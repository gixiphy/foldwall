//  MontageComposer.swift
//  隨機蒙太奇：每次構圖不同，同 seed 可重現。純 CoreGraphics 合成（決定性），
//  後製才走 Core Image。對使用者只有「蒙太奇」，內部配方不外露。

import CoreGraphics
import CoreText
import Foundation

/// 一片：圖，加上它的出處（如果有）。
///
/// 出處要跟著圖一路帶到合成那一刻——Unsplash 與 Pexels 的授權都要求標註作者，
/// 而桌布沒有地方可以點連結，只能燒進畫面（John's Background Switcher 也是這樣做）。
public struct MontagePiece {
    public var image: CGImage
    /// 例如 "Photo by Annie Spratt on Unsplash"。nil＝本機來源，不必標。
    public var credit: String?

    public init(image: CGImage, credit: String? = nil) {
        self.image = image
        self.credit = credit
    }
}

public protocol MontageComposing: Sendable {
    func compose(
        pieces: [MontagePiece],
        canvas: CGSize,
        recipe: MontageRecipe,
        effect: PostProcess
    ) throws -> CGImage
}

public struct MontageComposer: MontageComposing {

    public enum Failure: Error, Equatable {
        /// 空池：上層應跳過該輪、保留現桌布，不要寫黑圖。
        case emptyPool
        case contextUnavailable
    }

    public static let pieceCountRange = 4...12

    public init() {}

    public func compose(
        pieces: [MontagePiece],
        canvas: CGSize,
        recipe: MontageRecipe,
        effect: PostProcess
    ) throws -> CGImage {
        guard !pieces.isEmpty else { throw Failure.emptyPool }
        let images = pieces.map(\.image)

        let width = max(1, Int(canvas.width.rounded()))
        let height = max(1, Int(canvas.height.rounded()))

        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure.contextUnavailable }

        var rng = SeededGenerator(seed: recipe.seed)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)

        let count = min(max(recipe.pieceCount, Self.pieceCountRange.lowerBound),
                        Self.pieceCountRange.upperBound)

        // 多出來的那張留給背景，讓它不必跟任何一片重複。
        // 不夠分就退回用第一張——那時整張圖本來就一定會有重複。
        let tiles = Self.tileSelection(count: count, imageCount: images.count, rng: &rng)
        let backdropIndex = images.count > count
            ? Set(0..<images.count).subtracting(tiles).min() ?? 0
            : 0
        drawBackground(images[backdropIndex], in: ctx, bounds: bounds, rng: &rng)

        // 兩套內部配方，用 seed 選；不暴露給 UI
        let layout: Layout = recipe.seed % 2 == 0 ? .scatter : .stack

        for (index, imageIndex) in tiles.enumerated() {
            draw(images[imageIndex], at: index, of: count,
                 layout: layout, in: ctx, bounds: bounds, rng: &rng)
        }

        // 標註畫在後製**之前**：灰階／棕褐是要套在整張圖上的，
        // 字被一起處理才不會像事後貼上去的浮水印。
        Self.drawCredits(Self.creditLine(for: tiles.map { pieces[$0] }),
                         in: ctx, bounds: bounds)

        guard let composite = ctx.makeImage() else { throw Failure.contextUnavailable }
        return PostProcessor.apply(composite, effect: effect, rng: &rng)
    }

    /// 這一張蒙太奇要用哪幾張、依什麼順序。回傳的是 `images` 的索引。
    ///
    /// **先洗牌再依序取，不是每片各自隨機抽。** 原本是後者，那是「有放回抽樣」：
    /// 10 張圖抽 10 片，期望只有 6.5 張不重複，平均每張蒙太奇有 3.5 片是同一張圖。
    ///
    /// 片數多於張數時無法避免重複，但用洗牌循環可以讓重複次數盡量平均
    /// （每張用 ⌈count/n⌉ 或 ⌊count/n⌋ 次），不會有一張出現四次、另一張都沒出現。
    static func tileSelection(
        count: Int, imageCount: Int, rng: inout SeededGenerator
    ) -> [Int] {
        guard imageCount > 0, count > 0 else { return [] }
        var picked: [Int] = []
        picked.reserveCapacity(count)
        // 每輪重洗一次：片數超過張數時，第二輪的順序才不會跟第一輪一樣
        while picked.count < count {
            picked.append(contentsOf: Array(0..<imageCount).shuffled(using: &rng))
        }
        return Array(picked.prefix(count))
    }

    // MARK: - 標註

    /// 這一張要標哪些人。去重並保持出現順序——同一位作者被抽到兩片不必列兩次。
    static func creditLine(for pieces: [MontagePiece]) -> String? {
        var seen = Set<String>()
        let credits = pieces.compactMap(\.credit).filter { seen.insert($0).inserted }
        guard !credits.isEmpty else { return nil }
        return credits.joined(separator: "・")
    }

    /// 畫在右下角。字級跟著畫布縮放，超寬屏才不會小到看不見。
    ///
    /// 用 CoreText 而不是 NSAttributedString：那組 key 要 AppKit，而 Core 是純邏輯層。
    private static func drawCredits(_ line: String?, in ctx: CGContext, bounds: CGRect) {
        guard let line, !line.isEmpty else { return }

        let size = max(11, min(bounds.height * 0.014, 22))
        let font = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 0.72),
        ]
        let attributed = CFAttributedStringCreate(
            nil, line as CFString, attributes as CFDictionary)
        guard let attributed else { return }
        let ctLine = CTLineCreateWithAttributedString(attributed)
        let textBounds = CTLineGetBoundsWithOptions(ctLine, .useOpticalBounds)

        let padding = size * 0.9
        let x = bounds.maxX - textBounds.width - padding
        let y = bounds.minY + padding

        // 底下墊一層半透明暗色：亮色照片壓在角落時白字會看不見
        let plateX = x - padding * 0.5
        let plateY = y - padding * 0.35
        let plateWidth = textBounds.width + padding
        let plateHeight = textBounds.height + padding * 0.7
        let plate = CGRect(x: plateX, y: plateY, width: plateWidth, height: plateHeight)
        let corner = size * 0.35

        ctx.saveGState()
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.38))
        ctx.addPath(CGPath(roundedRect: plate, cornerWidth: corner,
                           cornerHeight: corner, transform: nil))
        ctx.fillPath()

        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(ctLine, ctx)
        ctx.restoreGState()
    }

    // MARK: - 內部配方

    private enum Layout {
        case scatter   // 散落全幅
        case stack     // 往中心聚攏、疏密對比
    }

    /// 底：暗色 + 一張低透明度鋪滿，避免縫隙露出純黑。
    /// 用哪一張由呼叫端決定——它會盡量挑一張沒被當成片用的。
    private func drawBackground(
        _ backdrop: CGImage, in ctx: CGContext, bounds: CGRect,
        rng: inout SeededGenerator
    ) {
        let shade = CGFloat.random(in: 0.06...0.12, using: &rng)
        ctx.setFillColor(CGColor(red: shade, green: shade, blue: shade, alpha: 1))
        ctx.fill(bounds)

        ctx.saveGState()
        ctx.setAlpha(0.22)
        ctx.draw(backdrop, in: aspectFill(backdrop, into: bounds))
        ctx.restoreGState()
    }

    private func draw(
        _ image: CGImage, at index: Int, of total: Int, layout: Layout,
        in ctx: CGContext, bounds: CGRect, rng: inout SeededGenerator
    ) {
        let shortSide = min(bounds.width, bounds.height)
        let scale: CGFloat
        let center: CGPoint

        switch layout {
        case .scatter:
            scale = CGFloat.random(in: 0.28...0.52, using: &rng)
            // 內縮 12%：允許壓邊，但不要整張切在畫布外
            let inset = bounds.insetBy(dx: bounds.width * 0.12, dy: bounds.height * 0.12)
            center = CGPoint(
                x: CGFloat.random(in: inset.minX...inset.maxX, using: &rng),
                y: CGFloat.random(in: inset.minY...inset.maxY, using: &rng)
            )
        case .stack:
            // 前幾張大、靠中間；後面小、往外散
            let progress = CGFloat(index) / CGFloat(max(1, total - 1))
            scale = CGFloat.random(in: 0.34...0.62, using: &rng) * (1.0 - progress * 0.35)
            let spread = 0.18 + progress * 0.34
            center = CGPoint(
                x: bounds.midX + CGFloat.random(in: -1...1, using: &rng) * bounds.width * spread,
                y: bounds.midY + CGFloat.random(in: -1...1, using: &rng) * bounds.height * spread
            )
        }

        let targetHeight = shortSide * scale
        let ratio = CGFloat(image.width) / CGFloat(max(1, image.height))
        let size = CGSize(width: targetHeight * ratio, height: targetHeight)
        let angle = CGFloat.random(in: -12...12, using: &rng) * .pi / 180

        let frame = CGRect(x: -size.width / 2, y: -size.height / 2,
                           width: size.width, height: size.height)
        // 相紙白邊：厚度跟著該張大小走，小張不會被邊框吃掉
        let border = max(2, min(size.width, size.height) * 0.02)
        let paper = frame.insetBy(dx: -border, dy: -border)

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -border * 0.8),
                      blur: border * 2.2,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
        ctx.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.96, alpha: 1))
        ctx.fill(paper)
        ctx.restoreGState()

        ctx.draw(image, in: frame)
        ctx.restoreGState()
    }

    private func aspectFill(_ image: CGImage, into bounds: CGRect) -> CGRect {
        let imageRatio = CGFloat(image.width) / CGFloat(max(1, image.height))
        let boundsRatio = bounds.width / max(1, bounds.height)
        var size = bounds.size
        if imageRatio > boundsRatio {
            size.width = bounds.height * imageRatio
        } else {
            size.height = bounds.width / imageRatio
        }
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
