//  MontageComposer.swift
//  隨機蒙太奇：每次構圖不同，同 seed 可重現。純 CoreGraphics 合成（決定性），
//  後製才走 Core Image。對使用者只有「蒙太奇」，內部配方不外露。

import CoreGraphics
import Foundation

public protocol MontageComposing: Sendable {
    func compose(
        images: [CGImage],
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
        images: [CGImage],
        canvas: CGSize,
        recipe: MontageRecipe,
        effect: PostProcess
    ) throws -> CGImage {
        guard !images.isEmpty else { throw Failure.emptyPool }

        let width = max(1, Int(canvas.width.rounded()))
        let height = max(1, Int(canvas.height.rounded()))

        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Failure.contextUnavailable }

        var rng = SeededGenerator(seed: recipe.seed)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)

        drawBackground(in: ctx, bounds: bounds, using: images, rng: &rng)

        let count = min(max(recipe.pieceCount, Self.pieceCountRange.lowerBound),
                        Self.pieceCountRange.upperBound)
        // 兩套內部配方，用 seed 選；不暴露給 UI
        let layout: Layout = recipe.seed % 2 == 0 ? .scatter : .stack

        for index in 0..<count {
            // 池不足就重複抽
            let image = images[Int.random(in: 0..<images.count, using: &rng)]
            draw(image, at: index, of: count, layout: layout, in: ctx, bounds: bounds, rng: &rng)
        }

        guard let composite = ctx.makeImage() else { throw Failure.contextUnavailable }
        return PostProcessor.apply(composite, effect: effect, rng: &rng)
    }

    // MARK: - 內部配方

    private enum Layout {
        case scatter   // 散落全幅
        case stack     // 往中心聚攏、疏密對比
    }

    /// 底：暗色 + 第一張低透明度鋪滿，避免縫隙露出純黑。
    private func drawBackground(
        in ctx: CGContext, bounds: CGRect, using images: [CGImage],
        rng: inout SeededGenerator
    ) {
        let shade = CGFloat.random(in: 0.06...0.12, using: &rng)
        ctx.setFillColor(CGColor(red: shade, green: shade, blue: shade, alpha: 1))
        ctx.fill(bounds)

        guard let backdrop = images.randomElement(using: &rng) else { return }
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
