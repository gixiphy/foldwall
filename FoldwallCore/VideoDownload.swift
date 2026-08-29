//  VideoDownload.swift
//  用**使用者自己安裝的** yt-dlp 從網址取得影片檔。
//
//  界線講清楚：Foldwall **不實作**任何串流解析或簽章繞過——那是規避技術保護
//  措施。這裡只負責找到使用者機器上既有的工具、組出參數、把結果收進影片來源。
//  抽取那一段由那個工具負責，也由使用者自己決定要對哪個站用。
//
//  順帶的好處：yt-dlp 支援上千個站，不必為每一個寫解析器。

import Foundation

public enum VideoDownloadTool {

    public static let executableName = "yt-dlp"

    /// GUI app **不繼承 shell 的 PATH**。從 LaunchServices 啟動時
    /// `/opt/homebrew/bin` 根本不在環境變數裡，直接呼叫名字必然失敗。
    /// 所以要自己找常見安裝位置。
    public static let searchPaths = [
        "/opt/homebrew/bin",      // Homebrew（Apple Silicon）
        "/usr/local/bin",         // Homebrew（Intel）／手動安裝
        "/opt/local/bin",         // MacPorts
        "/usr/bin",
    ]

    /// - Parameter home: 使用者家目錄，用來找 `~/.local/bin`（pipx／pip --user）。
    public static func locate(
        home: URL = URL.homeDirectory,
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let candidates = searchPaths.map { "\($0)/\(executableName)" }
            + [home.appending(path: ".local/bin/\(executableName)").path]
        return candidates.first(where: exists).map { URL(filePath: $0) }
    }

    /// 桌布影片不需要 4K：檔案大好幾倍、解碼更吃電，縮到螢幕尺寸也看不出差別。
    public static let maximumHeight = 1080

    /// ffmpeg 在哪。yt-dlp 要靠它把分離的視訊／音訊軌合起來。
    ///
    /// 找法跟 yt-dlp 一樣（GUI app 不繼承 shell 的 PATH），常見的安裝位置也一樣。
    public static func locateFFmpeg(
        home: URL = URL.homeDirectory,
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let candidates = searchPaths.map { "\($0)/ffmpeg" }
            + [home.appending(path: ".local/bin/ffmpeg").path]
        return candidates.first(where: exists).map { URL(filePath: $0) }
    }

    /// - Parameters:
    ///   - destination: 存放目錄。
    ///   - ffmpeg: 找得到 ffmpeg 就傳它，會多要「分離軌 ＋ 合併」那條路。
    /// - Returns: 傳給 yt-dlp 的參數。
    ///
    /// **為什麼要分兩種格式選擇**：原本刻意只取單一檔案（不用 `bv+ba` 那種要
    /// 合併的），理由是合併需要 ffmpeg 而使用者不見得裝了。代價是 2026 年的
    /// YouTube 幾乎不再提供 muxed 格式——實測整張格式表只有 DASH 的分離軌，
    /// 於是每一支都以 `Requested format is not available` 收場，片單一支也抓不下來。
    ///
    /// 所以：有 ffmpeg 就走分離軌＋合併，沒有才退回單一檔案（對還提供 muxed
    /// 的站仍然有效）。判斷放在呼叫端，這裡只負責照著組參數。
    public static func arguments(url: String, destination: URL, ffmpeg: URL? = nil) -> [String] {
        let singleFile = "b[height<=\(maximumHeight)][ext=mp4]/b[ext=mp4]"
            + "/b[height<=\(maximumHeight)]/b"
        var arguments = [
            "--no-playlist",              // 貼到播放清單網址時只抓那一支
            "--no-part",                  // 不留 .part 半成品在來源目錄裡
            "--no-progress",
            "--newline",
        ]
        if let ffmpeg {
            arguments += [
                "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path,
                "--merge-output-format", "mp4",
                "-f", "bv*[height<=\(maximumHeight)]+ba/\(singleFile)",
            ]
        } else {
            arguments += ["-f", singleFile]
        }
        arguments += [
            "-o", destination.appending(path: "%(title).80B [%(id)s].%(ext)s").path,
            url,
        ]
        return arguments
    }

    // MARK: - 版本

    /// 問工具版本的參數。
    public static let versionArguments = ["--version"]

    /// 解析版號。
    ///
    /// yt-dlp 用**日期版號**：`2026.08.19`，nightly 多接一段
    /// （`2026.08.19.232712`），GitHub 的 tag 也是同一套。Homebrew 會把前導零
    /// 去掉（`2026.8.19`），所以比字串沒有用，要比數字。
    /// 解不出來就回 nil——**寧可不提醒，也不要亂猜版本**。
    public static func parseVersion(_ text: String) -> [Int]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        let numbers = parts.prefix(3).compactMap { Int($0) }
        guard numbers.count == 3, numbers[0] >= 2000,
              (1...12).contains(numbers[1]), (1...31).contains(numbers[2])
        else { return nil }
        return numbers
    }

    /// 問 GitHub 最新的 release 是哪一版。
    ///
    /// 為什麼是「有沒有新版」而不是「幾天沒更新」：後者是猜的。一個十天前才
    /// 更新過的人如果已經是最新版，叫他去更新就是錯的建議——他照做也不會好，
    /// 還會以為問題處理掉了。直接問上游最新是幾版，答案沒有模糊空間。
    public static func latestReleaseRequest() -> URLRequest {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub 對沒帶 User-Agent 的請求回 403。
        request.setValue("Foldwall", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        return request
    }

    /// 從 release JSON 撈出 tag。
    public static func parseLatestRelease(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String, !tag.isEmpty
        else { return nil }
        return tag
    }

    /// 裝的這版落後上游了嗎。
    ///
    /// 任何一邊解不出版號就回 `false`：查不到不是「有問題」，不確定的時候
    /// 指著使用者的工具說它舊最糟。
    public static func isOutdated(installed: String?, latest: String?) -> Bool {
        guard let installed, let latest,
              let mine = parseVersion(installed), let theirs = parseVersion(latest)
        else { return false }
        for (a, b) in zip(mine, theirs) where a != b { return a < b }
        return false
    }

    /// 網址看起來合理嗎。擋掉明顯的手滑，真正能不能抓由工具決定。
    public static func isPlausible(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed), let scheme = parsed.scheme?.lowercased(),
              ["http", "https"].contains(scheme), parsed.host?.isEmpty == false
        else { return false }
        return true
    }
}

public enum VideoDownloadState: Sendable, Equatable {
    case idle
    case running
    case finished(name: String)
    case failed(reason: String)

    public var summary: String {
        switch self {
        case .idle: ""
        case .running: "下載中…"
        case .finished(let name): "完成：\(name)"
        case .failed(let reason): reason
        }
    }
}
