import XCTest
@testable import FoldwallCore

/// yt-dlp 的執行環境、JS runtime 偵測、失敗分類、片單整體冷卻。
final class VideoDownloadEnvironmentTests: XCTestCase {

    private let home = URL(filePath: "/Users/someone")
    private let tool = URL(filePath: "/opt/homebrew/bin/yt-dlp")

    // MARK: - 環境

    func testPathStartsWithTheToolDirectoryThenTheKnownInstallLocations() {
        let env = VideoDownloadTool.environment(
            tool: URL(filePath: "/custom/place/yt-dlp"), home: home,
            inherited: ["PATH": "/somewhere/else:/bin"])
        let path = env["PATH"]!.split(separator: ":").map(String.init)
        XCTAssertEqual(path.first, "/custom/place")
        XCTAssertTrue(path.contains("/opt/homebrew/bin"), "deno 在這裡")
        XCTAssertTrue(path.contains("/Users/someone/.local/bin"), "node 常在這裡")
        XCTAssertEqual(Array(path.suffix(2)), ["/somewhere/else", "/bin"], "繼承到的 PATH 接在後面")
    }

    func testPathHasNoDuplicates() {
        let env = VideoDownloadTool.environment(
            tool: tool, home: home, inherited: ["PATH": "/opt/homebrew/bin:/usr/bin:/opt/homebrew/bin"])
        let path = env["PATH"]!.split(separator: ":").map(String.init)
        XCTAssertEqual(path.count, Set(path).count, "\(path)")
        XCTAssertEqual(path.first, "/opt/homebrew/bin")
    }

    func testEnvironmentWithoutAnInheritedPathStillWorks() {
        // GUI app 從 LaunchServices 起來時就是這樣：什麼都沒有
        let env = VideoDownloadTool.environment(tool: tool, home: home, inherited: [:])
        XCTAssertTrue(env["PATH"]!.contains("/opt/homebrew/bin"))
        XCTAssertTrue(env["PATH"]!.contains("/usr/bin"), "系統目錄要補回來")
        XCTAssertEqual(env["HOME"], "/Users/someone", "yt-dlp 的快取與 cookie 資料庫都靠它")
        XCTAssertNil(env["TMPDIR"], "沒有就不捏造")
    }

    func testOnlyWhitelistedVariablesPassThrough() {
        let env = VideoDownloadTool.environment(
            tool: tool, home: home,
            inherited: ["PATH": "/usr/bin", "HOME": "/h", "TMPDIR": "/t", "LANG": "zh_TW.UTF-8",
                        "DYLD_INSERT_LIBRARIES": "/evil", "SECRET_TOKEN": "x"])
        XCTAssertEqual(env["HOME"], "/h")
        XCTAssertEqual(env["TMPDIR"], "/t")
        XCTAssertEqual(env["LANG"], "zh_TW.UTF-8")
        XCTAssertNil(env["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(env["SECRET_TOKEN"])
    }

    // MARK: - JS runtime

    func testFindsDenoBeforeNode() {
        let installed: Set<String> = ["/opt/homebrew/bin/deno", "/Users/someone/.local/bin/node"]
        let found = VideoDownloadTool.locateJavaScriptRuntime(home: home) { installed.contains($0) }
        XCTAssertEqual(found?.path, "/opt/homebrew/bin/deno")
    }

    func testFallsBackToNodeInUserLocalBin() {
        let installed: Set<String> = ["/Users/someone/.local/bin/node"]
        let found = VideoDownloadTool.locateJavaScriptRuntime(home: home) { installed.contains($0) }
        XCTAssertEqual(found?.path, "/Users/someone/.local/bin/node")
    }

    func testNoRuntimeMeansNil() {
        XCTAssertNil(VideoDownloadTool.locateJavaScriptRuntime(home: home) { _ in false })
    }

    // MARK: - 失敗分類

    private let challengeFailure = """
        WARNING: [youtube] abc: n challenge solving failed: Some formats may be missing. \
        Ensure you have a supported JavaScript runtime and challenge solver script distribution installed.
        WARNING: Only images are available for download. use --list-formats to see them
        ERROR: [youtube] abc: Requested format is not available. Use --list-formats for a list of available formats
        """

    func testMissingRuntimeIsNamedEvenThoughTheLastLineSaysFormat() {
        XCTAssertEqual(
            VideoDownloadTool.downloadFailureHint(challengeFailure, ffmpeg: nil, javaScriptRuntime: nil),
            .missingJavaScriptRuntime,
            "缺 deno 的人不能被指去裝 ffmpeg")
    }

    func testRuntimePresentButChallengeStillFailsPointsAtTheRuntime() {
        let deno = URL(filePath: "/opt/homebrew/bin/deno")
        XCTAssertEqual(
            VideoDownloadTool.downloadFailureHint(
                challengeFailure, ffmpeg: URL(filePath: "/opt/homebrew/bin/ffmpeg"), javaScriptRuntime: deno),
            .javaScriptChallengeFailed(runtime: deno))
    }

    func testFormatUnavailableWithoutFFmpegIsTheFFmpegCase() {
        XCTAssertEqual(
            VideoDownloadTool.downloadFailureHint(
                "ERROR: Requested format is not available", ffmpeg: nil, javaScriptRuntime: nil),
            .missingFFmpeg)
    }

    func testUnrelatedFailuresGetNoHint() {
        XCTAssertNil(VideoDownloadTool.downloadFailureHint(
            "ERROR: Video unavailable. This video is private",
            ffmpeg: nil, javaScriptRuntime: nil))
    }

    // MARK: - 整體冷卻

    func testThreeConsecutiveFailuresPauseTheWholePlaylist() {
        var backoff = DownloadBackoff()
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertFalse(backoff.recordFailure(now: now))
        XCTAssertFalse(backoff.recordFailure(now: now))
        XCTAssertFalse(backoff.isPaused(now: now), "兩次還不算證據")
        XCTAssertTrue(backoff.recordFailure(now: now), "第三次剛好觸發，回 true 讓呼叫端記一次 log")
        XCTAssertTrue(backoff.isPaused(now: now))
        XCTAssertFalse(backoff.recordFailure(now: now), "已經在停了，不重複觸發")
    }

    func testPauseExpires() {
        var backoff = DownloadBackoff()
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        for _ in 0..<3 { backoff.recordFailure(now: now) }
        XCTAssertTrue(backoff.isPaused(now: now.addingTimeInterval(DownloadBackoff.pause - 1)))
        XCTAssertFalse(backoff.isPaused(now: now.addingTimeInterval(DownloadBackoff.pause)))
    }

    func testAfterExpiryTheNextFailurePausesAgainImmediately() {
        var backoff = DownloadBackoff()
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        for _ in 0..<3 { backoff.recordFailure(now: now) }
        let later = now.addingTimeInterval(DownloadBackoff.pause + 1)
        XCTAssertTrue(backoff.recordFailure(now: later), "環境沒修好，不必重新累積三次")
        XCTAssertTrue(backoff.isPaused(now: later))
    }

    func testOneSuccessResetsEverything() {
        var backoff = DownloadBackoff()
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        for _ in 0..<3 { backoff.recordFailure(now: now) }
        backoff.recordSuccess()
        XCTAssertFalse(backoff.isPaused(now: now))
        XCTAssertEqual(backoff.consecutiveFailures, 0)
        XCTAssertFalse(backoff.recordFailure(now: now), "從頭數")
    }
}
