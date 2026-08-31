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

    /// 沒有 ffmpeg 就只敢要單一檔案：帶 `+` 的格式合併不了。
    func testFormatAvoidsMergingWhenFFmpegIsMissing() throws {
        let args = VideoDownloadTool.arguments(url: "https://example.com/v",
                                               destination: URL(filePath: "/tmp/out"))
        let format = try XCTUnwrap(args.firstIndex(of: "-f").map { args[$0 + 1] })
        XCTAssertFalse(format.contains("+"), "帶 + 的格式需要 ffmpeg 合併")
        XCTAssertTrue(format.contains("height<=1080"), "桌布不需要 4K")
        XCTAssertFalse(args.contains("--ffmpeg-location"))
    }

    /// 有 ffmpeg 就要分離軌。
    ///
    /// 2026 年的 YouTube 幾乎不再給 muxed 格式——實測整張格式表只有 DASH
    /// 分離軌，只要單一檔案的話每一支都以「Requested format is not available」
    /// 收場，片單一支也抓不下來。
    func testFormatUsesSeparateTracksWhenFFmpegIsAvailable() throws {
        let args = VideoDownloadTool.arguments(
            url: "https://example.com/v",
            destination: URL(filePath: "/tmp/out"),
            ffmpeg: URL(filePath: "/opt/homebrew/bin/ffmpeg"))
        let format = try XCTUnwrap(args.firstIndex(of: "-f").map { args[$0 + 1] })
        XCTAssertTrue(format.hasPrefix("bv*[height<=1080]/"), "先要分離的視訊軌")
        XCTAssertTrue(format.contains("/b"), "還是要留單一檔案的退路")
        XCTAssertEqual(args.firstIndex(of: "--ffmpeg-location").map { args[$0 + 1] },
                       "/opt/homebrew/bin", "yt-dlp 要的是目錄，不是執行檔")
    }

    /// **桌布不出聲**（`DesktopVideoEngine` 一開場就 isMuted），音訊軌抓下來
    /// 只是躺在檔案裡佔空間——實測整個快取有 8.3% 是這樣來的。
    func testDoesNotDownloadTheAudioTrack() throws {
        let args = VideoDownloadTool.arguments(
            url: "https://example.com/v",
            destination: URL(filePath: "/tmp/out"),
            ffmpeg: URL(filePath: "/opt/homebrew/bin/ffmpeg"))
        let format = try XCTUnwrap(args.firstIndex(of: "-f").map { args[$0 + 1] })
        XCTAssertFalse(format.contains("+ba"), "不要音訊軌")
        XCTAssertFalse(args.contains("--merge-output-format"), "沒有合併這一步了")
    }

    /// 只要視訊軌就沒有「合併」，`--merge-output-format` 不再生效；
    /// 而 `-S "res,br"` 有時會挑到 webm 容器的 vp9，**AVFoundation 不 demux webm**。
    /// 少了 remux 就是抓下來卻整支播不了。
    func testRemuxesToMP4SoAVFoundationCanPlayIt() {
        let args = VideoDownloadTool.arguments(
            url: "https://example.com/v",
            destination: URL(filePath: "/tmp/out"),
            ffmpeg: URL(filePath: "/opt/homebrew/bin/ffmpeg"))
        XCTAssertEqual(args.firstIndex(of: "--remux-video").map { args[$0 + 1] }, "mp4")
    }

    /// yt-dlp 預設的排序鍵把 `vcodec` 排在 `br` **前面**，而預設偏好 av01——
    /// 那剛好是 YouTube 上位元率壓得最狠的一條。實測同一支 1080p60，
    /// 量的是抓下來的檔案：預設拿到 av01 557 kbps，加上這個排序拿到 avc1 1206 kbps。
    func testSortsByBitrateSoItDoesNotPickTheWorstStream() throws {
        let args = VideoDownloadTool.arguments(
            url: "https://example.com/v",
            destination: URL(filePath: "/tmp/out"),
            ffmpeg: URL(filePath: "/opt/homebrew/bin/ffmpeg"))
        XCTAssertEqual(args.firstIndex(of: "-S").map { args[$0 + 1] }, "res,br")
    }

    // MARK: - 畫質由使用者決定

    /// 0.6.8 以前這是寫死的 1080p。預設不能變，否則升上來的人畫質會突然不一樣。
    func testDefaultQualityMatchesTheOldHardCodedValue() {
        XCTAssertEqual(VideoDownloadQuality.default, .p1080)
        XCTAssertEqual(VideoDownloadQuality.default.maximumHeight, 1080)
    }

    func testEachQualityCapsTheFormatSelector() throws {
        let expected: [VideoDownloadQuality: String] = [
            .p720: "[height<=720]", .p1080: "[height<=1080]",
            .p1440: "[height<=1440]", .p2160: "[height<=2160]",
        ]
        for (quality, filter) in expected {
            let args = VideoDownloadTool.arguments(
                url: "https://example.com/v", destination: URL(filePath: "/tmp/out"),
                ffmpeg: URL(filePath: "/opt/homebrew/bin/ffmpeg"), quality: quality)
            let format = try XCTUnwrap(args.firstIndex(of: "-f").map { args[$0 + 1] })
            XCTAssertTrue(format.hasPrefix("bv*\(filter)/"), "\(quality) 該有 \(filter)")
        }
    }

    /// 「不設上限」就是真的不加過濾——不是換一個很大的數字。
    func testBestQualityAddsNoHeightFilterAtAll() throws {
        let args = VideoDownloadTool.arguments(
            url: "https://example.com/v", destination: URL(filePath: "/tmp/out"),
            ffmpeg: URL(filePath: "/opt/homebrew/bin/ffmpeg"), quality: .best)
        let format = try XCTUnwrap(args.firstIndex(of: "-f").map { args[$0 + 1] })
        XCTAssertFalse(format.contains("height<="), "不設上限就不該有高度過濾")
        XCTAssertTrue(format.hasPrefix("bv*/"))
        XCTAssertNil(VideoDownloadQuality.best.maximumHeight)
    }

    /// rawValue 躺在 UserDefaults 與備份檔裡，改掉等於把使用者的設定弄丟。
    func testQualityRawValuesAreStable() {
        XCTAssertEqual(VideoDownloadQuality.allCases.map(\.rawValue),
                       ["p720", "p1080", "p1440", "p2160", "best"])
    }

    // MARK: - 借瀏覽器的登入狀態

    /// 預設不借：那是把使用者的登入身分交給一個子行程去用，
    /// 要由他明確選擇，不該是預設行為。
    func testNoCookiesUnlessTheUserPicksABrowser() {
        let args = VideoDownloadTool.arguments(url: "https://example.com/v",
                                               destination: URL(filePath: "/tmp/out"))
        XCTAssertFalse(args.contains("--cookies-from-browser"))
        XCTAssertTrue(VideoCookieSource.none.arguments.isEmpty)
    }

    func testCookieSourcePassesTheBrowserToYtDlp() {
        let args = VideoDownloadTool.arguments(
            url: "https://example.com/v", destination: URL(filePath: "/tmp/out"),
            ffmpeg: URL(filePath: "/opt/homebrew/bin/ffmpeg"), cookies: .firefox)
        XCTAssertEqual(args.firstIndex(of: "--cookies-from-browser").map { args[$0 + 1] },
                       "firefox")
    }

    /// rawValue 直接餵給 yt-dlp，名字必須跟它認得的一致。
    func testCookieSourceRawValuesMatchYtDlpBrowserNames() {
        XCTAssertEqual(VideoCookieSource.allCases.map(\.rawValue),
                       ["none", "safari", "chrome", "brave", "edge",
                        "firefox", "chromium", "vivaldi", "opera"])
    }

    /// Safari 的 cookie 在 TCC 保護的位置；Chromium 系的是鑰匙串加密。
    /// 這兩種要給的下一步完全不同，不能混為一談。
    func testKnowsWhichBrowsersNeedWhichAuthorization() {
        XCTAssertTrue(VideoCookieSource.safari.needsFullDiskAccess)
        XCTAssertFalse(VideoCookieSource.safari.needsKeychain)
        XCTAssertTrue(VideoCookieSource.chrome.needsKeychain)
        XCTAssertFalse(VideoCookieSource.chrome.needsFullDiskAccess)
        // Firefox 兩樣都不用——所以它是「不想開權限」時的建議答案。
        XCTAssertFalse(VideoCookieSource.firefox.needsKeychain)
        XCTAssertFalse(VideoCookieSource.firefox.needsFullDiskAccess)
    }

    /// Safari 的 cookie 檔沒授權時連「存不存在」都問不出來。
    /// 拿存在與否當安裝與否，會反過來說「你沒裝 Safari」。
    func testSafariCountsAsInstalledEvenWhenItsCookiesAreUnreadable() {
        XCTAssertTrue(VideoCookieSource.safari.isInstalled(
            home: URL(filePath: "/Users/test")) { _ in false })
        XCTAssertFalse(VideoCookieSource.chrome.isInstalled(
            home: URL(filePath: "/Users/test")) { _ in false })
        XCTAssertTrue(VideoCookieSource.chrome.isInstalled(
            home: URL(filePath: "/Users/test")) {
                $0.hasSuffix("Library/Application Support/Google/Chrome")
            })
    }

    /// 測試只問不下載——按一下「測試授權」不該真的開始抓一支影片下來。
    func testCookieCheckOnlySimulates() {
        let args = VideoDownloadTool.cookieCheckArguments(
            url: "https://example.com/v", cookies: .chrome)
        XCTAssertTrue(args.contains("--simulate"))
        XCTAssertFalse(args.contains("-o"), "測試不該有輸出路徑")
        XCTAssertTrue(args.contains("--socket-timeout"), "網路卡住時要有盡頭")
    }

    /// 測試問的必須是「照目前設定會拿到哪一條」，不是「這個站最好的是哪條」。
    func testCookieCheckUsesTheSameFormatSelectionAsTheRealDownload() throws {
        let args = VideoDownloadTool.cookieCheckArguments(
            url: "https://example.com/v", quality: .p720, cookies: .chrome)
        XCTAssertEqual(args.firstIndex(of: "-S").map { args[$0 + 1] }, "res,br")
        let format = try XCTUnwrap(args.firstIndex(of: "-f").map { args[$0 + 1] })
        XCTAssertTrue(format.hasPrefix("bv*[height<=720]/"))
    }

    // MARK: - 看得懂 yt-dlp 說了什麼

    /// TCC 擋下來有好幾種寫法，全都指向同一個解法。
    func testRecognisesFullDiskAccessFailures() {
        for text in [
            "ERROR: Could not find safari cookies database",
            "PermissionError: [Errno 1] Operation not permitted: '/Users/x/Library/Cookies'",
            "ERROR: Operation not permitted",
        ] {
            XCTAssertEqual(VideoDownloadTool.explainCookieCheck(text, succeeded: false),
                           .needsFullDiskAccess, "沒認出來：\(text)")
        }
    }

    func testRecognisesKeychainFailures() {
        for text in [
            "ERROR: Failed to decrypt cookie",
            "WARNING: unable to decrypt cookies from Chrome Safe Storage",
        ] {
            XCTAssertEqual(VideoDownloadTool.explainCookieCheck(text, succeeded: false),
                           .needsKeychain, "沒認出來：\(text)")
        }
    }

    func testRecognisesMissingBrowser() {
        XCTAssertEqual(
            VideoDownloadTool.explainCookieCheck(
                "ERROR: could not find brave cookies database", succeeded: false),
            .browserNotFound)
    }

    /// 認不出來的就報原文。**不要自己編一句**——編出來的那句多半把方向帶偏。
    func testUnknownFailuresKeepTheOriginalWording() {
        XCTAssertEqual(
            VideoDownloadTool.explainCookieCheck(
                "ERROR: Video unavailable", succeeded: false),
            .failed("Video unavailable"))
    }

    /// 「要授權」要排在「報原文」前面：反過來的話，一句 ERROR
    /// 就把唯一的解法蓋掉了。
    func testAuthorizationDiagnosisWinsOverTheRawError() {
        let text = """
            [Cookies] Extracting cookies from safari
            ERROR: Unable to load cookies: Operation not permitted
            """
        XCTAssertEqual(VideoDownloadTool.explainCookieCheck(text, succeeded: false),
                       .needsFullDiskAccess)
    }

    func testReadsBackTheCookieCountAndStream() {
        let text = """
            Extracted 1234 cookies from chrome
            foldwall-probe 1080p avc1.64002A
            """
        XCTAssertEqual(VideoDownloadTool.explainCookieCheck(text, succeeded: true),
                       .ok(count: 1234, stream: "1080p avc1.64002A"))
    }

    /// 讀不出細節不算失敗：cookie 讀到了就是讀到了。
    func testSucceedsEvenWhenTheDetailsAreMissing() {
        XCTAssertEqual(VideoDownloadTool.explainCookieCheck("", succeeded: true),
                       .ok(count: nil, stream: nil))
    }

    /// yt-dlp 查不到欄位時印的是字面上的 NA。把「NAp NA」端到介面上
    /// 比什麼都不說還糟。
    func testDoesNotShowYtDlpsPlaceholders() {
        XCTAssertEqual(VideoDownloadTool.explainCookieCheck(
            "foldwall-probe NAp NA", succeeded: true), .ok(count: nil, stream: nil))
    }

    /// **格式表上的位元率不能拿給使用者看**：實測格式 270（m3u8）宣稱 4634 kbps、
    /// 抓下來 1472 kbps，而它的 https 雙胞胎 137 宣稱 1424、抓下來 1471——
    /// 同一份編碼，m3u8 那條灌了三倍。印出來就是拿假數字騙人。
    func testDoesNotAskForABitrateItCannotTrust() throws {
        let args = VideoDownloadTool.cookieCheckArguments(
            url: "https://example.com/v", cookies: .chrome)
        let printed = try XCTUnwrap(args.firstIndex(of: "--print").map { args[$0 + 1] })
        XCTAssertFalse(printed.contains("vbr"), "vbr 對 HLS 是灌水的")
        XCTAssertFalse(printed.contains("tbr"), "tbr 同上")
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

    // MARK: - 版本

    func testParsesTheDateVersion() {
        XCTAssertEqual(VideoDownloadTool.parseVersion("2026.08.19\n"), [2026, 8, 19])
    }

    /// Homebrew 會把前導零去掉，所以比字串沒有用。
    func testHomebrewStyleVersionParsesToTheSameNumbers() {
        XCTAssertEqual(VideoDownloadTool.parseVersion("2026.8.19"),
                       VideoDownloadTool.parseVersion("2026.08.19"))
    }

    /// nightly 會多接一段秒數，前三段仍然是日期。
    func testParsesTheNightlyVersion() {
        XCTAssertEqual(VideoDownloadTool.parseVersion("2026.08.19.232712"), [2026, 8, 19])
    }

    func testUnparseableVersionIsNil() {
        XCTAssertNil(VideoDownloadTool.parseVersion("git-2026abcdef"))
        XCTAssertNil(VideoDownloadTool.parseVersion(""))
        XCTAssertNil(VideoDownloadTool.parseVersion("2026.08"))
    }

    func testOlderInstallIsOutdated() {
        XCTAssertTrue(VideoDownloadTool.isOutdated(installed: "2026.05.01", latest: "2026.08.19"))
        XCTAssertTrue(VideoDownloadTool.isOutdated(installed: "2025.12.31", latest: "2026.01.01"))
    }

    func testSameOrNewerInstallIsNotOutdated() {
        XCTAssertFalse(VideoDownloadTool.isOutdated(installed: "2026.08.19", latest: "2026.08.19"))
        XCTAssertFalse(VideoDownloadTool.isOutdated(installed: "2026.8.19", latest: "2026.08.19"),
                       "前導零不該讓最新版被說成舊的")
        XCTAssertFalse(VideoDownloadTool.isOutdated(installed: "2026.09.01", latest: "2026.08.19"),
                       "nightly 可能比 stable 新")
    }

    /// 查不到不是「有問題」。不確定就別唸使用者。
    func testUnknownVersionsAreNeverCalledOutdated() {
        XCTAssertFalse(VideoDownloadTool.isOutdated(installed: nil, latest: "2026.08.19"))
        XCTAssertFalse(VideoDownloadTool.isOutdated(installed: "2026.08.19", latest: nil))
        XCTAssertFalse(VideoDownloadTool.isOutdated(installed: "git-abc", latest: "2026.08.19"))
    }

    func testParsesTheReleaseTag() {
        let json = Data(#"{"tag_name":"2026.08.19","name":"yt-dlp 2026.08.19"}"#.utf8)
        XCTAssertEqual(VideoDownloadTool.parseLatestRelease(json), "2026.08.19")
        XCTAssertNil(VideoDownloadTool.parseLatestRelease(Data("not json".utf8)))
        XCTAssertNil(VideoDownloadTool.parseLatestRelease(Data(#"{"tag_name":""}"#.utf8)))
    }

    /// GitHub 對沒帶 User-Agent 的請求回 403。
    func testReleaseRequestCarriesAUserAgent() {
        let request = VideoDownloadTool.latestReleaseRequest()
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Foldwall")
        XCTAssertEqual(request.url?.host(), "api.github.com")
    }
}
