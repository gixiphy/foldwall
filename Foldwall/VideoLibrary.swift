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
    /// 「下一片」：請 extension 跳到下一支。名稱兩側必須一致（見 PhospheneExtension）。
    private static let skipVideoNotification = "app.foldwall.skipVideo"

    private let ledgerURL: URL
    /// 帳本與拒絕名單的記憶體快取。唯一的寫入者就是這個型別（@MainActor），
    /// 沒必要每次 `deployedCount`（每輪 refresh 至少問兩次）都重讀＋解一次 JSON。
    private var ledgerCache: [Deployment]?
    private var rejectsCache: [String: Int64]?

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

    /// 驗過解不動的來源路徑。排片時先濾掉，否則它們每輪都佔一個名額，
    /// 拷不進去又擠掉了本來排得進來的影片。
    var rejectedSourcePaths: Set<String> { Set(loadRejects().keys) }

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
        var rejects = loadRejects()
        let deployed = Set(ledger.map(\.sourcePath))
        for url in videos where !deployed.contains(url.standardizedFileURL.path) {
            if Task.isCancelled { break }
            let path = url.standardizedFileURL.path
            if let known = rejects[path], known == Self.fileSize(url) {
                Log.video.info("跳過解不動的影片：\(url.lastPathComponent, privacy: .public)")
                continue
            }
            guard await Self.isDecodable(url) else {
                // 記下來，下一輪別再花一次 SMB 讀取＋解碼去確認同一件事。
                // 連檔案大小一起記：檔被換掉（同路徑不同內容）就重驗一次。
                rejects[path] = Self.fileSize(url) ?? 0
                saveRejects(rejects)
                Log.video.error("影片解不動，不拷進 extension：\(url.lastPathComponent, privacy: .public)")
                continue
            }
            if let id = await deploy(url) {
                ledger.append(Deployment(sourcePath: path, entryID: id))
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

    /// macOS 真的放得出這支影片嗎。
    ///
    /// **必須真的解一格，不能只讀 metadata。** 踩過的坑：`hev1` 封裝的 HEVC
    /// （參數集放在串流內）在 `loadTracks` 這一層是**完全正常的**——回得出 codec、
    /// fps、尺寸——但 AVFoundation 一解碼就吐 -12430「Cannot Open」。
    /// Apple 的堆疊只吃 `hvc1`。所以只驗 metadata 的話，這種檔會一路過關，
    /// 白白從 SMB 拷幾十 MB 進 container，然後在系統設定的桌布清單裡因為
    /// 縮圖失敗被靜默跳過——**連帶讓 Shuffle All 磚因為數量不足而整個消失**。
    ///
    /// 只解第一格，成本遠低於拷貝整支。
    private static func isDecodable(_ url: URL) async -> Bool {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.maximumSize = CGSize(width: 160, height: 90)   // 只是要確認解得動
        generator.appliesPreferredTrackTransform = true
        do {
            _ = try await generator.image(at: .zero).image
            return true
        } catch {
            return false
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

    /// 解不動的影片：路徑 → 當時的檔案大小。
    ///
    /// 存起來是因為輪替每次都可能再抽到同一支，而確認「這支解不動」要付一次
    /// SMB 讀取加一次解碼。跟帳本放一起，清快取時一併消失。
    private var rejectsURL: URL {
        ledgerURL.deletingLastPathComponent().appending(path: "video-rejects.json")
    }

    private func loadRejects() -> [String: Int64] {
        if let rejectsCache { return rejectsCache }
        guard let data = try? Data(contentsOf: rejectsURL),
              let map = try? JSONDecoder().decode([String: Int64].self, from: data)
        else {
            rejectsCache = [:]
            return [:]
        }
        rejectsCache = map
        return map
    }

    private func saveRejects(_ rejects: [String: Int64]) {
        rejectsCache = rejects
        try? JSONEncoder().encode(rejects).write(to: rejectsURL, options: .atomic)
    }

    private func loadLedger() -> [Deployment] {
        if let ledgerCache { return ledgerCache }
        guard let data = try? Data(contentsOf: ledgerURL),
              let ledger = try? JSONDecoder().decode([Deployment].self, from: data)
        else {
            ledgerCache = []
            return []
        }
        ledgerCache = ledger
        return ledger
    }

    private func saveLedger(_ ledger: [Deployment]) {
        ledgerCache = ledger
        try? FileManager.default.createDirectory(
            at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? JSONEncoder().encode(ledger).write(to: ledgerURL, options: .atomic)
    }

    /// 手動下一片（系統 extension 那條）。
    ///
    /// **只能用發通知的**：當前播的是哪一支由 extension 自己持有（沙盒、另一個行程），
    /// app 這邊沒有把手可以直接指揮。只有在系統設定選了 **Shuffle All** 時它才有得跳；
    /// 選了固定某一支的話這個通知會被忽略——那正是「單片循環」的意思。
    static func requestExtensionSkip() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(skipVideoNotification as CFString),
            nil, nil, true
        )
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
