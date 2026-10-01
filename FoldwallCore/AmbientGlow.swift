//  AmbientGlow.swift
//  影片環境光：把影片邊緣的顏色往外延伸到黑邊裡，隨播放柔和變化。
//  做法參考 x-ambient（取邊緣色 → 向外投射並衰減 → 模糊），移植到原生播放管線。
//
//  這裡只有**純計算**：設定、版面（影片在螢幕上佔哪一塊）、以及從一張小縮圖算出
//  整面環境光。取幀與顯示是各播放核心的事（見 Foldwall/Playback/AmbientGlowController）。
//
//  全部在低解析度上算：輸入是幾十像素見方的縮圖，輸出是長邊 64 像素的畫布，
//  顯示時由 Core Animation 用雙線性放大到整面螢幕——光暈本來就是糊的，
//  放大的平滑正好是想要的效果，不必花力氣算高解析度。

import CoreGraphics
import Foundation

/// 「柔和程度」與「擴散範圍」共用的三段。
public enum AmbientGlowLevel: String, Codable, Sendable, CaseIterable {
    case low
    case medium
    case high

    public var displayName: String {
        switch self {
        case .low: String(localized: "低", bundle: .foldwallCore)
        case .medium: String(localized: "中", bundle: .foldwallCore)
        case .high: String(localized: "高", bundle: .foldwallCore)
        }
    }
}

/// 環境光設定。**預設關**：多一份取幀與合成，要由使用者自己決定開。
public struct AmbientGlowSettings: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    /// 0.1...1。光暈相對原片的亮度。
    public var intensity: Double
    /// 模糊半徑。
    public var softness: AmbientGlowLevel
    /// 光從影片邊緣往外走多遠才淡掉。
    public var spread: AmbientGlowLevel
    /// 跟著畫面持續變色。關掉時每支影片取一次色就固定。
    public var followsVideo: Bool

    public static let intensityRange: ClosedRange<Double> = 0.1...1
    public static let `default` = AmbientGlowSettings()

    public init(isEnabled: Bool = false, intensity: Double = 0.6,
                softness: AmbientGlowLevel = .medium, spread: AmbientGlowLevel = .medium,
                followsVideo: Bool = true) {
        self.isEnabled = isEnabled
        self.intensity = intensity
        self.softness = softness
        self.spread = spread
        self.followsVideo = followsVideo
    }

    /// 把「重設」要動的值換回預設，開關本身不動——按重設不該順手把效果關掉。
    public func resetToDefaults() -> AmbientGlowSettings {
        var reset = AmbientGlowSettings.default
        reset.isEnabled = isEnabled
        return reset
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, intensity, softness, spread, followsVideo
    }

    /// 手寫：**缺欄位用預設值**，以後加欄位時舊設定解得開；強度順手夾回合法範圍。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AmbientGlowSettings.default
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? fallback.isEnabled
        let rawIntensity = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? fallback.intensity
        intensity = rawIntensity.isFinite
            ? min(max(rawIntensity, Self.intensityRange.lowerBound), Self.intensityRange.upperBound)
            : fallback.intensity
        softness = (try? c.decodeIfPresent(AmbientGlowLevel.self, forKey: .softness)) ?? fallback.softness
        spread = (try? c.decodeIfPresent(AmbientGlowLevel.self, forKey: .spread)) ?? fallback.spread
        followsVideo = try c.decodeIfPresent(Bool.self, forKey: .followsVideo) ?? fallback.followsVideo
    }
}

/// 一張縮小過的影格，RGB 各 0...1，**原點在左上**。
public struct AmbientFrame: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// width × height × 3。
    public let rgb: [Float]

    public init(width: Int, height: Int, rgb: [Float]) {
        precondition(width > 0 && height > 0 && rgb.count == width * height * 3)
        self.width = width
        self.height = height
        self.rgb = rgb
    }

    public enum ChannelOrder: Sendable {
        case bgra
        case rgba
    }

    /// 從 32 位元像素緩衝縮成 `targetWidth × targetHeight`，每格取多點平均。
    /// 來源已經是小圖（播放器幫忙縮過）就幾乎是逐點抄；萬一拿到的是原尺寸，
    /// 每格最多取 4×4 個點平均，不會因為跳著取而閃爍得太厲害。
    /// - Parameter bottomUp: 來源第一列是畫面最下面（OpenGL 讀回來的就是這樣）。
    public init?(pixels: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
                 order: ChannelOrder, bottomUp: Bool = false,
                 targetWidth: Int = 32, targetHeight: Int = 32) {
        guard width > 0, height > 0, bytesPerRow >= width * 4,
              targetWidth > 0, targetHeight > 0 else { return nil }
        let tw = min(targetWidth, width), th = min(targetHeight, height)
        let bytes = pixels.assumingMemoryBound(to: UInt8.self)
        let (r, b) = order == .bgra ? (2, 0) : (0, 2)
        var out = [Float](repeating: 0, count: tw * th * 3)
        for ty in 0..<th {
            let y0 = ty * height / th, y1 = max(y0 + 1, (ty + 1) * height / th)
            let ys = Self.samplePoints(y0, y1)
            for tx in 0..<tw {
                let x0 = tx * width / tw, x1 = max(x0 + 1, (tx + 1) * width / tw)
                let xs = Self.samplePoints(x0, x1)
                var sum: (Float, Float, Float) = (0, 0, 0)
                for sy in ys {
                    let row = bottomUp ? height - 1 - sy : sy
                    let base = bytes + row * bytesPerRow
                    for sx in xs {
                        let p = base + sx * 4
                        sum.0 += Float(p[r]); sum.1 += Float(p[1]); sum.2 += Float(p[b])
                    }
                }
                let scale = 1 / (Float(xs.count * ys.count) * 255)
                let o = (ty * tw + tx) * 3
                out[o] = sum.0 * scale; out[o + 1] = sum.1 * scale; out[o + 2] = sum.2 * scale
            }
        }
        self.init(width: tw, height: th, rgb: out)
    }

    /// 跟另一張的平均色差（0...1）。畫面幾乎沒變時拿來跳過重算。
    public func meanDifference(from other: AmbientFrame) -> Float {
        guard width == other.width, height == other.height, !rgb.isEmpty else { return 1 }
        var total: Float = 0
        for i in rgb.indices { total += abs(rgb[i] - other.rgb[i]) }
        return total / Float(rgb.count)
    }

    /// [start, end) 裡平均分布的最多 4 個點。
    private static func samplePoints(_ start: Int, _ end: Int) -> [Int] {
        let span = end - start
        let count = min(span, 4)
        return (0..<count).map { start + ($0 * 2 + 1) * span / (count * 2) }
    }
}

public enum AmbientGlowLayout {

    /// 影片在螢幕上佔的那塊，**正規化到 0...1、原點在左上**；沒有看得見的留白就是 nil。
    ///
    /// 只有「符合螢幕大小」會留白；「填滿高度／寬度」與「隨機」在呼叫端已經化簡成
    /// fill 或 fit 了，fill 不留白，不必呼叫這個。留白不到半個百分點（四捨五入出來的
    /// 一兩條像素）不算：為了一條看不見的縫開一整套取幀不划算。
    public static func videoRect(videoAspect: Double, screenAspect: Double) -> CGRect? {
        guard videoAspect.isFinite, screenAspect.isFinite, videoAspect > 0, screenAspect > 0 else {
            return nil
        }
        if videoAspect > screenAspect {
            // 比螢幕寬：上下留白。
            let height = screenAspect / videoAspect
            guard 1 - height >= 0.005 else { return nil }
            return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
        }
        let width = videoAspect / screenAspect
        guard 1 - width >= 0.005 else { return nil }
        return CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
    }

    /// 畫布大小：長邊 64 像素，短邊照螢幕比例。光暈本來就糊，模糊加上放大之後
    /// 跟 96 像素看不出差別，計算量卻少一半多（實測 12 fps 時差約 1% CPU）。
    public static func canvasSize(screenAspect: Double) -> (width: Int, height: Int) {
        let longSide = 64
        guard screenAspect.isFinite, screenAspect > 0 else { return (longSide, longSide) }
        if screenAspect >= 1 {
            return (longSide, max(8, Int((Double(longSide) / screenAspect).rounded())))
        }
        return (max(8, Int((Double(longSide) * screenAspect).rounded())), longSide)
    }
}

public enum AmbientGlowRenderer {

    /// 擴散距離，以「螢幕高度」為單位：光走這麼遠剩 1/e。
    static func spreadLength(_ level: AmbientGlowLevel) -> Float {
        switch level {
        case .low: 0.12
        case .medium: 0.25
        case .high: 0.5
        }
    }

    /// 模糊半徑，以「長邊 96 像素的畫布」為準，實際畫布再按比例換算。
    static func blurRadius(_ level: AmbientGlowLevel) -> Float {
        switch level {
        case .low: 2
        case .medium: 4
        case .high: 7
        }
    }

    /// 取色時往影片裡面縮一點：最外圈常有一兩條黑線（編碼補邊、縮放取整），
    /// 直接拿那一圈當邊緣色，整面光暈會偏暗。
    static let edgeInset: Double = 0.04

    /// 算出整面環境光，RGBA（alpha 恆為 255），原點在左上，`canvas.width × canvas.height × 4`。
    ///
    /// 每一點的顏色＝影片上離它最近的那個邊緣點（往內縮一點取），
    /// 乘上強度與「離影片多遠」的指數衰減；影片範圍裡面直接放影格本身，
    /// 模糊跨過邊界時才接得上，不會在原片外圍糊出一圈暗邊。
    public static func render(frame: AmbientFrame, videoRect: CGRect,
                              canvas: (width: Int, height: Int), screenAspect: Double,
                              settings: AmbientGlowSettings) -> [UInt8] {
        let cw = max(1, canvas.width), ch = max(1, canvas.height)
        let source = boxBlur(frame.rgb, width: frame.width, height: frame.height, radius: 1, passes: 2)
        let spread = spreadLength(settings.spread)
        let intensity = Float(min(max(settings.intensity, 0), 1))
        let aspect = Float(screenAspect.isFinite && screenAspect > 0 ? screenAspect : 1)
        let inset = edgeInset
        let rect = videoRect.standardized

        var canvasRGB = [Float](repeating: 0, count: cw * ch * 3)
        for y in 0..<ch {
            let v = (Double(y) + 0.5) / Double(ch)
            let py = min(max(v, rect.minY), rect.maxY)
            let fy = rect.height > 0 ? (py - rect.minY) / rect.height : 0.5
            for x in 0..<cw {
                let u = (Double(x) + 0.5) / Double(cw)
                let px = min(max(u, rect.minX), rect.maxX)
                let fx = rect.width > 0 ? (px - rect.minX) / rect.width : 0.5
                // 距離換成「螢幕高度」單位：橫向的正規化座標要乘上寬高比。
                let dx = Float(u - px) * aspect, dy = Float(v - py)
                let distance = (dx * dx + dy * dy).squareRoot()
                let falloff = distance > 0 ? exp(-distance / spread) : 1
                let color = sample(source, width: frame.width, height: frame.height,
                                   x: inset + fx * (1 - 2 * inset), y: inset + fy * (1 - 2 * inset))
                let o = (y * cw + x) * 3
                let gain = intensity * falloff
                canvasRGB[o] = color.0 * gain
                canvasRGB[o + 1] = color.1 * gain
                canvasRGB[o + 2] = color.2 * gain
            }
        }

        let radius = Int((blurRadius(settings.softness) * Float(max(cw, ch)) / 96).rounded())
        let blurred = boxBlur(canvasRGB, width: cw, height: ch, radius: radius, passes: 3)
        var rgba = [UInt8](repeating: 255, count: cw * ch * 4)
        for i in 0..<(cw * ch) {
            rgba[i * 4] = toByte(blurred[i * 3])
            rgba[i * 4 + 1] = toByte(blurred[i * 3 + 1])
            rgba[i * 4 + 2] = toByte(blurred[i * 3 + 2])
        }
        return rgba
    }

    private static func toByte(_ value: Float) -> UInt8 {
        UInt8(min(max(value, 0), 1) * 255 + 0.5)
    }

    /// 雙線性取樣，x／y 是 0...1。
    static func sample(_ rgb: [Float], width: Int, height: Int, x: Double, y: Double) -> (Float, Float, Float) {
        let fx = min(max(x * Double(width) - 0.5, 0), Double(width - 1))
        let fy = min(max(y * Double(height) - 0.5, 0), Double(height - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
        func at(_ px: Int, _ py: Int, _ c: Int) -> Float { rgb[(py * width + px) * 3 + c] }
        func mix(_ c: Int) -> Float {
            let top = at(x0, y0, c) * (1 - tx) + at(x1, y0, c) * tx
            let bottom = at(x0, y1, c) * (1 - tx) + at(x1, y1, c) * tx
            return top * (1 - ty) + bottom * ty
        }
        return (mix(0), mix(1), mix(2))
    }

    /// 可分離的方框模糊，連做幾次逼近高斯。邊界用夾住（重複最外圈），
    /// 不會在畫布邊上糊出一圈黑。
    static func boxBlur(_ rgb: [Float], width: Int, height: Int, radius: Int, passes: Int) -> [Float] {
        guard radius > 0, passes > 0 else { return rgb }
        var data = rgb
        var scratch = rgb
        let window = Float(radius * 2 + 1)
        for _ in 0..<passes {
            // 橫向
            for y in 0..<height {
                for c in 0..<3 {
                    var sum: Float = 0
                    for k in -radius...radius {
                        sum += data[(y * width + min(max(k, 0), width - 1)) * 3 + c]
                    }
                    for x in 0..<width {
                        scratch[(y * width + x) * 3 + c] = sum / window
                        let outgoing = min(max(x - radius, 0), width - 1)
                        let incoming = min(max(x + radius + 1, 0), width - 1)
                        sum += data[(y * width + incoming) * 3 + c] - data[(y * width + outgoing) * 3 + c]
                    }
                }
            }
            // 縱向
            for x in 0..<width {
                for c in 0..<3 {
                    var sum: Float = 0
                    for k in -radius...radius {
                        sum += scratch[(min(max(k, 0), height - 1) * width + x) * 3 + c]
                    }
                    for y in 0..<height {
                        data[(y * width + x) * 3 + c] = sum / window
                        let outgoing = min(max(y - radius, 0), height - 1)
                        let incoming = min(max(y + radius + 1, 0), height - 1)
                        sum += scratch[(incoming * width + x) * 3 + c] - scratch[(outgoing * width + x) * 3 + c]
                    }
                }
            }
        }
        return data
    }
}
