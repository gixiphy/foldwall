import XCTest
@testable import FoldwallCore

final class VideoEngineTests: XCTestCase {

    /// 兩條路的差別必須是明確的旗標，不能靠散在各處的 if 判斷。
    func testOnlyTheExtensionNeedsDeploymentAndSupportsLockScreen() {
        XCTAssertFalse(VideoEngine.desktopWindow.needsDeployment,
                       "桌面視窗直接播來源檔，拷貝是那條路才有的成本")
        XCTAssertTrue(VideoEngine.systemExtension.needsDeployment)

        XCTAssertFalse(VideoEngine.desktopWindow.supportsLockScreen,
                       "鎖屏畫面不歸 app 管")
        XCTAssertTrue(VideoEngine.systemExtension.supportsLockScreen)
    }

    func testEveryEngineExplainsItself() {
        for engine in VideoEngine.allCases {
            XCTAssertFalse(engine.displayName.isEmpty)
            XCTAssertFalse(engine.summary.isEmpty)
        }
        XCTAssertTrue(VideoEngine.desktopWindow.summary.contains("鎖屏"),
                      "取捨要寫在使用者看得到的地方")
    }

    func testEnginesSurviveEncoding() throws {
        for engine in VideoEngine.allCases {
            let data = try JSONEncoder().encode(engine)
            XCTAssertEqual(try JSONDecoder().decode(VideoEngine.self, from: data), engine)
        }
        for layer in DesktopVideoLayer.allCases {
            let data = try JSONEncoder().encode(layer)
            XCTAssertEqual(try JSONDecoder().decode(DesktopVideoLayer.self, from: data), layer)
        }
    }
}

final class VideoPlaybackPlanTests: XCTestCase {

    private func video(_ name: String) -> URL { URL(filePath: "/videos/\(name)") }

    func testEveryMarkedScreenGetsSomethingToPlay() {
        let plan = VideoPlaybackPlan.assign(
            screens: ["A", "B"], videos: [video("1.mp4"), video("2.mp4")])
        XCTAssertEqual(Set(plan.keys), ["A", "B"])
    }

    /// 兩台螢幕不該播到同一部——那看起來像壞掉。
    func testTwoScreensGetDifferentVideos() {
        let plan = VideoPlaybackPlan.assign(
            screens: ["A", "B"], videos: [video("1.mp4"), video("2.mp4"), video("3.mp4")])
        XCTAssertNotEqual(plan["A"], plan["B"])
    }

    /// 只有一支影片時只能重複，但不能留空螢幕。
    func testSingleVideoIsReusedRatherThanLeavingAScreenBlank() {
        let plan = VideoPlaybackPlan.assign(screens: ["A", "B"], videos: [video("1.mp4")])
        XCTAssertEqual(plan["A"], video("1.mp4"))
        XCTAssertEqual(plan["B"], video("1.mp4"))
    }

    /// cycle 前進就換一批，這是「每次螢幕亮起看到新的」的來源。
    func testCycleShiftsTheSelection() {
        let videos = (1...4).map { video("\($0).mp4") }
        let first = VideoPlaybackPlan.assign(screens: ["A"], videos: videos, cycle: 0)
        let second = VideoPlaybackPlan.assign(screens: ["A"], videos: videos, cycle: 1)
        XCTAssertNotEqual(first["A"], second["A"])
    }

    func testStableOrderRegardlessOfInputOrder() {
        let videos = [video("b.mp4"), video("a.mp4"), video("c.mp4")]
        let forward = VideoPlaybackPlan.assign(screens: ["A"], videos: videos)
        let reversed = VideoPlaybackPlan.assign(screens: ["A"], videos: videos.reversed())
        XCTAssertEqual(forward, reversed, "順序不該影響播到哪一支")
    }

    // MARK: - 黏著：影片不跟著蒙太奇換

    /// 這條是回報的 bug：assign 的位置由池的**內容**決定，而池每輪都在變
    /// （下載落地、快取淘汰、索引重掃、失敗冷卻），所以 cycle 沒動影片也會被換掉。
    func testKeepingSurvivesPoolChanges() {
        let a = video("a.mp4"), b = video("b.mp4"), c = video("c.mp4")
        let current = ["S1": b]

        // 池多了一支、少了一支、順序也變了——正在播的那支仍在池裡就該續播
        let plan = VideoPlaybackPlan.keeping(
            current: current, screens: ["S1"], videos: [c, b, a], cycle: 0)
        XCTAssertEqual(plan["S1"], b, "還在池裡就繼續播，不要重新選")
    }

    func testKeepingReassignsWhenCurrentVideoIsGone() {
        let a = video("a.mp4"), b = video("b.mp4")
        let plan = VideoPlaybackPlan.keeping(
            current: ["S1": video("deleted.mp4")], screens: ["S1"], videos: [a, b])
        XCTAssertNotNil(plan["S1"])
        XCTAssertTrue([a, b].contains(plan["S1"]!), "原本那支不見了才重新選")
    }

    func testKeepingFillsScreensThatArePlayingNothing() {
        let a = video("a.mp4"), b = video("b.mp4")
        let plan = VideoPlaybackPlan.keeping(
            current: ["S1": a], screens: ["S1", "S2"], videos: [a, b])
        XCTAssertEqual(plan["S1"], a, "S1 續播")
        XCTAssertEqual(plan["S2"], b, "S2 拿沒被沿用的那支")
    }

    /// 兩台螢幕不該播到同一支——即使 current 裡兩台都記著同一支。
    func testKeepingDoesNotLetTwoScreensShareOneVideo() {
        let a = video("a.mp4"), b = video("b.mp4")
        let plan = VideoPlaybackPlan.keeping(
            current: ["S1": a, "S2": a], screens: ["S1", "S2"], videos: [a, b])
        XCTAssertNotEqual(plan["S1"], plan["S2"])
    }

    /// 只有一支影片時只能重複，但不能留空螢幕。
    func testKeepingReusesWhenThereIsOnlyOneVideo() {
        let a = video("a.mp4")
        let plan = VideoPlaybackPlan.keeping(
            current: ["S1": a], screens: ["S1", "S2"], videos: [a])
        XCTAssertEqual(plan["S1"], a)
        XCTAssertEqual(plan["S2"], a)
    }

    func testKeepingWithEmptyInputsIsSafe() {
        XCTAssertTrue(VideoPlaybackPlan.keeping(current: [:], screens: [], videos: [video("1.mp4")]).isEmpty)
        XCTAssertTrue(VideoPlaybackPlan.keeping(current: [:], screens: ["A"], videos: []).isEmpty)
    }

    func testEmptyInputsAreSafe() {
        XCTAssertTrue(VideoPlaybackPlan.assign(screens: [], videos: [video("1.mp4")]).isEmpty)
        XCTAssertTrue(VideoPlaybackPlan.assign(screens: ["A"], videos: []).isEmpty)
    }
}
