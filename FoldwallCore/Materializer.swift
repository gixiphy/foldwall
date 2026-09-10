//  Materializer.swift
//  合成前把來源變成「本機讀得到的檔案」：
//  File Provider（iCloud／Box／pCloud）dataless 先下載；SMB 等網路磁碟先拷到本機快取。
//  失敗一律 throw，由上層標離線、換下一張——不黑屏。

import CryptoKit
import Foundation
import os

public struct Materializer: MediaPreparing, Sendable {

    public enum Failure: Error, Equatable {
        case unavailable(URL)
        case downloadTimedOut(URL)
    }

    /// SMB 快取上限，超過按最舊存取時間 LRU 淘汰。
    public static let defaultCacheLimitBytes = 2 * 1024 * 1024 * 1024
    public static let downloadTimeout: Duration = .seconds(15)

    private let cacheDirectory: URL
    private let limitBytes: Int

    public init(cacheDirectory: URL, limitBytes: Int = Materializer.defaultCacheLimitBytes) {
        self.cacheDirectory = cacheDirectory
        self.limitBytes = limitBytes
    }

    /// 網路磁碟區（Finder 掛的 SMB／AFP）讀取慢又會斷，合成前先拷本機。
    ///
    /// 本機外接磁碟（USB／Thunderbolt）也掛在 `/Volumes/` 底下，但直接讀就好——
    /// 拷一份只是白佔快取額度、把 2GB 的 LRU 提早擠爆。查不到磁碟區屬性
    ///（路徑不存在、磁碟剛拔掉）就當網路磁碟處理，走拷貝那條保守路。
    public static func needsLocalCopy(_ url: URL) -> Bool {
        guard url.standardizedFileURL.path.hasPrefix("/Volumes/") else { return false }
        guard let isLocal = (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal
        else { return true }
        return !isLocal
    }

    /// 來源路徑 → 快取路徑。同一來源永遠對到同一份，副檔名保留給 ImageIO 認格式。
    public func cacheURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension
        return cacheDirectory.appending(path: ext.isEmpty ? name : "\(name).\(ext)")
    }

    public func prepare(_ url: URL) async throws -> URL {
        if Self.needsLocalCopy(url) {
            return try copyToCache(url)
        }

        if try isDataless(url) {
            try await materializeUbiquitous(url)
        }

        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw Failure.unavailable(url)
        }
        return url
    }

    // MARK: - File Provider

    private func isDataless(_ url: URL) throws -> Bool {
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ])
        guard values?.isUbiquitousItem == true else { return false }
        return values?.ubiquitousItemDownloadingStatus != .current
    }

    private func materializeUbiquitous(_ url: URL) async throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)

        let deadline = ContinuousClock.now.advanced(by: Self.downloadTimeout)
        while ContinuousClock.now < deadline {
            let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                .ubiquitousItemDownloadingStatus
            if status == .current { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Failure.downloadTimedOut(url)
    }

    // MARK: - 網路磁碟快取

    private func copyToCache(_ url: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: url.path) else { throw Failure.unavailable(url) }

        let destination = cacheURL(for: url)
        // 已快取且不比來源舊就直接用
        if let cached = try? destination.resourceValues(forKeys: [.contentModificationDateKey]),
           let source = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
           let cachedDate = cached.contentModificationDate,
           let sourceDate = source.contentModificationDate,
           cachedDate >= sourceDate {
            return destination
        }

        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: url, to: destination)

        try? Self.evict(directory: cacheDirectory, limitBytes: limitBytes)
        return destination
    }

    /// 超過上限就從最舊存取的開始砍，砍到低於上限為止。
    ///
    /// - Parameter protecting: **正在用的檔案，一律不砍。**
    ///   純 LRU 會刪掉正在播的那支影片：AVPlayer 抓著開啟中的檔案句柄，
    ///   所以畫面不會馬上壞，但下一輪排片就找不到它、換片，而且那些磁碟區塊
    ///   在句柄關掉之前根本沒被釋放——等於白刪一次還換來一次沒必要的換片。
    ///   保護的檔案仍然算進總量（它們確實佔著空間），只是跳過不刪；
    ///   全部都被保護時就砍不動，那是對的——桌布用量超標，不該拿正在播的去換。
    @discardableResult
    public static func evict(
        directory: URL, limitBytes: Int, protecting: Set<URL> = [],
    ) throws -> Int {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentAccessDateKey, .contentModificationDateKey, .fileSizeKey]
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        let pinned = Set(protecting.map(\.standardizedFileURL.path))

        var entries: [(url: URL, size: Int, stamp: Date)] = []
        var total = 0
        for url in files {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize else { continue }
            let stamp = values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
            total += size
            guard !pinned.contains(url.standardizedFileURL.path) else { continue }
            entries.append((url, size, stamp))
        }

        guard total > limitBytes else { return 0 }

        var removed = 0
        for entry in entries.sorted(by: { $0.stamp < $1.stamp }) {
            guard total > limitBytes else { break }
            guard (try? fm.removeItem(at: entry.url)) != nil else { continue }
            total -= entry.size
            removed += 1
        }
        return removed
    }
}

/// 淘汰時不可以砍的檔案。
///
/// **為什麼要一個共享的盒子而不是一個 closure**：讀它的是快取淘汰
/// （背景、任意執行緒），寫它的是排片（主執行緒上的播放引擎）。
/// closure 直接抓 `@MainActor` 的引擎就是跨隔離讀取；改成由排片那邊
/// 推一份快照進來，兩邊都乾淨。
///
/// 快照會過期一點點（剛換的片可能還沒推進來），代價只是那一支這一輪
/// 沒被保護到——比起讓淘汰完全不知道有誰在播，那是可接受的。
public final class ProtectedFiles: Sendable {

    private let storage = OSAllocatedUnfairLock(initialState: Set<URL>())

    public init() {}

    public var current: Set<URL> {
        storage.withLock { $0 }
    }

    public func update(_ urls: Set<URL>) {
        storage.withLock { $0 = urls }
    }
}
