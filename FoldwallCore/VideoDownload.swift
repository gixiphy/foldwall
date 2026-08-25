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

    /// - Parameter destination: 存放目錄。
    /// - Returns: 傳給 yt-dlp 的參數。
    ///
    /// 刻意**只取單一檔案**（不用 `bv+ba` 那種需要合併的格式）：
    /// 合併要 ffmpeg，使用者不見得裝了，失敗訊息又很難懂。
    public static func arguments(url: String, destination: URL) -> [String] {
        [
            "--no-playlist",              // 貼到播放清單網址時只抓那一支
            "--no-part",                  // 不留 .part 半成品在來源目錄裡
            "--no-progress",
            "--newline",
            "-f", "b[height<=\(maximumHeight)][ext=mp4]/b[ext=mp4]/b[height<=\(maximumHeight)]/b",
            "-o", destination.appending(path: "%(title).80B [%(id)s].%(ext)s").path,
            url,
        ]
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
