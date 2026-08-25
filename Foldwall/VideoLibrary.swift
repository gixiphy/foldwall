//  VideoLibrary.swift
//  把來源資料夾裡的影片送進 extension 的沙盒 container。
//
//  為什麼是「拷貝」不是 bookmark-link：extension 本身是沙盒的，讀不到 app 的 bookmark。
//  這是 Phosphene 既有的契約（app 直接寫進 extension container），磁碟用量會翻倍。
//
//  磁碟格式（與 fork 的 extension 對齊，不要改）：
//    Documents/videos/<uuid>/<檔名>
//    Documents/videos/<uuid>/metadata.json

import AVFoundation
import Foundation
import FoldwallCore

@MainActor
final class VideoLibrary {

    private struct Metadata: Codable {
        let id: String
        var name: String
        var filename: String
        var duration: Double
        var fps: Double
        var resolution: CGSize
        var dateAdded: Date
    }

    /// 我們自己的帳本：來源路徑 → entry id。用來做差異同步與移除。
    private struct Deployment: Codable {
        var sourcePath: String
        var entryID: String
    }

    static let extensionBundleID = "app.foldwall.extension"
    private static let libraryChangedNotification = "app.foldwall.libraryChanged"

    private let ledgerURL: URL

    init(paths: AppPaths = .standard()) {
        self.ledgerURL = paths.applicationSupport.appending(path: "video-deployments.json")
    }

    static var documentsURL: URL {
        URL.homeDirectory
            .appending(path: "Library/Containers/\(extensionBundleID)/Data/Documents")
    }

    private static var videosURL: URL {
        documentsURL.appending(path: "videos")
    }

    /// 差異同步：來源新增的拷進去，來源已刪或資料夾被移除的一併清掉。
    /// 每輪重掃後呼叫。
    func sync(videos: [URL]) async {
        var ledger = loadLedger()
        let wanted = Set(videos.map(\.standardizedFileURL.path))

        // 移除：來源已不在清單內（檔案刪了，或使用者移除了整個資料夾）
        for deployment in ledger where !wanted.contains(deployment.sourcePath) {
            remove(entryID: deployment.entryID)
        }
        ledger.removeAll { !wanted.contains($0.sourcePath) }

        // 新增
        let deployed = Set(ledger.map(\.sourcePath))
        for url in videos where !deployed.contains(url.standardizedFileURL.path) {
            if let id = await deploy(url) {
                ledger.append(Deployment(sourcePath: url.standardizedFileURL.path, entryID: id))
            }
        }

        saveLedger(ledger)
        notifyExtension()
    }

    // MARK: - 單支影片

    private func deploy(_ url: URL) async -> String? {
        let fm = FileManager.default
        let id = UUID().uuidString
        let dir = Self.videosURL.appending(path: id)

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let destination = dir.appending(path: url.lastPathComponent)
            try fm.copyItem(at: url, to: destination)

            let probe = await probeVideo(destination)
            let metadata = Metadata(
                id: id,
                name: url.deletingPathExtension().lastPathComponent,
                filename: url.lastPathComponent,
                duration: probe.duration,
                fps: probe.fps,
                resolution: probe.resolution,
                dateAdded: .now
            )
            try JSONEncoder().encode(metadata)
                .write(to: dir.appending(path: "metadata.json"), options: .atomic)

            Log.video.info("影片已部署：\(url.lastPathComponent, privacy: .public) → \(id, privacy: .public)")
            return id
        } catch {
            try? fm.removeItem(at: dir)
            Log.video.error("影片部署失敗：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func remove(entryID: String) {
        // 只接受 UUID：帳本壞掉也不能讓 removeItem 走到 container 外
        guard UUID(uuidString: entryID) != nil else { return }
        try? FileManager.default.removeItem(at: Self.videosURL.appending(path: entryID))
        Log.video.info("影片已從 container 移除：\(entryID, privacy: .public)")
    }

    private func probeVideo(_ url: URL) async -> (duration: Double, fps: Double, resolution: CGSize) {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return (0, 0, .zero)
        }
        let fps = Double((try? await track.load(.nominalFrameRate)) ?? 0)
        let size = (try? await track.load(.naturalSize)) ?? .zero
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        return (duration, fps, size)
    }

    // MARK: - 帳本與通知

    private func loadLedger() -> [Deployment] {
        guard let data = try? Data(contentsOf: ledgerURL),
              let ledger = try? JSONDecoder().decode([Deployment].self, from: data)
        else { return [] }
        return ledger
    }

    private func saveLedger(_ ledger: [Deployment]) {
        try? FileManager.default.createDirectory(
            at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? JSONEncoder().encode(ledger).write(to: ledgerURL, options: .atomic)
    }

    /// Darwin notification：讓 extension 重新掃描它的影片庫（名稱兩側必須一致）。
    private func notifyExtension() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.libraryChangedNotification as CFString),
            nil, nil, true
        )
    }
}
