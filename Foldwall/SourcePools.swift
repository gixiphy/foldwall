//  SourcePools.swift
//  照片相簿與網路來源的池管理。
//
//  節流是這裡的重點：桌布每 5 分鐘換一次，但**不能**每次都去打 API——
//  Unsplash 免費版每小時只有 50 次請求，那樣半小時就燒光。
//  策略是「磁碟上的快取就是池」，只有在池太薄或距上次抓太久時才補貨。
//
//  補貨**永遠不擋呼叫端**：`images`／`videos` 立刻回磁碟上現有的檔，需要補就
//  在背景開一條線去抓，抓完回呼上層補一輪合成。跟 FolderIndex 同一套做法。
//  await 補貨等於把整條合成管線壓在一次網路往返上——網路慢的時候桌布就跟著卡住。

import Foundation
import FoldwallCore

@MainActor
final class RemoteSourcePool {

    /// 池低於這個數量就補貨。
    private static let minimumPoolSize = 24
    /// 兩次補貨的最短間隔。
    private static let refillInterval: TimeInterval = 30 * 60
    /// 池太薄時可以提早補，但再急也要隔這麼久。
    ///
    /// 少了這道下限就會轉不停：補完回呼觸發 refresh，refresh 看池還是太薄
    /// （來源掛了、API key 錯了）又補一次。
    private static let hungryRetryInterval: TimeInterval = 5 * 60
    /// 每個來源單次抓幾張。
    private static let batchSize = 12

    private let directory: URL
    private let fetcher: RemoteFetcher
    private var lastRefill: Date?
    private var refillTask: Task<Void, Never>?

    private(set) var lastError: String?

    /// 補貨真的補到東西時回呼，讓上層補一輪合成——
    /// 不然新抓的圖要等到下一個切換間隔才看得到（間隔設「每天」就是等一天）。
    var onRefilled: (() -> Void)?

    init(paths: AppPaths = .standard()) {
        self.directory = paths.caches.appending(path: "remote")
        self.fetcher = RemoteFetcher(cacheDirectory: directory)
    }

    /// 回傳目前池內的本機檔案。**立刻回，不等網路**；需要補貨就在背景開一條線。
    func images(configs: [RemoteSourceConfig]) -> [URL] {
        // 影片來源（Pexels 影片）不進靜態蒙太奇池，由 RemoteVideoPool 管
        let enabled = configs.filter { $0.isEnabled && $0.kind.media == .image }
        guard !enabled.isEmpty else { return [] }

        let cached = cachedFiles()
        let sinceLast = lastRefill.map { Date.now.timeIntervalSince($0) } ?? .infinity
        let hungry = cached.count < Self.minimumPoolSize && sinceLast > Self.hungryRetryInterval
        if sinceLast > Self.refillInterval || hungry {
            startRefill(enabled)
        }
        return cached
    }

    private func startRefill(_ configs: [RemoteSourceConfig]) {
        guard refillTask == nil else { return }   // 上一輪還在抓就別疊上去
        let before = cachedFiles().count
        refillTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refill(configs)
            self.refillTask = nil
            // 只有真的多了檔才回呼：一直失敗的來源不該把 refresh 叫個不停。
            if self.cachedFiles().count != before { self.onRefilled?() }
        }
    }

    private func refill(_ configs: [RemoteSourceConfig]) async {
        defer { lastRefill = .now }

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
        case RemoteSourceError.missingKey: String(localized: "缺少 API key")
        case RemoteSourceError.missingEndpoint: String(localized: "缺少網址")
        case RemoteSourceError.badEndpoint: String(localized: "網址格式錯誤")
        case RemoteSourceError.malformedResponse: String(localized: "回應格式不符")
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

    /// 池低於這個數量就補貨。有資料夾來源時輪替一次只用 1 支網路片，備著十來支就夠輪很久。
    private static let minimumPoolSize = 12
    /// 兩次補貨的最短間隔。影片檔大，比照片保守得多。
    private static let refillInterval: TimeInterval = 6 * 60 * 60
    /// 池太薄時的提早補貨下限。影片一支幾十 MB，比照片再拉長。
    private static let hungryRetryInterval: TimeInterval = 30 * 60
    /// 每個來源單次抓幾支。
    private static let batchSize = 6
    /// 網路影片快取上限，與照片快取分開算。
    private static let cacheLimitBytes = 2 * 1024 * 1024 * 1024

    private let directory: URL
    private let fetcher: RemoteFetcher
    private var lastRefill: Date?
    private var refillTask: Task<Void, Never>?

    private(set) var lastError: String?

    var onRefilled: (() -> Void)?

    init(paths: AppPaths = .standard()) {
        self.directory = paths.caches.appending(path: "remoteVideos")
        self.fetcher = RemoteFetcher(cacheDirectory: directory, limitBytes: Self.cacheLimitBytes)
    }

    /// 立刻回快取，不等下載。一支影片幾十 MB，await 它會把桌面視窗的切換也卡住。
    func videos(configs: [RemoteSourceConfig]) -> [URL] {
        let enabled = configs.filter { $0.isEnabled && $0.kind.media == .video }
        let cached = cachedFiles()
        // 沒有啟用的網路影片來源就不補貨，但**還是要回傳快取裡的**——
        // 使用者用網址下載的影片也存在這裡，關掉 Pexels 不該讓它們一起消失。
        guard !enabled.isEmpty else {
            lastError = nil
            return cached
        }

        let sinceLast = lastRefill.map { Date.now.timeIntervalSince($0) } ?? .infinity
        let hungry = cached.count < Self.minimumPoolSize && sinceLast > Self.hungryRetryInterval
        if sinceLast > Self.refillInterval || hungry {
            startRefill(enabled)
        }
        return cached
    }

    private func startRefill(_ configs: [RemoteSourceConfig]) {
        guard refillTask == nil else { return }
        let before = cachedFiles().count
        refillTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refill(configs)
            self.refillTask = nil
            if self.cachedFiles().count != before { self.onRefilled?() }
        }
    }

    private func refill(_ configs: [RemoteSourceConfig]) async {
        defer { lastRefill = .now }

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
    private static let hungryRetryInterval: TimeInterval = 5 * 60
    private static let batchSize = 24

    private let directory: URL
    private let source: PhotosAlbumSource
    private var lastRefill: Date?
    private var refillTask: Task<Void, Never>?

    var onRefilled: (() -> Void)?

    init(paths: AppPaths = .standard()) {
        self.directory = paths.caches.appending(path: "photos")
        self.source = PhotosAlbumSource(cacheDirectory: directory)
    }

    /// 立刻回快取。匯出走 PHImageManager，十萬張的相簿慢起來也是好幾秒。
    func images(albums: Set<String>) -> [URL] {
        guard !albums.isEmpty else { return [] }

        let cached = cachedFiles()
        let sinceLast = lastRefill.map { Date.now.timeIntervalSince($0) } ?? .infinity
        let hungry = cached.count < Self.minimumPoolSize && sinceLast > Self.hungryRetryInterval
        if sinceLast > Self.refillInterval || hungry {
            startRefill(albums)
        }
        return cached
    }

    private func startRefill(_ albums: Set<String>) {
        guard refillTask == nil else { return }
        let before = cachedFiles().count
        refillTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for album in albums {
                _ = await self.source.export(
                    albumID: album, limit: Self.batchSize / max(1, albums.count))
            }
            self.lastRefill = .now
            self.refillTask = nil
            if self.cachedFiles().count != before { self.onRefilled?() }
        }
    }

    private func cachedFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter { $0.pathExtension.lowercased() == "jpg" }
    }
}
