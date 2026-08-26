import XCTest
import CoreGraphics
@testable import FoldwallCore

final class MontageComposerTests: XCTestCase {

    private let palette = [
        TestImage.solid(1, 0, 0),
        TestImage.solid(0, 1, 0),
        TestImage.solid(0, 0, 1),
    ]
    private let canvas = CGSize(width: 320, height: 180)

    private func compose(seed: UInt64, pieces: Int = 4, effect: PostProcess = .none,
                         images: [CGImage]? = nil) throws -> CGImage {
        try MontageComposer().compose(
            pieces: (images ?? palette).map { MontagePiece(image: $0) },
            canvas: canvas,
            recipe: MontageRecipe(pieceCount: pieces, seed: seed),
            effect: effect
        )
    }

    func testOutputMatchesCanvas() throws {
        let image = try compose(seed: 42)
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 180)
    }

    func testSameSeedIsDeterministic() throws {
        let a = try compose(seed: 42)
        let b = try compose(seed: 42)
        XCTAssertEqual(TestImage.bytes(a), TestImage.bytes(b), "同 seed 必須逐像素相同")
    }

    func testDifferentSeedDiffers() throws {
        let a = try compose(seed: 42)
        let b = try compose(seed: 43)
        XCTAssertNotEqual(TestImage.bytes(a), TestImage.bytes(b), "換 seed 要換構圖")
    }

    func testPieceCountIsClamped() throws {
        // 超出 pieceCountRange（1...20）不該爆，靜靜夾住
        XCTAssertNoThrow(try compose(seed: 1, pieces: 0))
        XCTAssertNoThrow(try compose(seed: 1, pieces: 999))
    }

    func testFewerImagesThanPiecesRepeats() throws {
        let single = [TestImage.solid(1, 1, 0)]
        XCTAssertNoThrow(try compose(seed: 7, pieces: 8, images: single), "池不足要重複抽，不是報錯")
    }

    func testEmptyImagesThrows() {
        XCTAssertThrowsError(try compose(seed: 1, images: []), "空池應由上層跳過該輪，Composer 明確報錯")
    }

    func testEffectIsAppliedToComposite() throws {
        let plain = try compose(seed: 5)
        let gray = try compose(seed: 5, effect: .grayscale)
        XCTAssertNotEqual(TestImage.bytes(plain), TestImage.bytes(gray), "後製要套在合成結果上")
    }

    // MARK: - 同一張圖裡不能有重複的片

    private func selection(count: Int, images: Int, seed: UInt64) -> [Int] {
        var rng = SeededGenerator(seed: seed)
        return MontageComposer.tileSelection(count: count, imageCount: images, rng: &rng)
    }

    /// 原本每片各自隨機抽——那是有放回抽樣，10 張抽 10 片期望只有 6.5 張不重複，
    /// 畫面上平均有 3.5 片是同一張圖。
    func testNoRepeatsWhenThereAreEnoughImages() {
        for seed in UInt64(1)...30 {
            let picked = selection(count: 10, images: 10, seed: seed)
            XCTAssertEqual(picked.count, 10)
            XCTAssertEqual(Set(picked).count, 10, "seed \(seed) 出現重複")
        }
    }

    func testNoRepeatsWhenThereAreImagesToSpare() {
        let picked = selection(count: 6, images: 20, seed: 7)
        XCTAssertEqual(Set(picked).count, 6)
    }

    /// 片數多於張數時無法避免重複，但要平均分配，
    /// 不能一張出現四次、另一張一次都沒出現。
    func testRepeatsAreSpreadEvenlyWhenUnavoidable() {
        let picked = selection(count: 10, images: 4, seed: 3)
        XCTAssertEqual(picked.count, 10)
        XCTAssertEqual(Set(picked).count, 4, "四張都要用到")

        var counts: [Int: Int] = [:]
        for index in picked { counts[index, default: 0] += 1 }
        let values = counts.values.sorted()
        XCTAssertLessThanOrEqual(values.last! - values.first!, 1,
                                 "最多用幾次與最少用幾次不該差超過 1，實際：\(values)")
    }

    func testSelectionIsReproducibleForTheSameSeed() {
        XCTAssertEqual(selection(count: 8, images: 12, seed: 42),
                       selection(count: 8, images: 12, seed: 42))
    }

    func testSelectionVariesAcrossSeeds() {
        let all = Set((UInt64(1)...20).map { selection(count: 8, images: 12, seed: $0) })
        XCTAssertGreaterThan(all.count, 1, "不同 seed 該給不同的組合")
    }

    func testEmptyInputsAreSafe() {
        XCTAssertTrue(selection(count: 10, images: 0, seed: 1).isEmpty)
        XCTAssertTrue(selection(count: 0, images: 10, seed: 1).isEmpty)
    }

    // MARK: - 密度與疊放順序

    /// 密度基準點：6 片時不縮不放，維持原本調好的尺寸。
    func testDensityScaleIsNeutralAtReference() {
        XCTAssertEqual(MontageComposer.densityScale(pieceCount: 6), 1, accuracy: 0.0001)
    }

    /// 總墨量 ∝ 片數 × 尺寸²，要大致守恆——這才是高張數不糊成一團的原因。
    func testDensityScaleKeepsTotalInkRoughlyConstant() {
        let reference = 6 * pow(MontageComposer.densityScale(pieceCount: 6), 2)
        for count in 6...MontageComposer.pieceCountRange.upperBound {
            let ink = CGFloat(count) * pow(MontageComposer.densityScale(pieceCount: count), 2)
            XCTAssertEqual(ink, reference, accuracy: 0.0001, "\(count) 片的總墨量偏掉了")
        }
    }

    /// 片數少時的放大要夾住：√6 ≈ 2.45 倍會讓單片比畫布還高，
    /// 相紙白邊與陰影被切在畫布外會像壞掉而不像刻意。
    func testDensityScaleIsCappedWhenPiecesAreFew() {
        XCTAssertEqual(MontageComposer.densityScale(pieceCount: 1),
                       MontageComposer.maxDensityBoost, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(MontageComposer.densityScale(pieceCount: 2),
                                 MontageComposer.maxDensityBoost)
    }

    /// 最大的那片要**最後**畫，才不會被後面每一片蓋掉。
    func testStackDrawsTheBiggestPieceLast() {
        let total = 12
        XCTAssertEqual(MontageComposer.stackProgress(index: total - 1, total: total), 0,
                       accuracy: 0.0001, "最後畫的＝progress 0＝最大最靠中間")
        XCTAssertEqual(MontageComposer.stackProgress(index: 0, total: total), 1,
                       accuracy: 0.0001, "最先畫的＝progress 1＝最小最外圍")
        let progress = (0..<total).map { MontageComposer.stackProgress(index: $0, total: total) }
        XCTAssertEqual(progress, progress.sorted(by: >), "深度要一路遞減")
    }

    /// 只有一片時它就是主角：最大、置中，不能被當成最外圍的小片。
    func testStackProgressHandlesASinglePiece() {
        XCTAssertEqual(MontageComposer.stackProgress(index: 0, total: 1), 0)
        XCTAssertEqual(MontageComposer.stackProgress(index: 0, total: 0), 0)
    }

    /// 開到上限不該爆，而且要跟低張數畫出不一樣的東西。
    func testComposesAtTheFullCeiling() throws {
        let ceiling = MontageComposer.pieceCountRange.upperBound
        let dense = try compose(seed: 9, pieces: ceiling)
        let sparse = try compose(seed: 9, pieces: 1)
        XCTAssertEqual(dense.width, Int(canvas.width))
        XCTAssertNotEqual(TestImage.bytes(dense), TestImage.bytes(sparse))
    }

    // MARK: - 標註

    /// Unsplash 與 Pexels 的授權都要求標註作者。桌布沒有地方可以點連結，
    /// 只能燒進畫面——所以出處必須一路跟著圖走到合成那一刻。
    func testCreditLineListsEveryDistinctSource() {
        let pieces = [
            MontagePiece(image: palette[0], credit: "Photo by A on Unsplash"),
            MontagePiece(image: palette[1], credit: "Photo by B on Pexels"),
            MontagePiece(image: palette[2], credit: nil),
        ]
        XCTAssertEqual(MontageComposer.creditLine(for: pieces),
                       "Photo by A on Unsplash・Photo by B on Pexels")
    }

    /// 同一位作者被抽到兩片不必列兩次，順序也要穩定。
    func testCreditLineDedupesAndKeepsOrder() {
        let pieces = [
            MontagePiece(image: palette[0], credit: "Photo by A on Unsplash"),
            MontagePiece(image: palette[1], credit: "Photo by B on Pexels"),
            MontagePiece(image: palette[2], credit: "Photo by A on Unsplash"),
        ]
        XCTAssertEqual(MontageComposer.creditLine(for: pieces),
                       "Photo by A on Unsplash・Photo by B on Pexels")
    }

    /// 全是本機來源就不畫——沒有人要標的時候不該平白多一塊底板。
    func testNoCreditLineWhenEverythingIsLocal() {
        let pieces = palette.map { MontagePiece(image: $0) }
        XCTAssertNil(MontageComposer.creditLine(for: pieces))
        XCTAssertNil(MontageComposer.creditLine(for: []))
    }

    // MARK: - 標註換行與截斷

    /// 塞得下就繼續往同一行加，塞不下才換行——而且不在一位作者中間斷。
    func testWrapCreditsPacksGreedilyWithoutSplittingAuthors() {
        // 一行最多 9 個字元：兩位（3+1+3=7）塞得下，三位（11）塞不下
        let lines = MontageComposer.wrapCredits(
            ["AAA", "BBB", "CCC", "DDD"], maxLines: 4) { $0.count <= 9 }
        XCTAssertEqual(lines, ["AAA・BBB", "CCC・DDD"])
    }

    /// 全部塞得下就一行，不該無故換行。
    func testWrapCreditsKeepsOneLineWhenEverythingFits() {
        XCTAssertEqual(MontageComposer.wrapCredits(["A", "B", "C"], maxLines: 4) { _ in true },
                       ["A・B・C"])
    }

    /// 超過行數上限時，剩下的併進末行等著被截成「…」。
    /// 直接丟掉的話，看的人不會知道還有沒列完的作者——那等於沒標。
    func testWrapCreditsFoldsOverflowIntoLastLine() {
        let lines = MontageComposer.wrapCredits(
            ["A", "B", "C", "D", "E"], maxLines: 2) { $0.count <= 1 }
        XCTAssertEqual(lines, ["A", "B・C・D・E"])
    }

    /// 連一位作者都塞不下時仍要吐出他：沒東西可截的話整塊標註會消失。
    func testWrapCreditsKeepsFirstAuthorEvenWhenNothingFits() {
        XCTAssertEqual(
            MontageComposer.wrapCredits(["Photo by A on Unsplash"], maxLines: 4) { _ in false },
            ["Photo by A on Unsplash"])
    }

    func testWrapCreditsHandlesEmptyInput() {
        XCTAssertTrue(MontageComposer.wrapCredits([], maxLines: 4) { _ in true }.isEmpty)
        XCTAssertTrue(MontageComposer.wrapCredits(["A"], maxLines: 0) { _ in true }.isEmpty)
    }

    /// 12 位不同作者在 320 寬的畫布上是 400 多個字元。排版是「從右緣往左推」，
    /// 修好之前那串會把 x 推成負的、字連同底板一起衝出畫布左緣。
    /// 標註只准待在右下角——左半邊一個像素都不該被動到。
    func testManyCreditsNeverSpillIntoTheLeftHalf() throws {
        let images = (0..<12).map { palette[$0 % palette.count] }
        let named = images.enumerated().map { index, image in
            MontagePiece(image: image,
                         credit: "Photo by Photographer Number \(index) on Unsplash")
        }
        let recipe = MontageRecipe(pieceCount: 12, seed: 3)
        let credited = try MontageComposer().compose(
            pieces: named, canvas: canvas, recipe: recipe, effect: .none)
        let plain = try MontageComposer().compose(
            pieces: images.map { MontagePiece(image: $0) },
            canvas: canvas, recipe: recipe, effect: .none)

        XCTAssertNotEqual(TestImage.bytes(credited), TestImage.bytes(plain),
                          "前提：標註真的有被畫出來，否則這個測試什麼都沒驗到")

        let leftHalf = CGRect(x: 0, y: 0,
                              width: CGFloat(Int(canvas.width) / 2), height: canvas.height)
        let a = try XCTUnwrap(credited.cropping(to: leftHalf))
        let b = try XCTUnwrap(plain.cropping(to: leftHalf))
        XCTAssertEqual(TestImage.bytes(a), TestImage.bytes(b), "標註溢出到畫面左半邊")
    }

    /// 有標註時畫面真的變了——確認那段繪圖有被執行到。
    func testCreditIsActuallyDrawn() throws {
        let plain = try MontageComposer().compose(
            pieces: palette.map { MontagePiece(image: $0) },
            canvas: canvas, recipe: MontageRecipe(pieceCount: 4, seed: 7), effect: .none)
        let credited = try MontageComposer().compose(
            pieces: palette.map { MontagePiece(image: $0, credit: "Photo by A on Unsplash") },
            canvas: canvas, recipe: MontageRecipe(pieceCount: 4, seed: 7), effect: .none)
        XCTAssertNotEqual(TestImage.bytes(plain), TestImage.bytes(credited))
    }

    // MARK: - 溢出

    /// 回傳這一片實際被切在畫布外多少（角度 0，只看垂直方向）。
    private func bleed(pieceHeight: CGFloat, in bounds: CGRect) -> CGFloat {
        let size = CGSize(width: bounds.width * 0.3, height: pieceHeight)
        // 中心硬推到畫布外，逼出允許的極限
        let placed = MontageComposer.clampedCenter(
            CGPoint(x: bounds.midX, y: bounds.minY - bounds.height),
            size: size, angle: 0, in: bounds)
        return bounds.minY - (placed.y - pieceHeight / 2)
    }

    /// 小片壓邊是刻意的：看起來像隨手擺的，不是沒放好。
    func testSmallPiecesMayHangOverTheEdge() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 900)
        XCTAssertGreaterThan(bleed(pieceHeight: 180, in: bounds), 40)
    }

    /// 佔滿大半畫面的大片幾乎不准溢出——上面空一塊、下面被切掉只是「沒放好」。
    func testLargePiecesAreHeldInsideTheCanvas() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 900)
        XCTAssertLessThan(bleed(pieceHeight: 760, in: bounds), 20)
    }

    /// 片佔畫面越多，能溢出的越少——中間沒有跳階。
    func testBleedShrinksMonotonicallyAsThePieceGrows() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let byHeight = stride(from: CGFloat(120), through: 880, by: 40).map {
            bleed(pieceHeight: $0, in: bounds)
        }
        XCTAssertEqual(byHeight, byHeight.sorted(by: >))
    }

    /// 片本身就比畫布大時湊不出合法位置——置中，讓它對稱地溢出。
    func testAPieceBiggerThanTheCanvasIsCentred() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let placed = MontageComposer.clampedCenter(
            CGPoint(x: 100, y: 100), size: CGSize(width: 2000, height: 1200),
            angle: 0, in: bounds)
        XCTAssertEqual(placed.x, bounds.midX)
        XCTAssertEqual(placed.y, bounds.midY)
    }

    // MARK: - 出處印在相紙上

    /// 相紙夠大就把作者印在下緣，像拍立得。
    func testCaptionPrintsOnAPieceWithRoomForIt() {
        let canvas = CGRect(x: 0, y: 0, width: 1600, height: 900)
        XCTAssertNotNil(MontageComposer.makeCaption(
            "Photo by A on Unsplash", pieceSize: CGSize(width: 900, height: 600), canvas: canvas))
    }

    /// 字會小到看不清就別印——印了只是白白把相紙下緣撐寬。
    func testCaptionIsSkippedWhenThePaperIsTooSmall() {
        let canvas = CGRect(x: 0, y: 0, width: 1600, height: 900)
        XCTAssertNil(MontageComposer.makeCaption(
            "Photo by A on Unsplash", pieceSize: CGSize(width: 200, height: 150), canvas: canvas))
    }

    /// 名字比相紙還寬也別擠——退回右下角那塊完整列出來。
    func testCaptionIsSkippedWhenTheNameIsWiderThanThePaper() {
        let canvas = CGRect(x: 0, y: 0, width: 1600, height: 900)
        XCTAssertNil(MontageComposer.makeCaption(
            "Photo by Somebody With A Very Long Name on Unsplash",
            pieceSize: CGSize(width: 90, height: 600), canvas: canvas))
    }

    /// 關掉標註要跟「本來就沒有出處」畫得**一模一樣**：相紙下緣不能留著加寬。
    func testTurningCreditsOffLeavesNoTrace() throws {
        let credited = palette.map { MontagePiece(image: $0, credit: "Photo by A on Unsplash") }
        let anonymous = palette.map { MontagePiece(image: $0) }
        func render(_ pieces: [MontagePiece], show: Bool) throws -> [UInt8] {
            TestImage.bytes(try MontageComposer().compose(
                pieces: pieces, canvas: canvas,
                recipe: MontageRecipe(pieceCount: 4, seed: 7, showCredits: show),
                effect: .none))
        }
        XCTAssertNotEqual(try render(credited, show: true), try render(credited, show: false))
        XCTAssertEqual(try render(credited, show: false), try render(anonymous, show: true),
                       "關掉之後不該還看得出這些圖有出處")
    }

    /// 預設是開的：授權要求標註，不該要使用者自己去找開關。
    func testCreditsAreOnByDefault() {
        XCTAssertTrue(MontageRecipe(pieceCount: 4, seed: 1).showCredits)
    }

    // MARK: - 字被蓋住

    private let wideCanvas = CGRect(x: 0, y: 0, width: 1600, height: 900)

    private func placed(
        x: CGFloat, y: CGFloat, size: CGSize = CGSize(width: 600, height: 400),
        angle: CGFloat = 0, captioned: Bool = true
    ) -> MontageComposer.Placement {
        let credit = "Photo by A on Unsplash"
        let caption = captioned
            ? MontageComposer.makeCaption(credit, pieceSize: size, canvas: wideCanvas)
            : nil
        let border = max(2, min(size.width, size.height) * 0.02)
        return MontageComposer.Placement(
            imageIndex: 0, credit: captioned ? credit : nil,
            center: CGPoint(x: x, y: y), size: size, angle: angle, border: border,
            footer: caption.map { max(border, $0.paperHeight) } ?? border, caption: caption)
    }

    /// 字整條被後面那片壓住＝沒標到。照片被蓋是構圖，字被蓋不是。
    func testCaptionCoveredByALaterPieceCountsAsHidden() {
        let target = placed(x: 400, y: 400)
        let cover = placed(x: 400, y: 183, captioned: false)
        XCTAssertTrue(MontageComposer.isCaptionHidden(at: 0, among: [target, cover]))
    }

    /// 只看**之後才畫**的片：先畫的那些在它下面，蓋不到它。
    func testEarlierPiecesDoNotHideACaption() {
        let cover = placed(x: 400, y: 183, captioned: false)
        let target = placed(x: 400, y: 400)
        XCTAssertFalse(MontageComposer.isCaptionHidden(at: 1, among: [cover, target]),
                       "順序反過來就蓋不到了")
    }

    /// 沒有字的片不必判斷，也不該被當成「被蓋住」而多列一位到角落。
    func testAPieceWithoutACaptionIsNeverHidden() {
        let target = placed(x: 400, y: 400, captioned: false)
        let cover = placed(x: 400, y: 183, captioned: false)
        XCTAssertFalse(MontageComposer.isCaptionHidden(at: 0, among: [target, cover]))
    }

    /// 只被壓到字尾一角，名字仍然讀得出來——不必為此把整位挪去角落。
    func testACaptionGrazedAtOneEndStaysOnThePaper() throws {
        let target = placed(x: 400, y: 400)
        let width = try XCTUnwrap(target.caption).width
        // 覆蓋片的相紙左緣剛好落在最後一個取樣點左邊一點點
        let cover = placed(x: 400 + width / 2 + 308 - width * 0.01, y: 183, captioned: false)
        XCTAssertFalse(MontageComposer.isCaptionHidden(at: 0, among: [target, cover]))
    }

    /// 取樣點要真的落在那行字上：旋轉之後也一樣。
    func testCaptionSamplesFollowTheRotatedPaper() throws {
        let upright = placed(x: 400, y: 400)
        let tilted = placed(x: 400, y: 400, angle: .pi / 2)
        let a = upright.captionSamples(MontageComposer.captionSampleCount)
        let b = tilted.captionSamples(MontageComposer.captionSampleCount)
        XCTAssertEqual(a.count, MontageComposer.captionSampleCount)
        XCTAssertEqual(b.count, a.count)
        // 轉 90° 之後那行字從水平變垂直
        XCTAssertGreaterThan(a.map(\.x).max()! - a.map(\.x).min()!,
                             a.map(\.y).max()! - a.map(\.y).min()!)
        XCTAssertGreaterThan(b.map(\.y).max()! - b.map(\.y).min()!,
                             b.map(\.x).max()! - b.map(\.x).min()!)
        // 而且每個取樣點都還在自己的相紙上
        XCTAssertTrue(b.allSatisfy { tilted.covers($0) })
    }
}
