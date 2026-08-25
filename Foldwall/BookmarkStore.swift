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

    init(defaults: UserDefaults = .standard) {
        self.store = FolderStore(defaults: UserDefaultsBookmarks(defaults: defaults))
    }

    func addFolders() async throws -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "加入"
        panel.message = "選擇要當桌布來源的資料夾"

        guard await panel.begin() == .OK else { return [] }

        for url in panel.urls {
            try store.add(url)
        }
        notifyChanged()
        return panel.urls
    }

    func removeFolder(_ url: URL) throws {
        guard try store.remove(url) else { return }
        notifyChanged()
        // 影片庫同步刪除該來源的拷貝：VideoLibrary 監聽 didChangeNotification（Task 8）
    }

    func resolvedFolders() -> [URL] {
        let resolution = store.resolve()
        offlineCount = resolution.offlineCount
        return resolution.readable
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
