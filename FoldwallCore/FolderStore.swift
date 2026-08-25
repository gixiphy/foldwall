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
        /// 解析得出路徑但讀不到（TCC 拒絕、磁碟拔掉、雲端登出）。
        public var offline: [URL]
        /// bookmark 連路徑都解析不出來（來源已刪）。
        public var unresolvedCount: Int

        public var offlineCount: Int { offline.count + unresolvedCount }
    }

    private let defaults: any BookmarkDefaults

    public init(defaults: any BookmarkDefaults) {
        self.defaults = defaults
    }

    // MARK: - 變更

    public func add(_ url: URL) throws {
        let target = url.standardizedFileURL.path
        guard !resolveAll().contains(where: { $0.url?.standardizedFileURL.path == target }) else {
            return   // 已加入，不重複
        }
        var stored = defaults.loadBookmarks()
        stored.append(try BookmarkCodec.data(for: url))
        defaults.saveBookmarks(stored)
    }

    /// 刪除該根的 bookmark。回傳是否真的刪到。
    /// 呼叫端（app 層）另需：讓池重掃、刪掉該來源已拷進 extension container 的影片。
    @discardableResult
    public func remove(_ url: URL) throws -> Bool {
        let target = url.standardizedFileURL.path
        let entries = resolveAll()
        let keep = entries.filter { $0.url?.standardizedFileURL.path != target }
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
                unresolved += 1
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
}
