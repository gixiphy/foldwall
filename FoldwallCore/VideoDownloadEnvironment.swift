//  VideoDownloadEnvironment.swift
//  yt-dlp 子行程的執行環境，以及「為什麼抓不下來」的分類。
//
//  為什麼要管環境：GUI app 起的子行程**沒有 shell 的 PATH**。yt-dlp 自己是我們
//  照絕對路徑找到的（見 `locate`），但它解 YouTube 還要再往外找 **JavaScript
//  runtime**（deno／node）解 n-challenge——找不到就只剩 storyboard 那幾個
//  「格式」，每一支都以 `Requested format is not available` 收場，而真正的原因
//  只在前面那行 WARNING 裡。0.9.1 以前片單下載就是這樣整批死掉的：
//  同一組參數在終端機跑好好的，從 app 起就不行，差別只有 PATH。
//
//  所以起 yt-dlp 時把我們找工具的那幾個目錄前置到 PATH，deno、node、ffmpeg
//  都在那些地方。其餘環境變數只留 yt-dlp 與 deno 需要的：HOME（快取與 cookie
//  資料庫）、USER／LOGNAME、TMPDIR。

import Foundation

extension VideoDownloadTool {

    /// yt-dlp 認得的 JavaScript runtime，照它自己的優先順序。
    public static let javaScriptRuntimeNames = ["deno", "node", "bun", "quickjs"]

    /// 使用者機器上找得到的 JavaScript runtime；nil＝一個都沒裝。
    ///
    /// 找法跟 yt-dlp 一樣（同一組目錄），優先序照 yt-dlp 的：deno 最前面。
    public static func locateJavaScriptRuntime(
        home: URL = URL.homeDirectory,
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        for name in javaScriptRuntimeNames {
            let candidates = searchPaths.map { "\($0)/\(name)" }
                + [home.appending(path: ".local/bin/\(name)").path]
            if let hit = candidates.first(where: exists) { return URL(filePath: hit) }
        }
        return nil
    }

    /// 起 yt-dlp 用的環境變數。**每一個起它的地方都要用這個**，不然就是
    /// 0.9.1 以前那個「終端機能跑、app 不能跑」的坑。
    ///
    /// PATH 的順序：工具自己所在的目錄 → 我們找工具的那幾個目錄 → `~/.local/bin`
    /// → 繼承到的 PATH。前置而不是取代：使用者環境裡有的照樣找得到。
    public static func environment(
        tool: URL,
        home: URL = URL.homeDirectory,
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var seen: Set<String> = []
        var dirs: [String] = []
        func add(_ dir: String) {
            guard !dir.isEmpty, seen.insert(dir).inserted else { return }
            dirs.append(dir)
        }
        add(tool.deletingLastPathComponent().path)
        searchPaths.forEach(add)
        add(home.appending(path: ".local/bin").path)
        (inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").map(String.init).forEach(add)

        var environment = [
            "PATH": dirs.joined(separator: ":"),
            "HOME": inherited["HOME"] ?? home.path,
            "USER": inherited["USER"] ?? NSUserName(),
            "LOGNAME": inherited["LOGNAME"] ?? NSUserName(),
        ]
        if let tmpdir = inherited["TMPDIR"] { environment["TMPDIR"] = tmpdir }
        if let lang = inherited["LANG"] { environment["LANG"] = lang }
        return environment
    }

    // MARK: - 為什麼抓不下來

    /// yt-dlp 失敗時，除了它最後那行 ERROR 之外還能多說什麼。
    ///
    /// 最後一行 ERROR 常常只是結果（`Requested format is not available`），
    /// 原因在前面的 WARNING 裡；而解法又取決於使用者機器上裝了什麼。
    /// 這裡把「輸出＋機器狀態」對成一個可以直接給解法的分類。
    public enum DownloadFailureHint: Equatable, Sendable {
        /// 站只給分離軌，沒 ffmpeg 合併不了。
        case missingFFmpeg
        /// yt-dlp 要 JavaScript runtime 解挑戰，機器上一個都沒有。
        case missingJavaScriptRuntime
        /// 有 runtime 但挑戰還是解不開：多半是 yt-dlp 或 runtime 太舊。
        case javaScriptChallengeFailed(runtime: URL)
    }

    /// - Parameters:
    ///   - output: yt-dlp 的 stdout＋stderr。
    ///   - ffmpeg: 機器上的 ffmpeg，nil＝沒裝。
    ///   - javaScriptRuntime: 機器上的 JS runtime，nil＝沒裝。
    ///
    /// JS 那條先判：它的症狀也是「格式不存在」，若先判 ffmpeg 會把沒裝 ffmpeg
    /// 的人指去裝 ffmpeg，而真正缺的是 deno。
    public static func downloadFailureHint(
        _ output: String, ffmpeg: URL?, javaScriptRuntime: URL?
    ) -> DownloadFailureHint? {
        let lower = output.lowercased()
        if lower.contains("javascript runtime") || lower.contains("challenge solving failed") {
            if let javaScriptRuntime { return .javaScriptChallengeFailed(runtime: javaScriptRuntime) }
            return .missingJavaScriptRuntime
        }
        if lower.contains("requested format is not available"), ffmpeg == nil {
            return .missingFFmpeg
        }
        return nil
    }
}

/// 片單下載的**整體**冷卻：連續幾支都抓不下來，就先別再起 yt-dlp。
///
/// 每支失敗本來各自冷卻 30 分鐘（`PlaylistService.retryInterval`），但片單有幾十支，
/// 每輪 refresh 都會挑到下一支還沒冷卻的——等於每 5 分鐘白起一次 yt-dlp、跑完
/// 整段網路擷取再失敗。壞的通常不是那一支，是環境（沒 deno、沒 ffmpeg、cookie
/// 讀不到），換哪一支都一樣。連續失敗到門檻就整個片單停一段時間，成功一次就歸零。
public struct DownloadBackoff: Sendable, Equatable {

    /// 連續失敗幾次就停。3 是「不是單支的問題」的最小證據量：一支可能真的下架了，
    /// 兩支可能剛好，三支連著死就是環境。
    public static let threshold = 3
    /// 停多久。跟單支的冷卻同一個數，理由一樣：環境問題多半是暫時的（限流、
    /// 網路），也可能使用者正在裝 deno，半小時後再試合理。
    public static let pause: TimeInterval = 30 * 60

    public private(set) var consecutiveFailures = 0
    public private(set) var pausedUntil: Date?

    public init() {}

    /// - Returns: 這一次失敗**剛好**觸發暫停的話回 true，呼叫端拿來只記一次 log。
    @discardableResult
    public mutating func recordFailure(now: Date) -> Bool {
        consecutiveFailures += 1
        guard consecutiveFailures >= Self.threshold, !isPaused(now: now) else { return false }
        pausedUntil = now.addingTimeInterval(Self.pause)
        return true
    }

    public mutating func recordSuccess() {
        consecutiveFailures = 0
        pausedUntil = nil
    }

    /// 暫停期滿後**連續失敗數不歸零**：環境沒修好的話，期滿後的第一次失敗
    /// 就會立刻再停，不必重新累積三次。
    public func isPaused(now: Date) -> Bool {
        guard let pausedUntil else { return false }
        return now < pausedUntil
    }
}
