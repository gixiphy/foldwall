import XCTest
@testable import FoldwallCore

final class MPVRuntimeTests: XCTestCase {

    // MARK: - 找

    /// GUI app 不繼承 shell 的 PATH，跟 yt-dlp 同一個理由：自己去 Homebrew 的位置找。
    func testLooksInBothHomebrewPrefixes() {
        XCTAssertEqual(MPVRuntime.librarySearchPaths, ["/opt/homebrew/lib", "/usr/local/lib"])
        XCTAssertEqual(MPVRuntime.executableSearchPaths, ["/opt/homebrew/bin", "/usr/local/bin"])
    }

    func testLocateLibraryReturnsTheFirstExistingCandidate() {
        let found = MPVRuntime.locateLibrary { $0 == "/usr/local/lib/libmpv.2.dylib" }
        XCTAssertEqual(found?.path, "/usr/local/lib/libmpv.2.dylib")
    }

    func testLocateLibraryPrefersAppleSiliconHomebrew() {
        let found = MPVRuntime.locateLibrary { _ in true }
        XCTAssertEqual(found?.path, "/opt/homebrew/lib/libmpv.2.dylib")
    }

    func testLocateReturnsNilWhenNothingIsInstalled() {
        XCTAssertNil(MPVRuntime.locateLibrary { _ in false })
        XCTAssertNil(MPVRuntime.locateExecutable { _ in false })
    }

    /// IINA 內附的那份不是支援來源：正式路徑不能建在別人的 bundle 上。
    func testDoesNotLookInsideIINA() {
        XCTAssertFalse(MPVRuntime.librarySearchPaths.contains { $0.contains("IINA") })
    }

    // MARK: - 版號

    func testParsesEveryWayAVersionShowsUp() {
        let expected = MPVRuntime.Version(0, 40, 0)
        XCTAssertEqual(MPVRuntime.parseVersion(
            "mpv v0.40.0 Copyright © 2000-2025 mpv/MPlayer/mplayer2 projects"), expected, "CLI 第一行")
        XCTAssertEqual(MPVRuntime.parseVersion("mpv v0.40.0-123-gabcdef"), expected, "mpv-version 屬性，git 建置")
        XCTAssertEqual(MPVRuntime.parseVersion("0.40.0"), expected, "formula 的 versions.stable")
        XCTAssertEqual(MPVRuntime.parseVersion("0.40.0_1"), expected, "brew list 的 bottle 修訂")
        XCTAssertEqual(MPVRuntime.parseVersion("v0.40.0"), expected, "GitHub tag")
        XCTAssertEqual(MPVRuntime.parseVersion("  mpv 0.40.0\n"), expected, "release 建置沒有 v、有空白")
    }

    /// 解不出來就 nil，不要亂猜——不確定的時候指著使用者的工具說它舊最糟。
    func testRefusesToGuessAVersion() {
        XCTAssertNil(MPVRuntime.parseVersion(""))
        XCTAssertNil(MPVRuntime.parseVersion("mpv"))
        XCTAssertNil(MPVRuntime.parseVersion("0.40"))
        XCTAssertNil(MPVRuntime.parseVersion("找不到 mpv"))
    }

    func testVersionsCompareNumericallyNotAsStrings() {
        XCTAssertLessThan(MPVRuntime.Version(0, 9, 0), MPVRuntime.Version(0, 40, 0))
        XCTAssertLessThan(MPVRuntime.Version(0, 40, 0), MPVRuntime.Version(0, 40, 1))
        XCTAssertLessThan(MPVRuntime.Version(0, 40, 9), MPVRuntime.Version(1, 0, 0))
        XCTAssertEqual(MPVRuntime.Version(0, 40, 0).description, "0.40.0")
    }

    func testOutdatedOnlyWhenBothSidesParseAndTheirsIsNewer() {
        XCTAssertTrue(MPVRuntime.isOutdated(installed: "mpv v0.38.0 Copyright", latest: "0.40.0"))
        XCTAssertFalse(MPVRuntime.isOutdated(installed: "mpv v0.40.0", latest: "0.40.0"))
        XCTAssertFalse(MPVRuntime.isOutdated(installed: "mpv v0.41.0", latest: "0.40.0"), "比 Homebrew 新不算落後")
        XCTAssertFalse(MPVRuntime.isOutdated(installed: nil, latest: "0.40.0"))
        XCTAssertFalse(MPVRuntime.isOutdated(installed: "mpv v0.38.0", latest: nil))
        XCTAssertFalse(MPVRuntime.isOutdated(installed: "garbage", latest: "0.40.0"))
    }

    /// `brew upgrade` 之後磁碟上是新版、行程裡還是舊版：要重新啟動才會用上。
    func testNeedsRestartWhenDiskAndLoadedDiffer() {
        XCTAssertTrue(MPVRuntime.needsRestart(loaded: "mpv v0.38.0-abc", onDisk: "mpv v0.40.0 Copyright"))
        XCTAssertFalse(MPVRuntime.needsRestart(loaded: "mpv v0.40.0-abc", onDisk: "mpv v0.40.0 Copyright"))
        XCTAssertFalse(MPVRuntime.needsRestart(loaded: nil, onDisk: "0.40.0"))
        XCTAssertFalse(MPVRuntime.needsRestart(loaded: "0.40.0", onDisk: nil))
    }

    func testMinimumIsTheOldestVersionThePrototypeWasVerifiedOn() {
        XCTAssertEqual(MPVRuntime.minimumVersion, MPVRuntime.Version(0, 38, 0))
        XCTAssertEqual(MPVRuntime.checkMinimum(MPVRuntime.Version(0, 37, 0)),
                       .tooOld(installed: MPVRuntime.Version(0, 37, 0), minimum: MPVRuntime.Version(0, 38, 0)))
        XCTAssertNil(MPVRuntime.checkMinimum(MPVRuntime.Version(0, 38, 0)))
        XCTAssertNil(MPVRuntime.checkMinimum(MPVRuntime.Version(0, 41, 0)), "太新不擋，只記錄")
    }

    /// 釘死的標頭是 v0.40.0 的 client.h：MPV_MAKE_VERSION(2, 5)。
    func testHeaderAPIVersionMatchesTheVendoredHeader() {
        XCTAssertEqual(MPVRuntime.headerClientAPIVersion, 0x0002_0005)
        XCTAssertEqual(MPVRuntime.clientAPIMajor(MPVRuntime.headerClientAPIVersion), 2)
    }

    func testAPIVersionOnlyFailsOnADifferentMajor() {
        XCTAssertNil(MPVRuntime.checkAPIVersion(0x0002_0005))
        XCTAssertNil(MPVRuntime.checkAPIVersion(0x0002_0003), "同主版號、較舊的次版號還是相容")
        XCTAssertNil(MPVRuntime.checkAPIVersion(0x0002_0009), "較新的次版號也相容")
        XCTAssertEqual(MPVRuntime.checkAPIVersion(0x0003_0000),
                       .apiVersionMismatch(found: 0x0003_0000, expected: 0x0002_0005))
    }

    // MARK: - Homebrew formula

    func testAsksHomebrewNotGitHubBecauseThatIsWhatBrewUpgradeGives() {
        let request = MPVRuntime.latestFormulaRequest()
        XCTAssertEqual(request.url?.host(), "formulae.brew.sh")
        XCTAssertEqual(request.url?.path(), "/api/formula/mpv.json")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
    }

    func testReadsTheStableVersionOutOfTheFormula() throws {
        let json = """
        {"name":"mpv","versions":{"stable":"0.40.0","head":"HEAD","bottle":true},"revision":1}
        """
        XCTAssertEqual(MPVRuntime.parseLatestFormula(Data(json.utf8)), "0.40.0")
    }

    func testFormulaWithoutAVersionIsNotAnAnswer() {
        XCTAssertNil(MPVRuntime.parseLatestFormula(Data("{}".utf8)))
        XCTAssertNil(MPVRuntime.parseLatestFormula(Data("{\"versions\":{\"stable\":\"\"}}".utf8)))
        XCTAssertNil(MPVRuntime.parseLatestFormula(Data("not json".utf8)))
    }

    // MARK: - 載入失敗

    /// dyld 的固定措辭：相依缺了要指去 `brew reinstall mpv`，不是叫人裝 mpv。
    func testMissingDependencyIsRecognisedWithThePathThatIsMissing() {
        let message = """
        dlopen(/opt/homebrew/lib/libmpv.2.dylib, 0x0005): Library not loaded: /opt/homebrew/opt/ffmpeg/lib/libavcodec.62.dylib
          Referenced from: <UUID> /opt/homebrew/Cellar/mpv/0.40.0/lib/libmpv.2.dylib
          Reason: tried: '/opt/homebrew/opt/ffmpeg/lib/libavcodec.62.dylib' (no such file)
        """
        let failure = MPVRuntime.classifyLoadError(message)
        XCTAssertEqual(failure, .dependencyMissing(path: "/opt/homebrew/opt/ffmpeg/lib/libavcodec.62.dylib"))
        XCTAssertEqual(failure.brewCommand, "brew reinstall mpv")
    }

    func testUnknownLoadErrorsKeepTheOriginalWordingAndAreNotUserFixable() {
        let failure = MPVRuntime.classifyLoadError("mpv_render_context_create: unsupported")
        XCTAssertEqual(failure, .coreFailed("mpv_render_context_create: unsupported"))
        XCTAssertNil(failure.brewCommand)
        XCTAssertFalse(failure.isUserFixable)
    }

    /// 每一種使用者能修的失敗都對一行 brew 指令，跟 yt-dlp 的提示一樣直接給解法。
    func testEveryUserFixableFailureNamesTheBrewCommand() {
        XCTAssertEqual(MPVRuntime.LoadFailure.notInstalled.brewCommand, "brew install mpv")
        XCTAssertEqual(MPVRuntime.LoadFailure.dependencyMissing(path: nil).brewCommand, "brew reinstall mpv")
        XCTAssertEqual(MPVRuntime.LoadFailure.apiVersionMismatch(found: 3 << 16, expected: 2 << 16).brewCommand,
                       "brew upgrade mpv")
        XCTAssertEqual(MPVRuntime.LoadFailure.tooOld(installed: .init(0, 37, 0), minimum: .init(0, 38, 0)).brewCommand,
                       "brew upgrade mpv")
    }

    // MARK: - 播放選項

    /// 基準是使用者確認流暢的原型：靜音但**保留音訊路徑**，不是 ao=null。
    /// 有人想省那條路的時候要獨立 A/B，不是順手改這裡。
    func testOptionsKeepThePrototypeBaseline() {
        let options = Dictionary(uniqueKeysWithValues: MPVRuntime.playbackOptions(loop: false))
        XCTAssertEqual(options["vo"], "libmpv")
        XCTAssertEqual(options["hwdec"], "auto-safe")
        XCTAssertEqual(options["mute"], "yes")
        XCTAssertNil(options["ao"])
        XCTAssertNil(options["aid"])
        XCTAssertEqual(options["keep-open"], "yes")
        XCTAssertEqual(options["loop-file"], "no")
    }

    /// `start` 是每支檔案都套用的選項，放進去會讓接上的每一支都從同一秒開始。
    func testLoopIsTheOnlyThingThatVariesAndStartIsNeverAnOption() {
        let looping = Dictionary(uniqueKeysWithValues: MPVRuntime.playbackOptions(loop: true))
        XCTAssertEqual(looping["loop-file"], "inf")
        XCTAssertNil(looping["start"])
        let plain = Dictionary(uniqueKeysWithValues: MPVRuntime.playbackOptions(loop: false))
        XCTAssertEqual(Set(looping.keys), Set(plain.keys))
        XCTAssertEqual(looping.filter { $0.key != "loop-file" }, plain.filter { $0.key != "loop-file" })
    }

    /// 桌布不該讀使用者的 mpv.conf、不該跑 script、不該自己去叫 yt-dlp。
    func testOptionsIsolateTheCoreFromTheUsersConfig() {
        let options = Dictionary(uniqueKeysWithValues: MPVRuntime.playbackOptions(loop: false))
        XCTAssertEqual(options["config"], "no")
        XCTAssertEqual(options["load-scripts"], "no")
        XCTAssertEqual(options["ytdl"], "no")
        XCTAssertEqual(options["input-default-bindings"], "no")
    }

    /// 內建 script 會起 LuaJIT，Hardened Runtime 沒有 allow-jit 就被 SIGKILL。
    /// 每一個內建 script 的開關都要關，少一個就是正式簽名的 app 啟動半分鐘後死掉。
    func testEveryBuiltinScriptIsSwitchedOffSoLuaJITNeverStarts() {
        let options = Dictionary(uniqueKeysWithValues: MPVRuntime.playbackOptions(loop: false))
        for key in ["osc", "load-stats-overlay", "load-osd-console", "load-console", "load-auto-profiles",
                    "load-select", "load-positioning", "load-commands", "load-context-menu", "ytdl"] {
            XCTAssertEqual(options[key], "no", key)
        }
    }

    /// 探測版本的那個 core 也不能起任何內建 script，否則同一種 SIGKILL 在載入時就發生。
    func testProbeOptionsSwitchOffScriptsAndAttachNoOutput() {
        let options = Dictionary(uniqueKeysWithValues: MPVRuntime.probeOptions())
        XCTAssertEqual(options["vo"], "null")
        XCTAssertEqual(options["ao"], "null")
        XCTAssertNil(options["hwdec"])
        for key in ["osc", "load-stats-overlay", "load-console", "load-auto-profiles",
                    "load-select", "load-positioning", "load-commands", "load-context-menu", "load-scripts"] {
            XCTAssertEqual(options[key], "no", key)
        }
    }

    func testPanscanMapsFillToOneAndFitToZero() {
        XCTAssertEqual(MPVRuntime.panscan(for: .fill), "1")
        XCTAssertEqual(MPVRuntime.panscan(for: .fit), "0")
    }

    func testEngineLabelExtendsTheDesktopWindowLabelInsteadOfReplacingIt() {
        XCTAssertTrue(MPVRuntime.engineLabel.hasPrefix(VideoEngine.desktopWindow.rawValue + "/"))
    }

    // MARK: - 播到一半的錯誤

    /// 讀取、格式、輸出要分開：輸出建不起來是我們的事，不能把影片送進冷卻名單。
    func testPlaybackErrorsAreClassifiedByMpvErrorCode() {
        XCTAssertEqual(MPVRuntime.classifyPlaybackError(-13), .unreadable)
        XCTAssertEqual(MPVRuntime.classifyPlaybackError(-17), .unsupportedFormat)
        XCTAssertEqual(MPVRuntime.classifyPlaybackError(-18), .unsupportedFormat)
        XCTAssertEqual(MPVRuntime.classifyPlaybackError(-16), .nothingToPlay)
        XCTAssertEqual(MPVRuntime.classifyPlaybackError(-15), .outputFailed)
        XCTAssertEqual(MPVRuntime.classifyPlaybackError(-99), .other(code: -99))
    }

    func testOnlyOutputFailuresSpareTheSource() {
        XCTAssertFalse(MPVRuntime.PlaybackFailure.outputFailed.blamesSource)
        XCTAssertTrue(MPVRuntime.PlaybackFailure.unreadable.blamesSource)
        XCTAssertTrue(MPVRuntime.PlaybackFailure.unsupportedFormat.blamesSource)
        XCTAssertTrue(MPVRuntime.PlaybackFailure.other(code: -20).blamesSource)
    }
}
