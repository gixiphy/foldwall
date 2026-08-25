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
            images: images ?? palette,
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
}
