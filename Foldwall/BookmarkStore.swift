//  BookmarkStore.swift
//  app 層：NSOpenPanel + UserDefaults。持久化與可讀性判定在 FoldwallCore.FolderStore。
//  介面名依 HANDOFF 鎖定（改成 @MainActor：選單列 app 一律主執行緒操作）。

import AppKit
import FoldwallCore

@MainActor
protocol FolderBookmarking {
    func addFolders() async throws -> [URL]
    func removeFolder(_ url: URL) throws
    func resolvedFolders() -> [URL]
    var offlineCount: Int { get }
    var offlineFolders: [URL] { get }
}

/// UserDefaults key `folders`（見 HANDOFF 設定 schema，不要改）。
struct UserDefaultsBookmarks: BookmarkDefaults, @unchecked Sendable {
    static let key = "folders"
    let defaults: UserDefaults

    func loadBookmarks() -> [Data] {
        defaults.array(forKey: Self.key) as? [Data] ?? []
    }

    func saveBookmarks(_ bookmarks: [Data]) {
        defaults.set(bookmarks, forKey: Self.key)
    }
}

@MainActor
final class BookmarkStore: FolderBookmarking {

    /// 來源集合有變（新增／移除／stale 重建）→ 池要重掃、影片庫要同步。
    static let didChangeNotification = Notification.Name("FoldwallFoldersDidChange")

    private let store: FolderStore
    private(set) var offlineCount: Int = 0
    /// 解析得出路徑、但這一刻讀不到的根（NAS 沒掛、磁碟拔掉、雲端登出）。
    ///
    /// 跟 `offlineCount` 分開留著是因為索引需要**路徑**：少了它，離線的根在
    /// FolderIndex 眼裡就等於「使用者移除了」，那顆碟的整份索引會被刪掉並落地。
    private(set) var offlineFolders: [URL] = []

    init(defaults: UserDefaults = .standard) {
        self.store = FolderStore(defaults: UserDefaultsBookmarks(defaults: defaults))
    }

    func addFolders() async throws -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "加入")
        panel.message = String(localized: "選擇要當桌布來源的資料夾")

        guard await panel.begin() == .OK else { return [] }

        for url in panel.urls {
            try store.add(url)
        }
        notifyChanged()
        return panel.urls
    }

    /// 從路徑加入，不開面板。設定還原用：備份檔存的是路徑不是 bookmark。
    ///
    /// 不需要面板是因為 v1 不沙盒、bookmark 也沒有 security scope（見 BookmarkCodec），
    /// 能不能讀由 TCC 決定，跟使用者有沒有在面板上點過那個資料夾無關。
    /// 路徑不存在的就跳過——另一台機器可能根本沒掛那顆磁碟。
    @discardableResult
    func addFolders(paths: [String]) -> [URL] {
        var added: [URL] = []
        for path in paths {
            let url = URL(filePath: path, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                Log.sources.notice("還原時跳過不存在的來源：\(path, privacy: .public)")
                continue
            }
            guard (try? store.add(url)) != nil else { continue }
            added.append(url)
        }
        if !added.isEmpty { notifyChanged() }
        return added
    }

    func removeFolder(_ url: URL) throws {
        guard try store.remove(url) else { return }
        notifyChanged()
        // 影片庫同步刪除該來源的拷貝：VideoLibrary 監聽 didChangeNotification（Task 8）
    }

    func resolvedFolders() -> [URL] {
        let resolution = store.resolve()
        offlineCount = resolution.offlineCount
        offlineFolders = resolution.offline
        return resolution.readable
    }

    /// 同上，但解析跑在背景執行緒。
    ///
    /// `resolve()` 對每個根做「列得出第一層嗎」的可讀性檢查——來源是 SMB 的話
    /// 那是一次網路往返，而這件事每輪 refresh 都要做一次。留在主執行緒上，
    /// 網路一慢整個介面就跟著頓。
    func resolvedFoldersInBackground() async -> [URL] {
        let store = self.store
        let resolution = await Task.detached(priority: .userInitiated) { store.resolve() }.value
        offlineCount = resolution.offlineCount
        offlineFolders = resolution.offline
        return resolution.readable
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
