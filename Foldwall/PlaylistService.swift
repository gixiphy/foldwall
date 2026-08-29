//  PlaylistService.swift
//  片單網址 → 影片檔。**抽到哪支才抓哪支。**
//
//  兩段式：
//  1. `refreshIfNeeded` 解析片單拿到 entry 清單（只有 metadata，不碰影片本體）。
//  2. `candidates` 回傳目前**已經在磁碟上**的那些；輪替抽到還沒抓的，
//     `requestDownload` 才去抓那一支。
//
//  為什麼不預先抓一批：片單可能有幾百支、幾十 GB，而桌布一次只播一支。
//  按需下載讓磁碟用量跟「你真的看過幾支」成正比。

import Foundation
import FoldwallCore

@MainActor
@Observable
final class PlaylistService {

    /// 兩次重新解析片單的最短間隔。片單本身變動不快，而解析要起一個子行程。
    private static let refreshInterval: TimeInterval = 6 * 60 * 60
    /// 同時最多下載幾支。桌布不急，一次一支就夠，也不會把頻寬吃光。
    private static let maximumConcurrentDownloads = 1

    private let directory: URL

    /// 片單 id → 解析出來的 entry。
    private(set) var entries: [UUID: [PlaylistEntry]] = [:]
    private var lastRefresh: [UUID: Date] = [:]
    private var refreshing: Set<UUID> = []

    /// 正在抓的 entry id。
    private(set) var downloading: Set<String> = []
    /// 抓失敗過的：不要每輪重試同一支。
    private var failed: [String: Date] = [:]
    private static let retryInterval: TimeInterval = 30 * 60

    private(set) var lastError: String?

    /// 有東西落地時回呼，讓上層補一輪。
    var onChanged: (() -> Void)?

    init(paths: AppPaths = .standard()) {
        self.directory = paths.remoteVideoCache
    }

    // MARK: - 解析

    /// 需要的話在背景重新解析片單。**不阻塞呼叫端。**
    func refreshIfNeeded(_ sources: [PlaylistSource]) {
        // 被刪掉的片單留在這些表裡永遠等不到人查，順手清掉——
        // 這個行程一開就是好幾週，慢性堆積也是堆積。
        let known = Set(sources.map(\.id))
        entries = entries.filter { known.contains($0.key) }
        lastRefresh = lastRefresh.filter { known.contains($0.key) }
        resolvedTitles = resolvedTitles.filter { known.contains($0.key) }

        for source in sources where source.isEnabled && source.url != nil {
            let stale = lastRefresh[source.id]
                .map { Date.now.timeIntervalSince($0) > Self.refreshInterval } ?? true
            guard stale, !refreshing.contains(source.id) else { continue }
            resolve(source)
        }
    }

    /// 使用者按「重新整理」或剛改完網址：跳過節流。
    func forceRefresh(_ source: PlaylistSource) {
        lastRefresh[source.id] = nil
        guard !refreshing.contains(source.id) else { return }
        resolve(source)
    }

    func entryCount(for source: PlaylistSource) -> Int { entries[source.id]?.count ?? 0 }

    func isRefreshing(_ source: PlaylistSource) -> Bool { refreshing.contains(source.id) }

    /// 這條片單有幾支已經在磁碟上了。
    func downloadedCount(for source: PlaylistSource) -> Int {
        let downloaded = VideoDownloadTool.localFileMap(in: directory)
        return (entries[source.id] ?? []).count { downloaded[$0.id] != nil }
    }

    private func resolve(_ source: PlaylistSource) {
        guard let url = source.url, let tool = VideoDownloadTool.locate() else {
            lastError = "找不到 yt-dlp。用 `brew install yt-dlp` 安裝後再試。"
            return
        }
        refreshing.insert(source.id)
        let id = source.id

        Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                Self.runList(tool: tool, url: url.absoluteString)
            }.value

            guard let self else { return }
            self.refreshing.remove(id)
            self.lastRefresh[id] = .now

            switch outcome {
            case .success(let title, let entries):
                let before = self.entries[id]?.count ?? 0
                self.entries[id] = entries
                self.resolvedTitles[id] = title
                self.lastError = nil
                Log.video.info("片單解析：\(entries.count, privacy: .public) 支")
                if before != entries.count { self.onChanged?() }
            case .failure(let reason):
                self.lastError = reason
                Log.video.error("片單解析失敗：\(reason, privacy: .public)")
            }
        }
    }

    /// 解析回來的片單標題，UI 用來補上使用者沒填的名稱。
    private(set) var resolvedTitles: [UUID: String] = [:]

    /// 解析結果。用自己的型別而不是 `Result<_, String>`：String 不是 Error。
    private enum ListOutcome {
        case success(title: String, entries: [PlaylistEntry])
        case failure(String)
    }

    nonisolated private static func runList(tool: URL, url: String) -> ListOutcome {
        let process = Process()
        process.executableURL = tool
        process.arguments = VideoDownloadTool.listArguments(url: url)
        let output = Pipe()
        process.standardOutput = output

        // stderr 收到暫存檔，不用第二條 pipe。
        //
        // 兩條 pipe 的話：我們卡在讀 stdout（片單 JSON 可以很大），
        // 子行程卡在寫 stderr（pipe 只有 64 KB 緩衝，滿了就 block）——互等，死鎖。
        // 拿掉 `--no-warnings` 之後 stderr 的量不再是可以忽略的一兩行，
        // 這條路就得堵起來。檔案沒有緩衝上限，寫多少都不會擋住誰。
        let log = FileManager.default.temporaryDirectory
            .appending(path: "foldwall-ytdlp-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: nil)
        let logHandle = try? FileHandle(forWritingTo: log)
        if let logHandle { process.standardError = logHandle }
        defer {
            try? logHandle?.close()
            try? FileManager.default.removeItem(at: log)
        }

        // 解析途中要拿它來補說明，所以先在 do 外面備好。
        var diagnostics = ""

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            diagnostics = String(decoding: (try? Data(contentsOf: log)) ?? Data(), as: UTF8.self)

            guard process.terminationStatus == 0 else {
                return .failure(Self.explain(diagnostics))
            }
            let parsed = try PlaylistCodec.parse(data)
            // 解出東西了但 yt-dlp 有話說（例如少數幾支跳過）：記一筆就好，不打擾使用者。
            if let warning = Self.firstWarning(diagnostics) {
                Log.video.info("yt-dlp 提醒：\(warning, privacy: .public)")
            }
            return .success(title: parsed.title, entries: parsed.entries)
        } catch PlaylistCodec.Failure.nothingExtracted(let expected) {
            return .failure(Self.explainNothingExtracted(expected: expected, diagnostics))
        } catch PlaylistCodec.Failure.empty {
            return .failure("這個網址裡沒有可用的影片")
        } catch PlaylistCodec.Failure.unreadable {
            return .failure("看不懂 yt-dlp 的輸出")
        } catch {
            return .failure((error as NSError).localizedDescription)
        }
    }

    nonisolated private static func explain(_ text: String) -> String {
        guard let line = text.split(separator: "\n").last(where: { $0.contains("ERROR") })
            ?? text.split(separator: "\n").last
        else { return "解析失敗" }
        if let range = line.range(of: "ERROR: ") { return String(line[range.upperBound...]) }
        return String(line)
    }

    /// yt-dlp 數得出片單裡有幾支，卻一支也沒解出來。
    ///
    /// 它自己認為成功（exit 0），所以這裡**不能**說「這個網址裡沒有可用的影片」——
    /// 那會把人推去檢查片單，而片單好好的。真正的原因幾乎都是 yt-dlp 太舊：
    /// 網站改版後 extractor 認不得新的頁面結構，只在 stderr 留一行 WARNING。
    /// 把那行原文一起帶出來，使用者要回報也有東西可貼。
    nonisolated private static func explainNothingExtracted(
        expected: Int, _ diagnostics: String
    ) -> String {
        var message = "yt-dlp 看得到這個片單有 \(expected) 支，卻一支也解不出來"
            + "——多半是 yt-dlp 太舊，跟不上網站改版。"
            + "用 `brew upgrade yt-dlp` 更新後再按「重新解析」。"
        if let warning = firstWarning(diagnostics) { message += "\n\n\(warning)" }
        return message
    }

    /// stderr 裡第一行 WARNING，去掉 yt-dlp 自己的前綴。
    nonisolated private static func firstWarning(_ text: String) -> String? {
        guard let line = text.split(separator: "\n").first(where: { $0.contains("WARNING") })
        else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let range = trimmed.range(of: "WARNING: ") { return String(trimmed[range.upperBound...]) }
        return trimmed
    }

    // MARK: - 按需下載

    /// 目前**已經在磁碟上**的片單影片。這些才進得了播放池。
    ///
    /// 用 `localFileMap` 一次建表：逐支呼叫 `localFile` 是每支重列一次目錄，
    /// 幾百支的片單在每輪 refresh、每次影片播畢都要問一遍。
    func candidates(for sources: [PlaylistSource]) -> [URL] {
        let downloaded = VideoDownloadTool.localFileMap(in: directory)
        return sources.filter(\.isEnabled).flatMap { source in
            (entries[source.id] ?? []).compactMap { downloaded[$0.id] }
        }
    }

    /// 還沒抓、也不在冷卻中的那些。
    func pending(for sources: [PlaylistSource]) -> [PlaylistEntry] {
        let now = Date.now
        let downloaded = VideoDownloadTool.localFileMap(in: directory)
        return sources.filter(\.isEnabled).flatMap { source in
            (entries[source.id] ?? []).filter { entry in
                guard downloaded[entry.id] == nil,
                      !downloading.contains(entry.id)
                else { return false }
                if let failedAt = failed[entry.id],
                   now.timeIntervalSince(failedAt) < Self.retryInterval { return false }
                return true
            }
        }
    }

    /// 抓這一支。已經在抓、或同時下載數滿了就跳過。
    func requestDownload(_ entry: PlaylistEntry) {
        guard downloading.count < Self.maximumConcurrentDownloads,
              !downloading.contains(entry.id),
              let tool = VideoDownloadTool.locate()
        else { return }

        downloading.insert(entry.id)
        let destination = directory
        let id = entry.id
        let urlString = entry.urlString
        Log.video.info("片單按需下載：\(entry.title, privacy: .public)")

        Task { @MainActor [weak self] in
            let ok = await Task.detached(priority: .utility) {
                Self.runDownload(tool: tool, url: urlString, destination: destination)
            }.value

            guard let self else { return }
            self.downloading.remove(id)
            if ok {
                self.failed.removeValue(forKey: id)
                self.onChanged?()
            } else {
                // 冷卻而不是永久剔除：失效多半是暫時的（限流、網路斷一下）
                self.failed[id] = .now
            }
        }
    }

    nonisolated private static func runDownload(tool: URL, url: String, destination: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = tool
            process.arguments = VideoDownloadTool.arguments(url: url, destination: destination)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            _ = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
