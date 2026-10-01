import CoreGraphics
import Foundation
import Testing
@testable import FoldwallCore

@Suite("影片環境光")
struct AmbientGlowTests {

    /// 左半紅、右半藍的 8×8 影格。
    private func splitFrame() -> AmbientFrame {
        var rgb = [Float]()
        for _ in 0..<8 {
            for x in 0..<8 {
                rgb += x < 4 ? [1, 0, 0] : [0, 0, 1]
            }
        }
        return AmbientFrame(width: 8, height: 8, rgb: rgb)
    }

    private func pixel(_ rgba: [UInt8], width: Int, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let o = (y * width + x) * 4
        return (rgba[o], rgba[o + 1], rgba[o + 2])
    }

    // MARK: 版面

    @Test("直式影片在橫式螢幕上左右留白")
    func portraitVideoLeavesSideBars() throws {
        let rect = try #require(AmbientGlowLayout.videoRect(videoAspect: 9.0 / 16, screenAspect: 16.0 / 9))
        #expect(rect.minY == 0 && rect.height == 1)
        #expect(abs(rect.width - (9.0 / 16) / (16.0 / 9)) < 1e-9)
        #expect(abs(rect.midX - 0.5) < 1e-9)
    }

    @Test("超寬影片上下留白")
    func ultrawideVideoLeavesTopAndBottomBars() throws {
        let rect = try #require(AmbientGlowLayout.videoRect(videoAspect: 2.39, screenAspect: 16.0 / 9))
        #expect(rect.minX == 0 && rect.width == 1)
        #expect(abs(rect.midY - 0.5) < 1e-9)
        #expect(rect.height < 1)
    }

    @Test("比例相同或只差一兩條像素就不算留白")
    func matchingAspectHasNoBars() {
        #expect(AmbientGlowLayout.videoRect(videoAspect: 16.0 / 9, screenAspect: 16.0 / 9) == nil)
        #expect(AmbientGlowLayout.videoRect(videoAspect: 1.7770, screenAspect: 16.0 / 9) == nil)
        #expect(AmbientGlowLayout.videoRect(videoAspect: .nan, screenAspect: 1.6) == nil)
        #expect(AmbientGlowLayout.videoRect(videoAspect: 0, screenAspect: 1.6) == nil)
    }

    @Test("畫布長邊固定、短邊照螢幕比例")
    func canvasFollowsScreenAspect() {
        #expect(AmbientGlowLayout.canvasSize(screenAspect: 16.0 / 10) == (64, 40))
        #expect(AmbientGlowLayout.canvasSize(screenAspect: 9.0 / 16) == (36, 64))
    }

    // MARK: 合成

    @Test("左邊黑邊是紅的、右邊是藍的")
    func barsTakeTheNearestEdgeColor() {
        let rect = CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
        let rgba = AmbientGlowRenderer.render(
            frame: splitFrame(), videoRect: rect, canvas: (96, 54), screenAspect: 16.0 / 9,
            settings: AmbientGlowSettings(isEnabled: true, intensity: 1))
        let left = pixel(rgba, width: 96, x: 20, y: 27)
        let right = pixel(rgba, width: 96, x: 75, y: 27)
        #expect(left.r > left.b && left.r > 40)
        #expect(right.b > right.r && right.b > 40)
    }

    @Test("離影片越遠越暗")
    func glowFadesWithDistance() {
        let frame = AmbientFrame(width: 4, height: 4, rgb: Array(repeating: 1, count: 48))
        let rect = CGRect(x: 0.3, y: 0, width: 0.4, height: 1)
        let rgba = AmbientGlowRenderer.render(
            frame: frame, videoRect: rect, canvas: (96, 54), screenAspect: 16.0 / 9,
            settings: AmbientGlowSettings(isEnabled: true, intensity: 1, softness: .low))
        let near = pixel(rgba, width: 96, x: 27, y: 27).r
        let far = pixel(rgba, width: 96, x: 2, y: 27).r
        #expect(near > far)
    }

    @Test("強度越低整面越暗")
    func intensityScalesBrightness() {
        let frame = AmbientFrame(width: 4, height: 4, rgb: Array(repeating: 1, count: 48))
        let rect = CGRect(x: 0.3, y: 0, width: 0.4, height: 1)
        func brightness(_ intensity: Double) -> Int {
            let rgba = AmbientGlowRenderer.render(
                frame: frame, videoRect: rect, canvas: (96, 54), screenAspect: 16.0 / 9,
                settings: AmbientGlowSettings(isEnabled: true, intensity: intensity))
            return Int(pixel(rgba, width: 96, x: 20, y: 27).r)
        }
        #expect(brightness(0.3) < brightness(0.9))
    }

    @Test("輸出大小與 alpha 正確")
    func outputIsOpaqueCanvas() {
        let rgba = AmbientGlowRenderer.render(
            frame: splitFrame(), videoRect: CGRect(x: 0.2, y: 0, width: 0.6, height: 1),
            canvas: (40, 30), screenAspect: 4.0 / 3, settings: .default)
        #expect(rgba.count == 40 * 30 * 4)
        #expect(stride(from: 3, to: rgba.count, by: 4).allSatisfy { rgba[$0] == 255 })
    }

    // MARK: 取幀

    @Test("BGRA 緩衝縮成小圖，顏色順序正確")
    func downsamplesBGRA() throws {
        // 16×16，上半紅（BGRA = 0,0,255,255）、下半綠。
        var bytes = [UInt8]()
        for y in 0..<16 {
            for _ in 0..<16 { bytes += y < 8 ? [0, 0, 255, 255] : [0, 255, 0, 255] }
        }
        let frame = try #require(bytes.withUnsafeBytes {
            AmbientFrame(pixels: $0.baseAddress!, width: 16, height: 16, bytesPerRow: 64,
                         order: .bgra, targetWidth: 4, targetHeight: 4)
        })
        #expect(frame.width == 4 && frame.height == 4)
        #expect(frame.rgb[0] == 1 && frame.rgb[1] == 0)                 // 左上紅
        #expect(frame.rgb[(3 * 4) * 3 + 1] == 1 && frame.rgb[(3 * 4) * 3] == 0)   // 左下綠
    }

    @Test("OpenGL 讀回來的是底朝上，要翻正")
    func flipsBottomUpRows() throws {
        // RGBA，第一列（畫面最下面）白、其餘黑。
        var bytes = [UInt8](repeating: 0, count: 4 * 4 * 4)
        for x in 0..<4 { bytes[x * 4] = 255; bytes[x * 4 + 1] = 255; bytes[x * 4 + 2] = 255 }
        let frame = try #require(bytes.withUnsafeBytes {
            AmbientFrame(pixels: $0.baseAddress!, width: 4, height: 4, bytesPerRow: 16,
                         order: .rgba, bottomUp: true, targetWidth: 4, targetHeight: 4)
        })
        #expect(frame.rgb[0] == 0)
        #expect(frame.rgb[(3 * 4) * 3] == 1)
    }

    @Test("平均色差：相同為 0、全黑對全白為 1")
    func meanDifference() {
        let black = AmbientFrame(width: 2, height: 2, rgb: Array(repeating: 0, count: 12))
        let white = AmbientFrame(width: 2, height: 2, rgb: Array(repeating: 1, count: 12))
        #expect(black.meanDifference(from: black) == 0)
        #expect(black.meanDifference(from: white) == 1)
    }

    // MARK: 設定

    @Test("舊設定缺欄位時用預設值，而且預設關")
    func decodesMissingFieldsWithDefaults() throws {
        let decoded = try JSONDecoder().decode(AmbientGlowSettings.self, from: Data("{}".utf8))
        #expect(decoded == .default)
        #expect(decoded.isEnabled == false)
        let partial = try JSONDecoder().decode(
            AmbientGlowSettings.self, from: Data(#"{"isEnabled":true,"intensity":5}"#.utf8))
        #expect(partial.isEnabled)
        #expect(partial.intensity == AmbientGlowSettings.intensityRange.upperBound)
    }

    @Test("重設不動開關")
    func resetKeepsEnabledFlag() {
        let custom = AmbientGlowSettings(isEnabled: true, intensity: 0.2, softness: .high,
                                         spread: .low, followsVideo: false)
        let reset = custom.resetToDefaults()
        #expect(reset.isEnabled)
        #expect(reset.intensity == AmbientGlowSettings.default.intensity)
        #expect(reset.followsVideo)
    }

    @Test("裝置設定舊檔沒有環境光欄位也解得開")
    func deviceSettingsDecodeWithoutGlow() throws {
        let device = DeviceSettings(
            savedAt: Date(timeIntervalSince1970: 0), deviceName: "Mac", deviceID: "x",
            folderUsage: [:], albums: [], sourceRules: [], intervalMinutes: 30, effect: "none",
            montagePieceCount: nil, videoWallpaperEnabled: true, videoEngine: .desktopWindow,
            desktopVideoLayer: .belowIcons, ambientGlow: AmbientGlowSettings(isEnabled: true),
            launchAtLogin: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(device)) as? [String: Any])
        #expect(object["ambientGlow"] != nil)
        object.removeValue(forKey: "ambientGlow")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(DeviceSettings.self,
                                     from: JSONSerialization.data(withJSONObject: object))
        #expect(old.ambientGlow == .default)
    }
}
