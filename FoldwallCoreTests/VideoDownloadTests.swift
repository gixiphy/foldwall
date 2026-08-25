import XCTest
@testable import FoldwallCore

final class VideoDownloadTests: XCTestCase {

    /// GUI app 不繼承 shell 的 PATH——從 LaunchServices 啟動時
    /// /opt/homebrew/bin 根本不在環境變數裡。這條鎖住「自己去找」這件事。
    func testLooksInHomebrewAndOtherCommonLocations() {
        XCTAssertTrue(VideoDownloadTool.searchPaths.contains("/opt/homebrew/bin"),
                      "Apple Silicon 的 Homebrew 一定要找")
        XCTAssertTrue(VideoDownloadTool.searchPaths.contains("/usr/local/bin"))
    }

    func testLocateReturnsTheFirstExistingCandidate() {
        let found = VideoDownloadTool.locate(home: URL(filePath: "/Users/test")) {
            $0 == "/usr/local/bin/yt-dlp"
        }
        XCTAssertEqual(found?.path, "/usr/local/bin/yt-dlp")
    }

    func testLocateFallsBackToUserLocalBin() {
        let found = VideoDownloadTool.locate(home: URL(filePath: "/Users/test")) {
            $0 == "/Users/test/.local/bin/yt-dlp"
        }
        XCTAssertEqual(found?.path, "/Users/test/.local/bin/yt-dlp")
    }

    func testLocateReturnsNilWhenNothingIsInstalled() {
        XCTAssertNil(VideoDownloadTool.locate(home: URL(filePath: "/Users/test")) { _ in false })
    }

    /// 貼到播放清單網址時只該抓那一支，不是整份清單。
    func testDoesNotDownloadWholePlaylists() {
        let args = VideoDownloadTool.arguments(url: "https://example.com/v",
                                               destination: URL(filePath: "/tmp/out"))
        XCTAssertTrue(args.contains("--no-playlist"))
    }

    /// 只取單一檔案：合併要 ffmpeg，使用者不見得裝了，失敗訊息又很難懂。
    func testFormatAvoidsFormatsThatNeedMerging() throws {
        let args = VideoDownloadTool.arguments(url: "https://example.com/v",
                                               destination: URL(filePath: "/tmp/out"))
        let format = try XCTUnwrap(args.firstIndex(of: "-f").map { args[$0 + 1] })
        XCTAssertFalse(format.contains("+"), "帶 + 的格式需要 ffmpeg 合併")
        XCTAssertTrue(format.contains("height<=1080"), "桌布不需要 4K")
    }

    func testOutputGoesToTheGivenDirectory() throws {
        let args = VideoDownloadTool.arguments(url: "https://example.com/v",
                                               destination: URL(filePath: "/tmp/out"))
        let template = try XCTUnwrap(args.firstIndex(of: "-o").map { args[$0 + 1] })
        XCTAssertTrue(template.hasPrefix("/tmp/out/"))
        XCTAssertTrue(template.contains("%(ext)s"))
    }

    /// 半成品不能留在來源目錄裡，否則會被當成影片播。
    func testNoPartialFilesLeftBehind() {
        let args = VideoDownloadTool.arguments(url: "https://example.com/v",
                                               destination: URL(filePath: "/tmp/out"))
        XCTAssertTrue(args.contains("--no-part"))
    }

    func testPlausibilityRejectsObviousMistakes() {
        XCTAssertTrue(VideoDownloadTool.isPlausible("https://example.com/watch?v=1"))
        XCTAssertTrue(VideoDownloadTool.isPlausible("  http://example.com/v  "))
        for bad in ["", "   ", "not a url", "ftp://example.com/v", "example.com/v"] {
            XCTAssertFalse(VideoDownloadTool.isPlausible(bad), "應擋下：\(bad)")
        }
    }

    /// 網址下載的影片跟網路來源的影片存**同一個目錄**。
    ///
    /// 原本刻意分開（下載的放 ~/Movies，理由是「使用者主動要的東西不該被當快取清掉」），
    /// 但兩邊最後都進同一個影片池，分開存的結果是同一支影片存兩份——
    /// 實測用網址抓一支 Pexels 的影片，就會跟該來源已經快取的那份並存。
    ///
    /// **代價是它們一起受 2 GB 上限與汰舊管**，這是明確選擇的取捨，不是疏忽。
    func testDownloadedVideosShareTheRemoteVideoCache() {
        let paths = AppPaths.standard()
        XCTAssertEqual(paths.downloadedVideos, paths.remoteVideoCache)
        XCTAssertTrue(paths.downloadedVideos.path.contains("/Caches/"))
    }

    /// 舊路徑保留著，但只給搬遷用——不再寫入。
    func testLegacyLocationIsStillAddressableForMigration() {
        XCTAssertTrue(AppPaths.standard().legacyDownloadedVideos.path.contains("/Movies/"))
        XCTAssertNotEqual(AppPaths.standard().legacyDownloadedVideos,
                          AppPaths.standard().downloadedVideos)
    }

    func testStatesDescribeThemselves() {
        XCTAssertEqual(VideoDownloadState.idle.summary, "")
        XCTAssertTrue(VideoDownloadState.finished(name: "a.mp4").summary.contains("a.mp4"))
        XCTAssertTrue(VideoDownloadState.failed(reason: "壞了").summary.contains("壞了"))
    }
}
