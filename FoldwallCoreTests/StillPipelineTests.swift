import XCTest
import CoreGraphics
@testable import FoldwallCore

/// 記錄被寫了哪些螢幕，供斷言「該跳過的一次都沒寫」。
private final class RecordingDesktop: DesktopSetting, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(id: CGDirectDisplayID, url: URL)] = []

    var calls: [(id: CGDirectDisplayID, url: URL)] {
        lock.withLock { storage }
    }

    func setDesktopImageURL(_ url: URL, for screenID: CGDirectDisplayID) async throws {
        lock.withLock { storage.append((screenID, url)) }
    }
}

final class StillPipelineTests: XCTestCase {

    private var root: URL!
    private var paths: AppPaths!
    private var desktop: RecordingDesktop!
    private var pool: [URL] = []

    private let displayA = DisplayTarget(id: 1, uuid: "AAAA", canvas: CGSize(width: 400, height: 300))
    private let displayB = DisplayTarget(id: 2, uuid: "BBBB", canvas: CGSize(width: 400, height: 300))

    override func setUpWithError() throws {
        root = URL.temporaryDirectory.appending(path: "foldwall-still-\(UUID().uuidString)")
        paths = AppPaths(applicationSupport: root.appending(path: "Support"),
                         caches: root.appending(path: "Caches"))
        desktop = RecordingDesktop()

        let sourceDir = root.appending(path: "photos")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        pool = try (0..<3).map { index in
            let url = sourceDir.appending(path: "p\(index).png")
            try TestImage.writePNG(TestImage.solid(Double(index) / 3, 0.5, 0.5, size: 300), to: url)
            return url
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makePipeline() -> StillPipeline {
        StillPipeline(desktop: desktop, paths: paths)
    }

    // MARK: - 尺寸與片數

    func testCanvasSizeUsesBackingScale() {
        let canvas = DisplayTarget.canvasSize(frame: CGSize(width: 100, height: 100), scale: 2)
        XCTAssertEqual(canvas, CGSize(width: 200, height: 200))
    }

    func testPieceCountCeilingFollowsLongSide() {
        XCTAssertEqual(StillPipeline.pieceCountCeiling(longSide: 5120, tier: .full), 16)
        XCTAssertEqual(StillPipeline.pieceCountCeiling(longSide: 6016, tier: .full), 16)
        XCTAssertEqual(StillPipeline.pieceCountCeiling(longSide: 3456, tier: .full), 12)
        XCTAssertEqual(StillPipeline.pieceCountCeiling(longSide: 2560, tier: .full), 8)
        XCTAssertEqual(StillPipeline.pieceCountCeiling(longSide: 5120, tier: .reduced), 6, "降載封頂 6")
    }

    func testPieceCountCeilingOverrideBeatsLongSide() {
        XCTAssertEqual(StillPipeline.pieceCountCeiling(longSide: 2560, tier: .full, override: 20), 20)
        XCTAssertEqual(StillPipeline.pieceCountCeiling(longSide: 5120, tier: .full, override: 4), 4)
        XCTAssertEqual(StillPipeline.pieceCountCeiling(longSide: 2560, tier: .full, override: nil), 8,
                       "nil＝自動，行為與沒有這個參數時相同")
    }

    func testPieceCountCeilingOverrideIsClampedAndStillCappedWhenReduced() {
        XCTAssertEqual(StillPipeline.pieceCountCeiling(longSide: 2560, tier: .full, override: 99),
                       MontageComposer.pieceCountRange.upperBound, "夾到合成端畫得出來的上限")
        XCTAssertEqual(StillPipeline.pieceCountCeiling(longSide: 2560, tier: .full, override: 0),
                       MontageComposer.pieceCountRange.lowerBound)
        XCTAssertEqual(StillPipeline.pieceCountCeiling(longSide: 2560, tier: .reduced, override: 20), 6,
                       "降載封頂 6 不因使用者指定而失效")
    }

    // MARK: - 每輪抽張數

    /// 同 seed 同張數，否則整條管線就不可重現了。
    func testDrawnPieceCountIsDeterministic() {
        for seed in UInt64(1)...20 {
            XCTAssertEqual(StillPipeline.drawnPieceCount(ceiling: 16, seed: seed),
                           StillPipeline.drawnPieceCount(ceiling: 16, seed: seed))
        }
    }

    /// 永遠落在 1...上限。0 或負的上限也不能吐出 0 片——那會合成出一張空圖。
    func testDrawnPieceCountStaysInRange() {
        for ceiling in [1, 2, 6, 16, 20] {
            for seed in UInt64(1)...80 {
                let drawn = StillPipeline.drawnPieceCount(ceiling: ceiling, seed: seed)
                XCTAssertGreaterThanOrEqual(drawn, 1)
                XCTAssertLessThanOrEqual(drawn, ceiling)
            }
        }
        XCTAssertEqual(StillPipeline.drawnPieceCount(ceiling: 0, seed: 1), 1,
                       "上限 0 不能吐出 0 片——那會合成一張只有背景的空圖")
        XCTAssertEqual(StillPipeline.drawnPieceCount(ceiling: -5, seed: 1), 1)
        for seed in UInt64(1)...20 {
            XCTAssertLessThanOrEqual(StillPipeline.drawnPieceCount(ceiling: 999, seed: seed),
                                     MontageComposer.pieceCountRange.upperBound,
                                     "超出範圍的上限要先被夾住")
        }
    }

    /// 上限 1＝固定 1 張，不再隨機。
    func testDrawnPieceCountOfOneIsAlwaysOne() {
        for seed in UInt64(1)...20 {
            XCTAssertEqual(StillPipeline.drawnPieceCount(ceiling: 1, seed: seed), 1)
        }
    }

    /// 真的有在變：80 顆 seed 掃過去要看到夠多不同的張數，
    /// 否則「每輪隨機」就只是寫在註解裡而已。
    func testDrawnPieceCountActuallyVaries() {
        let drawn = Set((UInt64(1)...80).map {
            StillPipeline.drawnPieceCount(ceiling: 16, seed: $0)
        })
        XCTAssertGreaterThan(drawn.count, 10, "16 個可能值只出現 \(drawn.count) 種，太集中")
        XCTAssertTrue(drawn.contains { $0 <= 3 }, "應該偶爾出現只有兩三張的稀疏構圖")
        XCTAssertTrue(drawn.contains { $0 >= 13 }, "應該偶爾出現接近上限的密構圖")
    }

    // MARK: - 解碼上限

    /// 短邊 × maxPieceScale(0.62) × densityScale(片數) × pieceAspectAllowance(1.8)。
    /// 片數 6 是密度基準（densityScale == 1），所以這幾個值就是純粹的片需求。
    /// 門檻定死，改了要一起改。
    func testDecodeMaxPixelFollowsShortSideNotLongSide() {
        XCTAssertEqual(
            StillPipeline.decodeMaxPixel(canvas: CGSize(width: 5120, height: 2880), pieceCount: 6),
            3214)
        XCTAssertEqual(
            StillPipeline.decodeMaxPixel(canvas: CGSize(width: 3456, height: 2234), pieceCount: 6),
            2493)
        XCTAssertEqual(
            StillPipeline.decodeMaxPixel(canvas: CGSize(width: 2560, height: 1440), pieceCount: 6),
            1607)
    }

    /// 這個改動的重點：別再按畫布長邊解。記憶體是按**面積**算的，所以斷言面積比。
    /// 畫布越接近 3:2（短邊相對大）省得越少，16:10／超寬省最多——都要在半數以下。
    func testDecodeMaxPixelCutsDecodedAreaVersusCanvasLongSide() {
        for canvas in [CGSize(width: 5120, height: 2880),   // 5K，~0.39
                       CGSize(width: 5120, height: 1440),   // 超寬，~0.25（吃背景地板）
                       CGSize(width: 3456, height: 2234)] { // 16" MBP，接近 3:2，~0.52
            let longSide = max(canvas.width, canvas.height)
            let maxPixel = CGFloat(StillPipeline.decodeMaxPixel(canvas: canvas, pieceCount: 6))
            XCTAssertLessThanOrEqual(pow(maxPixel / longSide, 2), 0.6,
                                     "\(canvas) 每張圖的解碼面積應降到舊規則的六成以下")
        }
    }

    /// 片數越多每片越小，該解的也越少——單調不遞增。
    func testDecodeMaxPixelShrinksAsPieceCountGrows() {
        let canvas = CGSize(width: 5120, height: 2880)
        let byCount = (1...MontageComposer.pieceCountRange.upperBound).map {
            StillPipeline.decodeMaxPixel(canvas: canvas, pieceCount: $0)
        }
        XCTAssertEqual(byCount, byCount.sorted(by: >), "片數變多時解碼上限不該變大")
        XCTAssertGreaterThan(byCount.first!, byCount.last!, "1 片與 20 片不該解一樣大")
    }

    /// 上限從 12 開到 20，記憶體不能跟著失控——這才是敢開的前提。
    /// 峰值 ∝ (片數 + 1 張背景) × 解碼面積。
    func testRaisingTheCeilingDoesNotBlowUpTheDecodeBudget() {
        let canvas = CGSize(width: 5120, height: 2880)
        func budget(_ count: Int) -> CGFloat {
            let side = CGFloat(StillPipeline.decodeMaxPixel(canvas: canvas, pieceCount: count))
            return CGFloat(count + 1) * side * side
        }
        let ceiling = MontageComposer.pieceCountRange.upperBound
        XCTAssertLessThanOrEqual(budget(ceiling), budget(6) * 2,
                                 "\(ceiling) 片的解碼量不該超過 6 片的兩倍")
    }

    /// 超寬螢幕短邊小、片的需求跟著小，但背景仍要鋪滿 5120——由地板接住。
    func testBackdropFloorTakesOverOnUltrawide() {
        let canvas = CGSize(width: 5120, height: 1440)
        let piece = 1440 * MontageComposer.maxPieceScale * StillPipeline.pieceAspectAllowance
        XCTAssertLessThan(piece, 2560, "前提：這台的片需求低於地板，否則測不到地板")
        XCTAssertEqual(StillPipeline.decodeMaxPixel(canvas: canvas, pieceCount: 6), 2560, "長邊 5120 / 2")
    }

    /// 不管畫布什麼形狀、幾片，橫幅背景的放大倍數都不該超過 backdropMaxUpscale。
    func testBackdropIsNeverUpscaledBeyondCap() {
        for canvas in [CGSize(width: 5120, height: 1440),
                       CGSize(width: 5120, height: 2880),
                       CGSize(width: 3456, height: 2234),
                       CGSize(width: 1440, height: 2560),
                       CGSize(width: 1000, height: 1000)] {
            for count in [1, 6, 12, MontageComposer.pieceCountRange.upperBound] {
                let longSide = max(canvas.width, canvas.height)
                let upscale = longSide
                    / CGFloat(StillPipeline.decodeMaxPixel(canvas: canvas, pieceCount: count))
                XCTAssertLessThanOrEqual(upscale, StillPipeline.backdropMaxUpscale,
                                         "\(canvas) / \(count) 片：背景會被放大 \(upscale)x")
            }
        }
    }

    /// 直式／方形畫布上公式會超過長邊——解到長邊就到頂，不要解得比畫布還大。
    /// 1 片時 densityScale 會把片放大 1.4 倍，最容易撞到這條。
    func testDecodeMaxPixelNeverExceedsCanvasLongSide() {
        for canvas in [CGSize(width: 1000, height: 1000),
                       CGSize(width: 1440, height: 2560),
                       CGSize(width: 8, height: 8)] {
            for count in [1, 6, MontageComposer.pieceCountRange.upperBound] {
                XCTAssertLessThanOrEqual(
                    StillPipeline.decodeMaxPixel(canvas: canvas, pieceCount: count),
                    Int(max(canvas.width, canvas.height)))
            }
        }
    }

    /// 直向／橫向同一台螢幕轉一圈，解碼上限不該變（短邊一樣）。
    func testDecodeMaxPixelIsOrientationAgnostic() {
        XCTAssertEqual(
            StillPipeline.decodeMaxPixel(canvas: CGSize(width: 2560, height: 1440), pieceCount: 6),
            StillPipeline.decodeMaxPixel(canvas: CGSize(width: 1440, height: 2560), pieceCount: 6))
    }

    /// 上限必須真的蓋得住一片：片的長邊 = 短邊 × maxPieceScale × densityScale × 長寬比，
    /// 16:9 的來源圖在任何片數下都要是原尺寸貼上、不能被放大。
    func testDecodeMaxPixelCoversAFullSizePieceAtSixteenNine() {
        let canvas = CGSize(width: 5120, height: 2880)
        for count in 1...MontageComposer.pieceCountRange.upperBound {
            let widestPiece = min(canvas.width, canvas.height) * MontageComposer.maxPieceScale
                * MontageComposer.densityScale(pieceCount: count) * (16.0 / 9.0)
            XCTAssertGreaterThanOrEqual(
                CGFloat(StillPipeline.decodeMaxPixel(canvas: canvas, pieceCount: count)),
                widestPiece, "\(count) 片時 16:9 的來源會被放大")
        }
    }

    // MARK: - 共存與空池

    func testSkippedDisplayIsNeverWritten() async throws {
        let outcome = try await makePipeline().refresh(
            displays: [displayA, displayB], skipIDs: [displayA.id],
            pool: SourcePool(pool), effect: .none, tier: .full, cycleNonce: 1
        )
        XCTAssertEqual(desktop.calls.map(\.id), [displayB.id], "播影片的螢幕一次都不能寫")
        XCTAssertEqual(outcome.written, [displayB.id])
        XCTAssertEqual(outcome.skipped, [displayA.id])
    }

    func testEmptyPoolWritesNothing() async throws {
        let outcome = try await makePipeline().refresh(
            displays: [displayA, displayB], skipIDs: [],
            pool: SourcePool([]), effect: .none, tier: .full, cycleNonce: 1
        )
        XCTAssertTrue(desktop.calls.isEmpty, "空池必須保留現桌布，不可寫黑圖")
        XCTAssertTrue(outcome.poolWasEmpty)
        XCTAssertTrue(outcome.written.isEmpty)
    }

    func testAllUndecodablePoolWritesNothing() async throws {
        let broken = root.appending(path: "broken.jpg")
        try Data("garbage".utf8).write(to: broken)
        let outcome = try await makePipeline().refresh(
            displays: [displayA], skipIDs: [], pool: SourcePool([broken]),
            effect: .none, tier: .full, cycleNonce: 1
        )
        XCTAssertTrue(desktop.calls.isEmpty, "全是壞檔等同空池")
        XCTAssertTrue(outcome.poolWasEmpty)
    }

    // MARK: - 檔名與保留策略

    func testEachCycleUsesFreshFilename() async throws {
        let pipeline = makePipeline()
        try await pipeline.refresh(displays: [displayA], skipIDs: [], pool: SourcePool(pool),
                             effect: .none, tier: .full, cycleNonce: 1)
        try await pipeline.refresh(displays: [displayA], skipIDs: [], pool: SourcePool(pool),
                             effect: .none, tier: .full, cycleNonce: 2)

        let urls = desktop.calls.map(\.url)
        XCTAssertEqual(urls.count, 2)
        XCTAssertNotEqual(urls[0], urls[1],
                          "同 URL 重設是 no-op，每輪必須換檔名")
    }

    func testKeepsOnlyTwoGenerations() async throws {
        let pipeline = makePipeline()
        for nonce in UInt64(1)...4 {
            try await pipeline.refresh(displays: [displayA], skipIDs: [], pool: SourcePool(pool),
                                 effect: .none, tier: .full, cycleNonce: nonce)
        }
        let remaining = try FileManager.default
            .contentsOfDirectory(atPath: paths.wallpapers.path)
            .filter { $0.hasSuffix(".jpg") }
        XCTAssertEqual(remaining.count, 2, "只留當前輪＋上一輪")
    }

    /// Space 切換的補設要拿「最新一輪」那張：nonce 最大的、而且只認自己螢幕的檔。
    func testLatestStillPicksNewestNonceForOwnDisplay() async throws {
        let pipeline = makePipeline()
        for nonce in UInt64(1)...2 {
            try await pipeline.refresh(displays: [displayA, displayB], skipIDs: [],
                                       pool: SourcePool(pool), effect: .none, tier: .full,
                                       cycleNonce: nonce)
        }
        let latest = try XCTUnwrap(pipeline.latestStillURL(displayUUID: displayA.uuid))
        XCTAssertEqual(latest.lastPathComponent, "AAAA-2.jpg")
        XCTAssertNil(pipeline.latestStillURL(displayUUID: "CCCC"), "沒合成過的螢幕要回 nil")
    }

    func testReapplyLatestStillSetsNewestAndSkipsUnknownDisplay() async throws {
        let pipeline = makePipeline()
        try await pipeline.refresh(displays: [displayA], skipIDs: [], pool: SourcePool(pool),
                                   effect: .none, tier: .full, cycleNonce: 7)
        let written = desktop.calls.count
        await pipeline.reapplyLatestStill(display: displayA)
        XCTAssertEqual(desktop.calls.count, written + 1)
        XCTAssertEqual(desktop.calls.last?.url.lastPathComponent, "AAAA-7.jpg")

        await pipeline.reapplyLatestStill(display: displayB)
        XCTAssertEqual(desktop.calls.count, written + 1, "沒有現成合成結果就什麼都不設")
    }

    func testWallpapersLiveOutsideCaches() {
        XCTAssertFalse(paths.wallpapers.path.contains("/Caches/"),
                       "桌布檔放 Caches 會被系統清掉＝重登入黑屏")
        XCTAssertTrue(paths.smbCache.path.contains("Caches"))
    }

    // MARK: - 抽片時剔除過小圖

    /// 索引只看副檔名，池裡會混進 icon。整池都太小 → 視同空池，保留現桌布。
    func testPoolOfOnlyTinyImagesIsTreatedAsEmpty() async throws {
        let dir = root.appending(path: "icons")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tiny = try (0..<5).map { index -> URL in
            let url = dir.appending(path: "icon\(index).png")
            try TestImage.writePNG(TestImage.solid(0.5, 0.5, 0.5, size: 64), to: url)
            return url
        }

        let outcome = try await makePipeline().refresh(
            displays: [displayA], skipIDs: [], pool: SourcePool(tiny),
            effect: .none, tier: .full, cycleNonce: 1
        )
        XCTAssertTrue(desktop.calls.isEmpty, "短邊 <256 的圖不該被拿去合成")
        XCTAssertTrue(outcome.poolWasEmpty)
        XCTAssertTrue(outcome.written.isEmpty, "沒圖可用就保留現桌布，不寫黑圖")
    }

    /// 混池：雜訊圖被換掉，合格圖照樣出得了圖。
    func testTinyImagesAreSkippedButPoolStillComposes() async throws {
        let dir = root.appending(path: "mixed")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var mixed: [URL] = []
        for index in 0..<12 {
            let url = dir.appending(path: "m\(index).png")
            try TestImage.writePNG(TestImage.solid(0.2, 0.6, 0.9, size: 64), to: url)
            mixed.append(url)
        }
        mixed.append(contentsOf: pool)   // pool 是 300px 的合格圖

        let outcome = try await makePipeline().refresh(
            displays: [displayA], skipIDs: [], pool: SourcePool(mixed),
            effect: .none, tier: .full, cycleNonce: 2
        )
        XCTAssertEqual(outcome.written, [displayA.id], "有合格圖就該出圖")
        XCTAssertFalse(outcome.poolWasEmpty)
    }

    // MARK: - 每螢不同

    func testDisplaysGetDifferentComposition() async throws {
        try await makePipeline().refresh(displays: [displayA, displayB], skipIDs: [],
                                   pool: SourcePool(pool), effect: .none, tier: .full, cycleNonce: 7)
        let files = desktop.calls.map { try! Data(contentsOf: $0.url) }
        XCTAssertEqual(files.count, 2)
        XCTAssertNotEqual(files[0], files[1], "每螢各自合成，構圖不該相同")
    }
}
