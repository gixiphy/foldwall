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

    func testEmptyInputsAreSafe() {
        XCTAssertTrue(VideoPlaybackPlan.assign(screens: [], videos: [video("1.mp4")]).isEmpty)
        XCTAssertTrue(VideoPlaybackPlan.assign(screens: ["A"], videos: []).isEmpty)
    }
}
