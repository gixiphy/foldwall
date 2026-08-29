//  FolderStore.swift
//  來源根目錄的持久化與可讀性判定。純 Foundation，可測；NSOpenPanel 在 app 層。

import Foundation

/// bookmark 的持久化後端（app 用 UserDefaults，測試用 in-memory）。
public protocol BookmarkDefaults: Sendable {
    func loadBookmarks() -> [Data]
    func saveBookmarks(_ bookmarks: [Data])
}

public struct FolderStore: Sendable {

    public struct Resolution: Sendable, Equatable {
        /// 目前真的讀得到的根。
        public var readable: [URL]
        /// 知道路徑但這一刻讀不到（TCC 拒絕、磁碟拔掉、雲端登出）。
        public var offline: [URL]
        /// bookmark 連當初記下的路徑都撈不出來。實務上幾乎不會發生——
        /// 整顆碟沒掛的來源會落在 `offline`，見 `recordedPath`。
        public var unresolvedCount: Int

        public var offlineCount: Int { offline.count + unresolvedCount }
    }

    private let defaults: any BookmarkDefaults

    public init(defaults: any BookmarkDefaults) {
        self.defaults = defaults
    }

    // MARK: - 變更

    public func add(_ url: URL) throws {
        let target = Self.comparablePath(url)
        guard !resolveAll().contains(where: { Self.path(of: $0) == target }) else {
            return   // 已加入，不重複
        }
        var stored = defaults.loadBookmarks()
        stored.append(try BookmarkCodec.data(for: url))
        defaults.saveBookmarks(stored)
    }

    /// 刪除該根的 bookmark。回傳是否真的刪到。
    /// 呼叫端（app 層）另需：讓池重掃、刪掉該來源已拷進 extension container 的影片。
    ///
    /// 比對走 `path(of:)` 而不是解出來的 URL：碟沒掛時 bookmark 根本解不開，
    /// 只認 URL 的話使用者對著設定裡那排離線來源按「移除」會**靜靜地沒反應**。
    @discardableResult
    public func remove(_ url: URL) throws -> Bool {
        let target = Self.comparablePath(url)
        let entries = resolveAll()
        let keep = entries.filter { Self.path(of: $0) != target }
        guard keep.count != entries.count else { return false }
        defaults.saveBookmarks(keep.map(\.data))
        return true
    }

    // MARK: - 查詢

    /// 解析所有 bookmark，並對每個根做「列得出第一層嗎」的可讀性檢查。
    /// stale 的 bookmark 會就地重建存回。
    public func resolve() -> Resolution {
        var readable: [URL] = []
        var offline: [URL] = []
        var unresolved = 0
        var rebuilt = false
        var stored: [Data] = []

        for entry in resolveAll() {
            guard let url = entry.url else {
                // 解析不出來也把原 data 留著：磁碟插回來就會活
                stored.append(entry.data)
                // **解析失敗不等於來源消失。** 整顆碟沒掛的時候，resolve 會先試著
                // 掛載它，掛不上就 throw——NAS 關機、筆電不在家都走這條。
                // bookmark 裡還留著當初記下的路徑，撈出來歸到「離線」：
                // 少了這步，那個根會從上層的清單裡整個消失，索引會當成使用者
                // 移除了它，把那顆碟的整份清單刪掉並落地（見 FolderIndex）。
                if let path = Self.recordedPath(entry.data) {
                    offline.append(URL(filePath: path, directoryHint: .isDirectory))
                } else {
                    unresolved += 1
                }
                continue
            }

            var data = entry.data
            if entry.isStale, let fresh = try? BookmarkCodec.data(for: url) {
                data = fresh
                rebuilt = true
            }
            stored.append(data)

            if Self.isReadable(url) {
                readable.append(url)
            } else {
                offline.append(url)
            }
        }

        if rebuilt {
            defaults.saveBookmarks(stored)
        }
        return Resolution(readable: readable, offline: offline, unresolvedCount: unresolved)
    }

    public func resolvedFolders() -> [URL] {
        resolve().readable
    }

    // MARK: - 私有

    private struct Entry {
        var data: Data
        var url: URL?
        var isStale: Bool
    }

    private func resolveAll() -> [Entry] {
        defaults.loadBookmarks().map { data in
            guard let resolved = try? BookmarkCodec.resolve(data) else {
                return Entry(data: data, url: nil, isStale: false)
            }
            return Entry(data: data, url: resolved.url, isStale: resolved.isStale)
        }
    }

    /// 可讀性 = 列得出第一層。TCC 拒絕、磁碟拔掉、雲端登出都會在這裡失敗。
    private static func isReadable(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    /// bookmark 建立當時記下的路徑。**不解析、不碰檔案系統，更不會嘗試掛載磁碟**
    /// ——這是 `URL(resolvingBookmarkData:)` 在碟沒掛時會做的事，也是它會失敗的原因。
    private static func recordedPath(_ data: Data) -> String? {
        URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path
    }

    /// 這筆 bookmark 指的是哪個路徑。解得開就用解出來的，解不開就用它記下的。
    private static func path(of entry: Entry) -> String? {
        if let url = entry.url { return comparablePath(url) }
        guard let recorded = recordedPath(entry.data) else { return nil }
        return comparablePath(URL(filePath: recorded, directoryHint: .isDirectory))
    }

    private static func comparablePath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
