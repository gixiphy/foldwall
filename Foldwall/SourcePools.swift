//  SourcePools.swift
//  照片相簿與網路來源的池管理。
//
//  節流是這裡的重點：桌布每 5 分鐘換一次，但**不能**每次都去打 API——
//  Unsplash 免費版每小時只有 50 次請求，那樣半小時就燒光。
//  策略是「磁碟上的快取就是池」，只有在池太薄或距上次抓太久時才補貨。

import Foundation
import FoldwallCore

@MainActor
final class RemoteSourcePool {

    /// 池低於這個數量就補貨。
    private static let minimumPoolSize = 24
    /// 兩次補貨的最短間隔。
    private static let refillInterval: TimeInterval = 30 * 60
    /// 每個來源單次抓幾張。
    private static let batchSize = 12

    private let directory: URL
    private let fetcher: RemoteFetcher
    private var lastRefill: Date?
    private var isRefilling = false

    private(set) var lastError: String?

    init(paths: AppPaths = .standard()) {
        self.directory = paths.caches.appending(path: "remote")
        self.fetcher = RemoteFetcher(cacheDirectory: directory)
    }

    /// 回傳目前池內的本機檔案；必要時在背景補貨。
    func images(configs: [RemoteSourceConfig]) async -> [URL] {
        let enabled = configs.filter(\.isEnabled)
        guard !enabled.isEmpty else { return [] }

        let cached = cachedFiles()
        let stale = lastRefill.map { Date.now.timeIntervalSince($0) > Self.refillInterval } ?? true

        if !isRefilling, cached.count < Self.minimumPoolSize || stale {
            await refill(enabled)
            return cachedFiles()
        }
        return cached
    }

    private func refill(_ configs: [RemoteSourceConfig]) async {
        isRefilling = true
        defer {
            isRefilling = false
            lastRefill = .now
        }

        var failures: [String] = []
        for config in configs {
            let key = KeychainStore.get(AppSettings.keychainAccount(for: config))
            do {
                let source = try RemoteSourceFactory.make(config: config, key: key)
                let urls = try await fetcher.fetch(source: source, limit: Self.batchSize)
                Log.sources.info("\(config.kind.rawValue, privacy: .public) 取得 \(urls.count) 張")
            } catch {
                // 單一來源失敗不影響其他來源，也不影響現有桌布
                failures.append("\(config.kind.displayName)：\(Self.describe(error))")
                Log.sources.error("\(config.kind.rawValue, privacy: .public) 失敗：\(String(describing: error), privacy: .public)")
            }
        }
        lastError = failures.isEmpty ? nil : failures.joined(separator: "、")
    }

    private func cachedFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter { MediaIndexer.imageExtensions.contains($0.pathExtension.lowercased()) }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case RemoteSourceError.missingKey: "缺少 API key"
        case RemoteSourceError.missingEndpoint: "缺少網址"
        case RemoteSourceError.badEndpoint: "網址格式錯誤"
        case RemoteSourceError.malformedResponse: "回應格式不符"
        case RemoteSourceError.httpStatus(let code): "HTTP \(code)"
        default: (error as NSError).localizedDescription
        }
    }
}

@MainActor
final class PhotosPool {

    private static let minimumPoolSize = 24
    private static let refillInterval: TimeInterval = 30 * 60
    private static let batchSize = 24

    private let directory: URL
    private let source: PhotosAlbumSource
    private var lastRefill: Date?

    init(paths: AppPaths = .standard()) {
        self.directory = paths.caches.appending(path: "photos")
        self.source = PhotosAlbumSource(cacheDirectory: directory)
    }

    func images(albums: Set<String>) async -> [URL] {
        guard !albums.isEmpty else { return [] }

        let cached = cachedFiles()
        let stale = lastRefill.map { Date.now.timeIntervalSince($0) > Self.refillInterval } ?? true

        if cached.count < Self.minimumPoolSize || stale {
            for album in albums {
                _ = await source.export(albumID: album, limit: Self.batchSize / max(1, albums.count))
            }
            lastRefill = .now
            return cachedFiles()
        }
        return cached
    }

    private func cachedFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter { $0.pathExtension.lowercased() == "jpg" }
    }
}
