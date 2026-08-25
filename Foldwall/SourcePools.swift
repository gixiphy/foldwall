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
        // 影片來源（Pexels 影片）不進靜態蒙太奇池，由 RemoteVideoPool 管
        let enabled = configs.filter { $0.isEnabled && $0.kind.media == .image }
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

    static func describe(_ error: Error) -> String {
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

/// 網路**影片**來源的池。跟照片池同一套「快取就是池」的策略，但參數差很多：
/// 影片一支幾十 MB，補貨間隔要拉長、批次要小、快取上限要另外算。
///
/// 下載時機由 WallpaperCoordinator 控制——只在螢幕重新亮起那條背景線上呼叫，
/// 不會在合成路徑上發生。
/// 設定視窗的「測試」：只打一次清單、不下載。
@MainActor
enum SourceProbe {

    static func test(_ config: RemoteSourceConfig) async -> SourceTestResult {
        do {
            let key = KeychainStore.get(AppSettings.keychainAccount(for: config))
            let source = try RemoteSourceFactory.make(config: config, key: key)
            let count = try await RemoteFetcher(cacheDirectory: AppPaths.standard().remoteCache)
                .probe(source: source)
            return .fromCount(count)
        } catch {
            return .fromError(error)
        }
    }
}

@MainActor
final class RemoteVideoPool {

    /// 池低於這個數量就補貨。輪替一次只用 1–3 支，備著十來支就夠輪很久。
    private static let minimumPoolSize = 12
    /// 兩次補貨的最短間隔。影片檔大，比照片保守得多。
    private static let refillInterval: TimeInterval = 6 * 60 * 60
    /// 每個來源單次抓幾支。
    private static let batchSize = 6
    /// 網路影片快取上限，與照片快取分開算。
    private static let cacheLimitBytes = 2 * 1024 * 1024 * 1024

    private let directory: URL
    private let fetcher: RemoteFetcher
    private var lastRefill: Date?
    private var isRefilling = false

    private(set) var lastError: String?

    init(paths: AppPaths = .standard()) {
        self.directory = paths.caches.appending(path: "remoteVideos")
        self.fetcher = RemoteFetcher(cacheDirectory: directory, limitBytes: Self.cacheLimitBytes)
    }

    func videos(configs: [RemoteSourceConfig]) async -> [URL] {
        let enabled = configs.filter { $0.isEnabled && $0.kind.media == .video }
        guard !enabled.isEmpty else {
            lastError = nil
            return []
        }

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
                Log.sources.info("\(config.kind.rawValue, privacy: .public) 取得 \(urls.count) 支影片")
            } catch {
                failures.append("\(config.kind.displayName)：\(RemoteSourcePool.describe(error))")
                Log.sources.error("\(config.kind.rawValue, privacy: .public) 失敗：\(String(describing: error), privacy: .public)")
            }
        }
        lastError = failures.isEmpty ? nil : failures.joined(separator: "、")
    }

    private func cachedFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter { MediaIndexer.videoExtensions.contains($0.pathExtension.lowercased()) }
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
