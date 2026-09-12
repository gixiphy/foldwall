//  MPVRuntime.swift
//  libmpv 跟 yt-dlp 走同一條界線：**使用者自己用 Homebrew 裝**，Foldwall 找它、
//  問版本、提示更新，不附帶、不下載、也不替他跑 brew。沒裝就走 AVPlayer。
//
//  這裡只有純邏輯——找哪裡、版號怎麼解、落後怎麼判、載入失敗怎麼分類——
//  磁碟、dlopen 與網路都由呼叫端做，所以每一條都測得到。寫法仿 VideoDownload.swift。
//
//  **一個行程只 dlopen 一次**，握著 handle 到行程結束。`brew upgrade mpv` 會換掉磁碟上
//  的檔：已映射的舊庫照樣能用，但之後再 dlopen 會拿到新版，兩台螢幕各跑一版是在賭。
//  新版一律下次啟動才生效，`needsRestart` 就是在判「磁碟上的 ≠ 載入中的」。

import Foundation

public enum MPVRuntime {

    // MARK: - 找

    public static let libraryName = "libmpv.2.dylib"
    public static let executableName = "mpv"

    /// 只認 Homebrew 的兩個前綴，跟 `VideoDownloadTool.searchPaths` 同一個原則
    /// （GUI app 不繼承 shell 的 PATH，得自己找）。
    ///
    /// **IINA 內附的那份不在這裡**：那是別人 app 的內部檔、版本 0.38、IINA 一更新就
    /// 可能變或消失。原型拿它做 A/B 可以，正式路徑不能建在別人的 bundle 上。
    public static let librarySearchPaths = [
        "/opt/homebrew/lib",      // Homebrew（Apple Silicon）
        "/usr/local/lib",         // Homebrew（Intel）／手動安裝
    ]

    /// Homebrew 的 mpv formula 連 CLI 一起裝；還沒載入函式庫之前問版本靠它。
    public static let executableSearchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]

    public static func locateLibrary(
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        librarySearchPaths.map { "\($0)/\(libraryName)" }
            .first(where: exists).map { URL(filePath: $0) }
    }

    public static func locateExecutable(
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        executableSearchPaths.map { "\($0)/\(executableName)" }
            .first(where: exists).map { URL(filePath: $0) }
    }

    // MARK: - 版本

    /// 問 CLI 版本的參數。第一行長這樣：`mpv v0.40.0 Copyright © 2000-2025 mpv/MPlayer/mplayer2 projects`。
    public static let versionArguments = ["--version"]

    /// 三段整數的版號。mpv 的 release 一律 `0.X.Y`。
    public struct Version: Comparable, Hashable, Sendable, CustomStringConvertible {
        public var major: Int
        public var minor: Int
        public var patch: Int

        public init(_ major: Int, _ minor: Int, _ patch: Int) {
            self.major = major
            self.minor = minor
            self.patch = patch
        }

        public var description: String { "\(major).\(minor).\(patch)" }

        public static func < (lhs: Version, rhs: Version) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
    }

    /// 從任何一種寫法裡撈出版號。
    ///
    /// 會遇到的：CLI 的 `mpv v0.40.0 Copyright…`、`mpv-version` 屬性的 `mpv v0.40.0-123-gabcdef`、
    /// Homebrew formula 的 `0.40.0`、`brew list` 的 `0.40.0_1`（`_1` 是 bottle 修訂，不是版本）、
    /// GitHub tag 的 `v0.40.0`。都是「第一個 X.Y.Z」。
    /// 解不出來就回 nil——**寧可不提醒，也不要亂猜版本**。
    public static func parseVersion(_ text: String) -> Version? {
        guard let match = text.firstMatch(of: /(\d+)\.(\d+)\.(\d+)/),
              let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3)
        else { return nil }
        return Version(major, minor, patch)
    }

    /// 支援的最低版本。原型只在 0.38 以上驗過（IINA 附的那份就是 0.38.0），
    /// 再舊的 render API 行為沒人看過，不載。
    public static let minimumVersion = Version(0, 38, 0)

    /// 我們釘死的標頭是哪一版的 client API（`ThirdParty/mpv/client.h`，mpv v0.40.0：
    /// `MPV_MAKE_VERSION(2, 5)`）。主版號不同就是 ABI 不相容，不能載。
    public static let headerClientAPIVersion: UInt = (2 << 16) | 5

    /// `mpv_client_api_version()` 回的值裡的主版號。
    public static func clientAPIMajor(_ version: UInt) -> UInt { version >> 16 }

    /// 上游是哪版：問 **Homebrew 的 formula**，不問 GitHub。
    ///
    /// 更新指令是 `brew upgrade mpv`，拿 GitHub tag 比會在 bottle 還沒出來的那幾天
    /// 叫使用者升一個升不上去的版本。yt-dlp 沒這個問題，是因為它的 formula 幾小時內
    /// 就跟上；mpv 一年只出兩三版，bottle 慢個幾天很常見。
    public static func latestFormulaRequest() -> URLRequest {
        var request = URLRequest(
            url: URL(string: "https://formulae.brew.sh/api/formula/mpv.json")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Foldwall", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        return request
    }

    /// 從 formula JSON 撈出 `versions.stable`。
    public static func parseLatestFormula(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let versions = root["versions"] as? [String: Any],
              let stable = versions["stable"] as? String, !stable.isEmpty
        else { return nil }
        return stable
    }

    /// 裝的這版落後 Homebrew 了嗎。
    ///
    /// 任何一邊解不出版號就回 `false`：查不到不是「有問題」，不確定的時候
    /// 指著使用者的工具說它舊最糟。
    public static func isOutdated(installed: String?, latest: String?) -> Bool {
        guard let installed, let latest,
              let mine = parseVersion(installed), let theirs = parseVersion(latest)
        else { return false }
        return mine < theirs
    }

    /// 磁碟上的跟行程裡載入中的不是同一版：使用者剛 `brew upgrade` 過，
    /// 新版要重新啟動才會用上。兩邊都解得出、而且不同才算。
    public static func needsRestart(loaded: String?, onDisk: String?) -> Bool {
        guard let loaded, let onDisk,
              let running = parseVersion(loaded), let installed = parseVersion(onDisk)
        else { return false }
        return running != installed
    }

    // MARK: - 為什麼載不起來

    /// 載入失敗的分類。**每一種對一個解法**，而且全部不是影片的錯——
    /// 這幾類都不能把影片送進來源冷卻名單。
    public enum LoadFailure: Equatable, Sendable {
        /// 兩個目錄都沒有 `libmpv.2.dylib`。
        case notInstalled
        /// dlopen 說某個相依找不到：多半是 `brew upgrade ffmpeg` 之類換了大版本、
        /// mpv 還沒跟著重建。`path` 是缺的那個。
        case dependencyMissing(path: String?)
        /// `mpv_client_api_version()` 的主版號跟我們釘死的標頭不同，ABI 不相容。
        case apiVersionMismatch(found: UInt, expected: UInt)
        /// 低於 `minimumVersion`。
        case tooOld(installed: Version, minimum: Version)
        /// `mpv_create`／`mpv_initialize`／render context 建立失敗。不是使用者能修的。
        case coreFailed(String)

        /// 使用者能照著打的那一行；`nil` 就是這不是他能修的。
        public var brewCommand: String? {
            switch self {
            case .notInstalled: "brew install mpv"
            case .dependencyMissing: "brew reinstall mpv"
            case .apiVersionMismatch, .tooOld: "brew upgrade mpv"
            case .coreFailed: nil
            }
        }

        public var isUserFixable: Bool { brewCommand != nil }
    }

    /// 把 `dlerror()` 的話對成分類。
    ///
    /// 相依缺了長這樣（dyld 的固定措辭）：
    /// `dlopen(/opt/homebrew/lib/libmpv.2.dylib, 0x0005): Library not loaded: /opt/homebrew/opt/ffmpeg/lib/libavcodec.62.dylib
    ///   Referenced from: … Reason: tried: '…' (no such file)`
    public static func classifyLoadError(_ message: String) -> LoadFailure {
        let marker = "Library not loaded: "
        guard let range = message.range(of: marker) else { return .coreFailed(message) }
        let rest = message[range.upperBound...]
        let path = rest.split(whereSeparator: { $0.isNewline || $0 == " " }).first.map(String.init)
        return .dependencyMissing(path: path)
    }

    /// 載入後第一件事：API 主版號對不對。
    public static func checkAPIVersion(_ found: UInt) -> LoadFailure? {
        guard clientAPIMajor(found) != clientAPIMajor(headerClientAPIVersion) else { return nil }
        return .apiVersionMismatch(found: found, expected: headerClientAPIVersion)
    }

    /// 第二件事：夠不夠新。**太新不擋**，只記錄——擋掉一個沒驗過的新版換來的是黑畫面。
    public static func checkMinimum(_ installed: Version) -> LoadFailure? {
        installed < minimumVersion ? .tooOld(installed: installed, minimum: minimumVersion) : nil
    }

    // MARK: - 播放選項

    /// 診斷事件的 `engine` 欄位：沿用 `VideoEngine.desktopWindow` 的字串再加核心，
    /// 不改欄位——那個型別同時編進沙盒 appex，加必填欄位會讓舊 extension 的紀錄解不開。
    public static let engineLabel = "desktopWindow/mpv"

    /// 建 core 時一次設好的選項。
    ///
    /// 基準是使用者確認流暢的原型（`tools/playback-compare`）：`vo=libmpv`、
    /// `hwdec=auto-safe`、**靜音但保留音訊路徑**（`mute=yes`，不是 `ao=null`／`aid=no`）。
    /// 關掉音訊解碼、改同步模式這類改動要獨立 A/B，不能假設不影響播放節奏。
    ///
    /// **沒有 `start`**：那個選項是每支檔案都套用的，放在這裡會讓之後接上的每一支
    /// 都從同一秒開始。換核心要保留時間點的話，載入後再 seek（見 MPVSurface）。
    ///
    /// - Parameter loop: 單片循環。mpv 的 `loop-file` 是可即時改的屬性，這裡只管初值。
    /// - Returns: 鍵值對。順序無所謂，排成固定的只是為了測試與 log 好讀。
    public static func playbackOptions(loop: Bool) -> [(String, String)] {
        [
            ("vo", "libmpv"),
            ("hwdec", "auto-safe"),
            ("mute", "yes"),
            // 不讀使用者的 mpv.conf、不跑 script：桌布的行為不該被別處的設定改掉。
            ("config", "no"),
            ("load-scripts", "no"),
            ("ytdl", "no"),
            ("terminal", "no"),
            ("msg-level", "all=warn"),
            // **內建 script 一個都不要。** `load-scripts=no` 只擋使用者的；stats、osc、
            // console 這些內建的各有自己的開關，預設會起一條 LuaJIT 執行緒。LuaJIT 要
            // 可執行的記憶體，Hardened Runtime 沒給 allow-jit 就直接 SIGKILL
            // （Code Signature Invalid）——實測正式簽名的 app 啟動 30 秒就這樣死在
            // `*/stats` 執行緒上，Debug 建置反而看不到。桌布用不到任何一個 script，
            // 關掉就不會碰到 LuaJIT；比開 allow-jit 放寬簽名好。
            // 幾個較新的開關舊版沒有（select 0.39、positioning／commands 0.40）：
            // 橋接層對「沒這個選項」不當失敗。
            ("osc", "no"),
            ("load-stats-overlay", "no"),
            ("load-osd-console", "no"),   // 0.41 改名 load-console，舊名留成別名
            ("load-console", "no"),
            ("load-auto-profiles", "no"),
            ("load-select", "no"),
            ("load-positioning", "no"),
            ("load-commands", "no"),
            ("load-context-menu", "no"),   // 0.41 新增；實測關了上面那些之後還剩它一條 lua 執行緒
            ("osd-level", "0"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("cursor-autohide", "no"),
            // 沒有下一支時停在最後一格等上層排片，不要黑掉。
            ("keep-open", "yes"),
            ("idle", "yes"),
            // 下一支先開起來（讀檔頭、建 demuxer），接縫才短。
            ("prefetch-playlist", "yes"),
            ("video-unscaled", "no"),
            ("loop-file", loop ? "inf" : "no"),
        ]
    }

    /// 載入後開一個暫時 core 讀 `mpv-version` 用的選項：跟播放同一套（**內建 script
    /// 一樣全關**——探測用的 core 也會起 stats script、也會被 SIGKILL，實測第二次就是
    /// 死在這裡），只是不接任何輸出。
    public static func probeOptions() -> [(String, String)] {
        playbackOptions(loop: false).filter { $0.0 != "vo" && $0.0 != "hwdec" }
            + [("vo", "null"), ("ao", "null")]
    }

    // MARK: - 播到一半的錯誤

    /// mpv 回報一支播不下去時的分類：讀取、格式、解碼／輸出要分開處理——
    /// 讀取失敗多半是來源暫時斷了（重建一次就好），格式不支援重建幾次都一樣。
    public enum PlaybackFailure: Equatable, Sendable {
        /// 開不了檔、讀不到：檔案不見了、網路磁碟斷了、串流 404。
        case unreadable
        /// 容器或編碼不支援。
        case unsupportedFormat
        /// 檔案開得了但沒有可播的軌。
        case nothingToPlay
        /// 視訊輸出建不起來。**不是影片的錯**，是我們這邊的 render context。
        case outputFailed
        case other(code: Int)

        /// 這個錯該不該怪影片：怪影片的才進來源冷卻名單。
        public var blamesSource: Bool {
            switch self {
            case .unreadable, .unsupportedFormat, .nothingToPlay, .other: true
            case .outputFailed: false
            }
        }

        public var localizedDescription: String {
            switch self {
            case .unreadable: String(localized: "讀取失敗", bundle: .foldwallCore)
            case .unsupportedFormat: String(localized: "格式不支援", bundle: .foldwallCore)
            case .nothingToPlay: String(localized: "沒有可播的軌", bundle: .foldwallCore)
            case .outputFailed: String(localized: "視訊輸出建不起來", bundle: .foldwallCore)
            case .other(let code): String(localized: "mpv 錯誤 \(code)", bundle: .foldwallCore)
            }
        }
    }

    /// 把 `mpv_event_end_file.error`（mpv_error 的值）對成分類。碼照 client.h。
    public static func classifyPlaybackError(_ code: Int) -> PlaybackFailure {
        switch code {
        case -13: .unreadable            // MPV_ERROR_LOADING_FAILED
        case -17, -18: .unsupportedFormat // UNKNOWN_FORMAT、UNSUPPORTED
        case -16: .nothingToPlay         // NOTHING_TO_PLAY
        case -15, -14: .outputFailed     // VO_INIT_FAILED、AO_INIT_FAILED
        default: .other(code: code)
        }
    }

    /// 縮放對到 mpv 的 `panscan`：填滿＝1（把黑邊裁掉），符合＝0。
    /// 「填滿高度／寬度」在引擎那層已經化簡成這兩種之一。
    public static func panscan(for scale: VideoScaleMode) -> String {
        switch scale {
        case .fit: "0"
        case .fill, .matchHeight, .matchWidth, .random: "1"
        }
    }
}
