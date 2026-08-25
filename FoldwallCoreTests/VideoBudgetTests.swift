import XCTest
@testable import FoldwallCore

final class VideoBudgetTests: XCTestCase {

    private let mb: Int64 = 1024 * 1024

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/videos/\(name)") }

    private func sizes(_ pairs: [String: Int64]) -> (URL) -> Int64? {
        { pairs[$0.lastPathComponent] }
    }

    /// 小檔就帶滿三支。
    func testSmallClipsFillTheRotation() {
        let videos = ["a", "b", "c", "d"].map { url("\($0).mp4") }
        let rotation = VideoBudget.rotate(videos, cursor: 0) { _ in 10 * self.mb }

        XCTAssertEqual(rotation.selected.map(\.lastPathComponent), ["a.mp4", "b.mp4", "c.mp4"])
        XCTAssertEqual(rotation.nextCursor, 3, "下一輪從第 4 支接著走")
    }

    /// 一支大的就只帶一支——「1~3 支視影片大小而定」。
    func testOneLargeClipTakesTheWholeRotation() {
        let videos = [url("big.mp4"), url("small.mp4")]
        let rotation = VideoBudget.rotate(
            videos, cursor: 0,
            size: sizes(["big.mp4": 500 * mb, "small.mp4": 100 * mb])
        )
        XCTAssertEqual(rotation.selected.map(\.lastPathComponent), ["big.mp4"],
                       "500MB 已經吃掉整輪額度")
    }

    /// 游標會繞回開頭，整個片庫才輪得到。
    func testCursorWrapsAround() {
        let videos = ["a", "b", "c", "d"].map { url("\($0).mp4") }
        let rotation = VideoBudget.rotate(videos, cursor: 3) { _ in 10 * self.mb }

        XCTAssertEqual(rotation.selected.map(\.lastPathComponent), ["d.mp4", "a.mp4", "b.mp4"])
        XCTAssertEqual(rotation.nextCursor, 2)
    }

    /// 連續輪替走遍全庫，不會卡在同一批。
    func testRotationEventuallyCoversEverything() {
        let videos = (0..<9).map { url("v\($0).mp4") }
        var cursor = 0
        var seen: Set<String> = []
        for _ in 0..<3 {
            let rotation = VideoBudget.rotate(videos, cursor: cursor) { _ in 10 * self.mb }
            seen.formUnion(rotation.selected.map(\.lastPathComponent))
            cursor = rotation.nextCursor
        }
        XCTAssertEqual(seen.count, 9, "三輪之後九支都輪過了")
    }

    /// GB 級長片是片庫內容，不是桌布素材：直接跳過，繼續看後面的。
    func testOversizedFilesAreSkippedNotBlocking() {
        let videos = [url("movie.mp4"), url("loop.mp4")]
        let rotation = VideoBudget.rotate(
            videos, cursor: 0,
            size: sizes(["movie.mp4": 2400 * mb, "loop.mp4": 20 * mb])
        )
        XCTAssertEqual(rotation.selected.map(\.lastPathComponent), ["loop.mp4"])
    }

    func testFileExactlyAtPerFileLimitIsAccepted() {
        let rotation = VideoBudget.rotate(
            [url("edge.mp4")], cursor: 0,
            size: sizes(["edge.mp4": VideoBudget.maxFileBytes])
        )
        XCTAssertEqual(rotation.selected.count, 1, "剛好等於上限要放行")
    }

    /// 全部都超過單檔上限時要能收手，不能空轉。
    func testAllOversizedYieldsEmptyRotation() {
        let videos = (0..<5).map { url("big\($0).mp4") }
        let rotation = VideoBudget.rotate(videos, cursor: 0) { _ in 4000 * self.mb }
        XCTAssertTrue(rotation.selected.isEmpty)
    }

    func testUnreadableSizeIsSkipped() {
        let videos = [url("gone.mp4"), url("ok.mp4")]
        let rotation = VideoBudget.rotate(videos, cursor: 0) {
            $0.lastPathComponent == "gone.mp4" ? nil : 10 * self.mb
        }
        XCTAssertEqual(rotation.selected.map(\.lastPathComponent), ["ok.mp4"],
                       "大小讀不到（離線／壞檔）就跳過")
    }

    func testEmptyLibraryIsSafe() {
        let rotation = VideoBudget.rotate([], cursor: 7) { _ in 1 }
        XCTAssertTrue(rotation.selected.isEmpty)
        XCTAssertEqual(rotation.nextCursor, 0)
    }

    func testOutOfRangeCursorRestartsFromZero() {
        let videos = ["a", "b"].map { url("\($0).mp4") }
        let rotation = VideoBudget.rotate(videos, cursor: 99) { _ in 10 * self.mb }
        XCTAssertEqual(rotation.selected.first?.lastPathComponent, "a.mp4",
                       "片庫縮小後游標超出範圍，要從頭開始而不是爆掉")
    }

    // MARK: - 網路來源的名額

    /// 實測：資料夾 4596 支、網路 6 支。混在一起排序輪替的話，游標要繞完 4602 支
    /// 才碰得到網路那 6 支——一次 3 支等於一千多輪，加了來源卻永遠看不到。
    func testRemoteAlwaysGetsASlotWhenFolderLibraryIsHuge() {
        XCTAssertEqual(VideoBudget.remoteSlots(remoteCount: 6, folderCount: 4596), 1)
    }

    func testRemoteTakesWholeRotationWhenNoFolderVideos() {
        XCTAssertEqual(VideoBudget.remoteSlots(remoteCount: 6, folderCount: 0),
                       VideoBudget.rotationCount)
    }

    func testNoRemoteMeansNoSlot() {
        XCTAssertEqual(VideoBudget.remoteSlots(remoteCount: 0, folderCount: 4596), 0)
    }

    func testRotationReportsUsedBytesForMixedBudget() {
        let videos = [url("a.mp4"), url("b.mp4")]
        let rotation = VideoBudget.rotate(videos, cursor: 0, count: 2) { _ in 30 * self.mb }
        XCTAssertEqual(rotation.usedBytes, 60 * mb, "混合來源要靠這個算剩餘額度")
    }

    func testDefaultsAreConservative() {
        XCTAssertEqual(VideoBudget.rotationCount, 3)
        XCTAssertEqual(VideoBudget.rotationBytes, 512 * 1024 * 1024)
        XCTAssertEqual(VideoBudget.maxFileBytes, 512 * 1024 * 1024)
    }
}
