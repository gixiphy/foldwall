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

    func testPieceCountFollowsLongSide() {
        XCTAssertEqual(StillPipeline.pieceCount(longSide: 5120, tier: .full), 10)
        XCTAssertEqual(StillPipeline.pieceCount(longSide: 6016, tier: .full), 10)
        XCTAssertEqual(StillPipeline.pieceCount(longSide: 3456, tier: .full), 8)
        XCTAssertEqual(StillPipeline.pieceCount(longSide: 2560, tier: .full), 6)
        XCTAssertEqual(StillPipeline.pieceCount(longSide: 5120, tier: .reduced), 6, "降載封頂 6")
    }

    func testPieceCountOverrideBeatsLongSide() {
        XCTAssertEqual(StillPipeline.pieceCount(longSide: 2560, tier: .full, override: 12), 12)
        XCTAssertEqual(StillPipeline.pieceCount(longSide: 5120, tier: .full, override: 4), 4)
        XCTAssertEqual(StillPipeline.pieceCount(longSide: 2560, tier: .full, override: nil), 6,
                       "nil＝自動，行為與沒有這個參數時相同")
    }

    func testPieceCountOverrideIsClampedAndStillCappedWhenReduced() {
        XCTAssertEqual(StillPipeline.pieceCount(longSide: 2560, tier: .full, override: 99),
                       MontageComposer.pieceCountRange.upperBound, "夾到合成端畫得出來的上限")
        XCTAssertEqual(StillPipeline.pieceCount(longSide: 2560, tier: .full, override: 0),
                       MontageComposer.pieceCountRange.lowerBound)
        XCTAssertEqual(StillPipeline.pieceCount(longSide: 2560, tier: .reduced, override: 12), 6,
                       "降載封頂 6 不因使用者指定而失效")
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
