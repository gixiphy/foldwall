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

    /// 一張蒙太奇畫得下的片數。下限 1（單張大圖也是一種構圖），
    /// 上限 20——再多每片就小到認不出是什麼照片了。
    ///
    /// 這是**上限**的可選範圍：實際畫幾片由 `StillPipeline.drawnPieceCount` 每輪抽。
    public static let pieceCountRange = 1...20

    /// 密度基準：片數等於這個值時，每片維持下面 `draw` 裡原本的尺寸。
    static let densityReferenceCount = 6
    /// 片數少時每片能放大的倍率上限。1 張時 √6 ≈ 2.45，不夾住的話單片會比畫布還高，
    /// 相紙白邊與陰影會被切在畫布外，看起來像壞掉而不像刻意。
    static let maxDensityBoost: CGFloat = 1.4

    /// 一片最多佔畫布**短邊**的多少。`.stack` 的第一片最大，就是這個值；
    /// `.scatter` 上限 0.52，在它之下。
    ///
    /// 公開是因為 `StillPipeline.decodeMaxPixel` 靠它決定每張圖要解到多大——
    /// 動了下面 `draw` 裡的 scale 範圍就要跟著動這裡，否則片會被放大到糊掉。
    public static let maxPieceScale: CGFloat = 0.62

    /// 兩位作者之間的分隔。
    static let creditSeparator = "・"
    /// 標註區塊最多佔畫布寬度的多少。它在右下角，不該橫跨整條底邊。
    static let creditMaxWidthFraction: CGFloat = 0.42
    /// 標註最多幾行。授權要求標註，但標註不能吃掉整張桌布——超過就在末行截斷。
    static let creditMaxLines = 4

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

        // **先把整組排完版再畫。** 一片的字會不會被蓋掉，取決於後面還有哪些片
        // 落在哪裡——邊算邊畫的話，畫到某一片時還不知道後面的事。
        let placements = tiles.enumerated().map { index, imageIndex in
            Self.place(images[imageIndex], imageIndex: imageIndex,
                       credit: recipe.showCredits ? pieces[imageIndex].credit : nil,
                       at: index, of: count, layout: layout, bounds: bounds, rng: &rng)
        }

        // 出處優先印在該片自己的相紙下緣。印不下的（片太小字會糊、名字比相紙還寬）
        // 和會被後面的片蓋住的，退回右下角那塊——一位都不能少。
        var spilled: [String] = []
        for (index, placement) in placements.enumerated() {
            let printed = placement.caption != nil
                && !Self.isCaptionHidden(at: index, among: placements)
            Self.render(placement, image: images[placement.imageIndex],
                        caption: printed, in: ctx)
            if let credit = placement.credit, !printed { spilled.append(credit) }
        }

        // 標註畫在後製**之前**：灰階／棕褐是要套在整張圖上的，
        // 字被一起處理才不會像事後貼上去的浮水印。
        Self.drawCredits(Self.dedupe(spilled), in: ctx, bounds: bounds)

        guard let composite = ctx.makeImage() else { throw Failure.contextUnavailable }
        return PostProcessor.apply(composite, effect: effect, rng: &rng)
    }

    /// 燒在相紙下緣的作者字級，佔該片高度的比例。
    static let captionScale: CGFloat = 0.04
    /// 字級再乘上這個當作下緣白邊的厚度——上下各留一點，字不會貼著邊。
    static let captionPaperRatio: CGFloat = 2.4
    /// 低於這個像素就不印在相紙上。印了也看不清，只是白白把下緣撐寬。
    static let captionMinimumSize: CGFloat = 11
    /// 作者名最多佔相紙寬度的多少。超過就別擠了，退回右下角那塊完整列出。
    static let captionMaxWidthRatio: CGFloat = 0.92

    /// 一片最多能有多少露在畫布外，佔**畫布短邊**的比例。實際允許量還會再乘上
    /// `1 - 該片佔掉的畫面比例`，見 `clampedCenter`。
    static let maxBleedFraction: CGFloat = 0.09

    /// 把中心點拉回來，限制這一片能有多少露在畫布外。
    ///
    /// **片佔畫面越大，能溢出的越少。** 小片壓邊、甚至半張跨出去，看起來是隨手擺的；
    /// 同樣的絕對量套在一張佔滿八成畫面的大圖上，就只是「沒放好」——上面空一大塊、
    /// 下面被切掉。所以允許量乘上 `1 - 該片佔掉的畫面比例`：
    /// 20 片時每片幾乎拿滿額度，1 片時額度趨近 0、自然被框回畫布內。
    ///
    /// 用**旋轉後**的外接框算：轉了 12° 的片，四個角比沒轉時更靠外。
    /// 片本身就比畫布大時湊不出合法範圍——那就置中，讓它對稱地溢出，
    /// 而不是偏在某一邊看起來像沒放好。
    static func clampedCenter(
        _ center: CGPoint, size: CGSize, angle: CGFloat, in bounds: CGRect
    ) -> CGPoint {
        let cosine = abs(cos(angle)), sine = abs(sin(angle))
        let halfWidth = (size.width * cosine + size.height * sine) / 2
        let halfHeight = (size.width * sine + size.height * cosine) / 2
        let budget = min(bounds.width, bounds.height) * maxBleedFraction
        return CGPoint(
            x: clamp(center.x, half: halfWidth, budget: budget,
                     from: bounds.minX, to: bounds.maxX),
            y: clamp(center.y, half: halfHeight, budget: budget,
                     from: bounds.minY, to: bounds.maxY)
        )
    }

    private static func clamp(
        _ value: CGFloat, half: CGFloat, budget: CGFloat,
        from lower: CGFloat, to upper: CGFloat
    ) -> CGFloat {
        let span = upper - lower
        let fill = span > 0 ? min(1, half * 2 / span) : 1
        let bleed = budget * (1 - fill)
        let low = lower + half - bleed, high = upper - half + bleed
        guard low <= high else { return (lower + upper) / 2 }
        return min(max(value, low), high)
    }

    /// `.stack` 的深度：0＝最大、最靠中間、**最後畫**（疊在最上面）；
    /// 1＝最小、最外圍、最先畫。
    ///
    /// 原本是反過來的（index 0 → 0），等於把最大最顯眼的那片畫在第一個，
    /// 然後被後面每一片蓋——片數越多埋越深。
    static func stackProgress(index: Int, total: Int) -> CGFloat {
        total <= 1 ? 0 : 1 - CGFloat(index) / CGFloat(total - 1)
    }

    /// 片數越多，每片要越小。
    ///
    /// 沒有這個係數的話，片數是直接乘上去的：6 片時總墨量約佔畫布 81%，12 片就是
    /// 162%——先畫的那幾片只剩兩三成露在外面。**面積 ∝ 1/片數**才能讓總墨量大致
    /// 不變，換成線性尺寸就是 ∝ 1/√片數。
    ///
    /// 這也是張數上限能從 12 開到 20 的原因：不縮的話 20 片是一團糊。
    static func densityScale(pieceCount: Int) -> CGFloat {
        let ratio = CGFloat(densityReferenceCount) / CGFloat(max(1, pieceCount))
        return min(sqrt(ratio), maxDensityBoost)
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
    static func creditNames(for pieces: [MontagePiece]) -> [String] {
        dedupe(pieces.compactMap(\.credit))
    }

    /// 去重並保持出現順序。
    static func dedupe(_ credits: [String]) -> [String] {
        var seen = Set<String>()
        return credits.filter { seen.insert($0).inserted }
    }

    /// 同上，串成一行。全是本機來源就回 nil——沒有人要標時不該平白多一塊底板。
    static func creditLine(for pieces: [MontagePiece]) -> String? {
        let names = creditNames(for: pieces)
        return names.isEmpty ? nil : names.joined(separator: creditSeparator)
    }

    /// 把作者一個一個塞進行裡，塞不下就換行。
    ///
    /// **不在一位作者中間斷行**：「Photo by Annie Spratt on」斷在這裡沒有意義，
    /// 而且斷過的名字會讓人以為那就是全名。裝不下的整位挪到下一行。
    ///
    /// 行數超過 `maxLines` 時，剩下的全部併進末行交給呼叫端截斷成「…」——
    /// 直接丟掉的話，看的人不會知道還有沒列完的作者。
    ///
    /// `fits` 由呼叫端決定（實際排版時是量 CTLine 寬度），這裡只管切法。
    static func wrapCredits(
        _ credits: [String], maxLines: Int, fits: (String) -> Bool
    ) -> [String] {
        guard !credits.isEmpty, maxLines > 0 else { return [] }

        var lines: [String] = []
        var current = ""
        for credit in credits {
            guard !current.isEmpty else {
                // 第一位無條件放進去：連一位都裝不下時也得有東西可截
                current = credit
                continue
            }
            let candidate = current + creditSeparator + credit
            if fits(candidate) {
                current = candidate
            } else {
                lines.append(current)
                current = credit
            }
        }
        lines.append(current)

        guard lines.count > maxLines else { return lines }
        let overflow = lines[(maxLines - 1)...].joined(separator: creditSeparator)
        return Array(lines.prefix(maxLines - 1)) + [overflow]
    }

    /// 畫在右下角。字級跟著畫布縮放，超寬屏才不會小到看不見。
    ///
    /// 用 CoreText 而不是 NSAttributedString：那組 key 要 AppKit，而 Core 是純邏輯層。
    ///
    /// **會換行也會截斷。** 12 片全來自不同作者時單行是 400 多個字元，而排版是
    /// 「從右緣往左推」——推過頭 x 會算成負的，字連同底板一起衝出畫布左緣。
    private static func drawCredits(_ credits: [String], in ctx: CGContext, bounds: CGRect) {
        guard !credits.isEmpty else { return }

        let size = max(11, min(bounds.height * 0.014, 22))
        let font = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 0.72),
        ]

        let padding = size * 0.9
        let maxWidth = bounds.width * creditMaxWidthFraction
        let token = makeLine(creditEllipsis, attributes: attributes)

        let wrapped = wrapCredits(credits, maxLines: creditMaxLines) { candidate in
            guard let line = makeLine(candidate, attributes: attributes) else { return false }
            return lineWidth(line) <= maxWidth
        }

        // 每一行都過一次截斷，不只末行：單一作者的名字就超寬時也要有人接。
        // 沒超寬的話 CTLineCreateTruncatedLine 原樣回傳，不會多出「…」。
        let lines: [(line: CTLine, width: CGFloat)] = wrapped.compactMap { text in
            guard let line = makeLine(text, attributes: attributes) else { return nil }
            guard lineWidth(line) > maxWidth,
                  let cut = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, token)
            else { return (line, lineWidth(line)) }
            return (cut, lineWidth(cut))
        }
        guard !lines.isEmpty else { return }

        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let lineHeight = ascent + descent + CTFontGetLeading(font)

        // 由下往上排，右緣切齊：最後一位作者落在最底下那行
        let baseline = bounds.minY + padding
        let rightEdge = bounds.maxX - padding
        let blockWidth = lines.map(\.width).max() ?? 0
        let top = baseline + CGFloat(lines.count - 1) * lineHeight + ascent
        let bottom = baseline - descent

        // 底下墊一層半透明暗色：亮色照片壓在角落時白字會看不見
        let plate = CGRect(x: rightEdge - blockWidth - padding * 0.5,
                           y: bottom - padding * 0.35,
                           width: blockWidth + padding,
                           height: (top - bottom) + padding * 0.7)
        let corner = size * 0.35

        ctx.saveGState()
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.38))
        ctx.addPath(CGPath(roundedRect: plate, cornerWidth: corner,
                           cornerHeight: corner, transform: nil))
        ctx.fillPath()

        for (offset, entry) in lines.reversed().enumerated() {
            ctx.textPosition = CGPoint(x: rightEdge - entry.width,
                                       y: baseline + CGFloat(offset) * lineHeight)
            CTLineDraw(entry.line, ctx)
        }
        ctx.restoreGState()
    }

    private static let creditEllipsis = "…"

    private static func makeLine(_ text: String, attributes: [CFString: Any]) -> CTLine? {
        guard let attributed = CFAttributedStringCreate(
            nil, text as CFString, attributes as CFDictionary) else { return nil }
        return CTLineCreateWithAttributedString(attributed)
    }

    private static func lineWidth(_ line: CTLine) -> CGFloat {
        CTLineGetBoundsWithOptions(line, .useOpticalBounds).width
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

    /// 一片排好版之後的樣子：落點、尺寸、角度、相紙厚度，以及要印的那行字。
    ///
    /// 之所以要有這個中間產物，是因為「這片的字會不會被蓋住」只有在**整組都排完**
    /// 之後才知道。順帶讓排版變成不碰 CGContext 的純函式，可以直接測。
    struct Placement {
        var imageIndex: Int
        var credit: String?
        /// 照片本身的落點與尺寸，不含白邊。
        var center: CGPoint
        var size: CGSize
        var angle: CGFloat
        /// 左右與上緣的白邊。
        var border: CGFloat
        /// 下緣白邊。要印字的話會比 `border` 厚，像拍立得。
        var footer: CGFloat
        var caption: Caption?

        /// 照片在自己座標系裡的框（原點＝照片中心，未旋轉）。
        var frame: CGRect {
            CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        }

        /// 相紙在自己座標系裡的框。上下不對稱——下緣可能加厚了。
        var paper: CGRect {
            CGRect(x: frame.minX - border, y: frame.minY - footer,
                   width: size.width + border * 2, height: size.height + border + footer)
        }

        /// 自己座標系的點 → 畫布座標。
        func toCanvas(_ point: CGPoint) -> CGPoint {
            let cosine = cos(angle), sine = sin(angle)
            return CGPoint(x: center.x + point.x * cosine - point.y * sine,
                           y: center.y + point.x * sine + point.y * cosine)
        }

        /// 畫布上這個點，落在這片的相紙上嗎。
        func covers(_ point: CGPoint) -> Bool {
            let dx = point.x - center.x, dy = point.y - center.y
            let cosine = cos(-angle), sine = sin(-angle)
            return paper.contains(CGPoint(x: dx * cosine - dy * sine,
                                          y: dx * sine + dy * cosine))
        }

        /// 沿著那行字均勻取樣（畫布座標）。沒有字就沒有點。
        func captionSamples(_ count: Int) -> [CGPoint] {
            guard let caption, count > 0 else { return [] }
            let y = frame.minY - footer / 2
            return (0..<count).map { step in
                let position = count == 1 ? 0.5 : CGFloat(step) / CGFloat(count - 1)
                return toCanvas(CGPoint(x: (position - 0.5) * caption.width, y: y))
            }
        }
    }

    /// 沿那行字取幾個點來判斷有沒有被蓋住。
    static let captionSampleCount = 13
    /// 被蓋掉多少比例就當作讀不到了。留一點餘裕——字尾被壓到一個角，
    /// 名字仍然認得出來，不必為此把整位挪去角落。
    static let captionOcclusionTolerance: CGFloat = 0.15

    /// 第 `index` 片的字會不會被**後面才畫**的片蓋掉。
    ///
    /// 蒙太奇本來就互相疊，照片被蓋住是構圖的一部分；但字被蓋住就是沒標到，
    /// 而 Unsplash 與 Pexels 的授權要求標註——所以被蓋到的那幾位要退回右下角那塊。
    static func isCaptionHidden(at index: Int, among placements: [Placement]) -> Bool {
        let samples = placements[index].captionSamples(captionSampleCount)
        guard !samples.isEmpty else { return false }
        let later = placements[(index + 1)...]
        let hidden = samples.count { point in later.contains { $0.covers(point) } }
        return CGFloat(hidden) / CGFloat(samples.count) > captionOcclusionTolerance
    }

    /// 排版一片：吃掉它那份隨機數，算出落點。**不碰 CGContext。**
    private static func place(
        _ image: CGImage, imageIndex: Int, credit: String?,
        at index: Int, of total: Int, layout: Layout,
        bounds: CGRect, rng: inout SeededGenerator
    ) -> Placement {
        let shortSide = min(bounds.width, bounds.height)
        let density = densityScale(pieceCount: total)
        let scale: CGFloat
        let center: CGPoint

        switch layout {
        case .scatter:
            scale = CGFloat.random(in: 0.28...0.52, using: &rng) * density
            // 內縮 12%：允許壓邊，但不要整張切在畫布外
            let inset = bounds.insetBy(dx: bounds.width * 0.12, dy: bounds.height * 0.12)
            center = CGPoint(
                x: CGFloat.random(in: inset.minX...inset.maxX, using: &rng),
                y: CGFloat.random(in: inset.minY...inset.maxY, using: &rng)
            )
        case .stack:
            // **倒著排**：小的、散在外圍的先畫，大的、靠中間的最後畫。
            // 原本是反過來的——最大最顯眼的那片畫在第一個，被後面每一片蓋。
            let progress = stackProgress(index: index, total: total)
            scale = CGFloat.random(in: 0.34...maxPieceScale, using: &rng)
                * (1.0 - progress * 0.35) * density
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

        // 相紙白邊：厚度跟著該張大小走，小張不會被邊框吃掉
        let border = max(2, min(size.width, size.height) * 0.02)
        // 有出處要印就把下緣加厚成拍立得那樣的留白，字寫在裡面
        let caption = credit.flatMap { makeCaption($0, pieceSize: size, canvas: bounds) }
        let footer = caption.map { max(border, $0.paperHeight) } ?? border

        // 夾的是**相紙**不是照片：下緣印了字之後相紙比照片高一截，
        // 拿照片的框去算會少算那一截，字就會被切在畫布外。
        // 相紙上下不對稱，所以先把它的中心轉到畫布座標、夾完再換算回落點。
        // 角度抽完才做，抽的順序沒變，同 seed 的隨機串流仍然一致。
        let paperSize = CGSize(width: size.width + border * 2,
                               height: size.height + border + footer)
        let paperOffset = (border - footer) / 2
        let rotatedOffset = CGPoint(x: -paperOffset * sin(angle), y: paperOffset * cos(angle))
        let clampedPaper = clampedCenter(
            CGPoint(x: center.x + rotatedOffset.x, y: center.y + rotatedOffset.y),
            size: paperSize, angle: angle, in: bounds)

        return Placement(
            imageIndex: imageIndex, credit: credit,
            center: CGPoint(x: clampedPaper.x - rotatedOffset.x,
                            y: clampedPaper.y - rotatedOffset.y),
            size: size, angle: angle, border: border, footer: footer, caption: caption)
    }

    /// 照排好的版畫出來。`caption` 決定要不要真的把那行字印上去——
    /// 被蓋住的就不印，但相紙下緣仍維持排版時的厚度（那塊本來就被蓋著看不到，
    /// 而改厚度會連帶動到落點，整組就不是同一個版了）。
    private static func render(
        _ placement: Placement, image: CGImage, caption showCaption: Bool, in ctx: CGContext
    ) {
        let border = placement.border
        let paper = placement.paper

        ctx.saveGState()
        ctx.translateBy(x: placement.center.x, y: placement.center.y)
        ctx.rotate(by: placement.angle)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -border * 0.8),
                      blur: border * 2.2,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
        ctx.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.96, alpha: 1))
        ctx.fill(paper)
        ctx.restoreGState()

        ctx.draw(image, in: placement.frame)

        if showCaption, let caption = placement.caption {
            // 置中在下緣留白裡。文字的視覺中心在 baseline 上方 (ascent - descent) / 2，
            // 要讓那個中心對準留白的中線，baseline 就得往下扣掉那一段。
            ctx.textPosition = CGPoint(
                x: -caption.width / 2,
                y: paper.minY + placement.footer / 2 - (caption.ascent - caption.descent) / 2)
            CTLineDraw(caption.line, ctx)
        }
        ctx.restoreGState()
    }

    /// 這一片的相紙下緣印不印得下這行字。印不下回 nil——由呼叫端退回右下角那塊，
    /// 不是丟掉：授權要求標註，擠不進去不代表可以不標。
    static func makeCaption(
        _ credit: String, pieceSize: CGSize, canvas: CGRect
    ) -> Caption? {
        // 跟著片走，但不超過畫布的一個比例：大片上的說明字不該大得像標題
        let fontSize = min(pieceSize.height * captionScale, canvas.height * 0.016)
        guard fontSize >= captionMinimumSize else { return nil }

        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        guard let line = makeLine(credit, attributes: [
            kCTFontAttributeName: font,
            // 深灰而不是純黑：印在相紙上的說明字，不該比照片本身還搶
            kCTForegroundColorAttributeName: CGColor(red: 0.32, green: 0.31, blue: 0.30, alpha: 1),
        ]) else { return nil }

        let width = lineWidth(line)
        guard width <= pieceSize.width * captionMaxWidthRatio else { return nil }
        return Caption(line: line, width: width,
                       paperHeight: fontSize * captionPaperRatio,
                       ascent: CTFontGetAscent(font), descent: CTFontGetDescent(font))
    }

    struct Caption {
        var line: CTLine
        var width: CGFloat
        /// 相紙下緣要多厚才裝得下這行字。
        var paperHeight: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
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
