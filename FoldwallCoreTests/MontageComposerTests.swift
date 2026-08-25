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
        // 超出 4...12 不該爆，靜靜夾住
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
}
