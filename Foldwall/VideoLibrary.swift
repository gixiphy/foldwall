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

    /// 同步 container，讓它**剛好等於** `videos`：沒在清單裡的移除，缺的拷進來。
    ///
    /// 選哪幾支不在這裡決定（見 VideoBudget.rotate）——這支只負責把磁碟弄成指定的樣子。
    /// 拷貝走 SMB／雲端時一支要好幾分鐘，**呼叫端務必放背景**，別擋著靜態管線。
    /// container 裡實際備妥幾支。靜態管線靠它判斷「這螢幕真的有影片可播嗎」。
    var deployedCount: Int { loadLedger().count }

    func sync(videos: [URL]) async {
        var ledger = loadLedger()
        sweepOrphans(ledger: ledger)

        let wanted = Set(videos.map(\.standardizedFileURL.path))

        // 移除：不在這輪清單裡的（來源刪了、資料夾被移除，或這輪輪到別支）
        for deployment in ledger where !wanted.contains(deployment.sourcePath) {
            remove(entryID: deployment.entryID)
        }
        ledger.removeAll { !wanted.contains($0.sourcePath) }
        saveLedger(ledger)

        // 新增。**每拷完一支就寫帳本**——中途被砍（或當機）時，
        // 已經拷進去的才不會變成帳本外的孤兒永遠佔著磁碟。
        let deployed = Set(ledger.map(\.sourcePath))
        for url in videos where !deployed.contains(url.standardizedFileURL.path) {
            if Task.isCancelled { break }
            if let id = await deploy(url) {
                ledger.append(Deployment(sourcePath: url.standardizedFileURL.path, entryID: id))
                saveLedger(ledger)
            }
        }

        notifyExtension()
    }

    /// 把 container 裡帳本沒記到的目錄清掉。
    /// 同步跑到一半被中斷就會留下這種孤兒，不掃的話它們永遠不會被回收。
    private func sweepOrphans(ledger: [Deployment]) {
        let known = Set(ledger.map(\.entryID))
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Self.videosURL, includingPropertiesForKeys: nil
        )) ?? []

        for dir in contents where !known.contains(dir.lastPathComponent) {
            remove(entryID: dir.lastPathComponent)
        }
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize
        else { return nil }
        return Int64(size)
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
