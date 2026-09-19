//  VideoPrefetcher.swift
//  把 File Provider 上還沒下載的影片在背景抓下來。
//
//  Box 這類 provider 不支援邊讀邊抓：mpv／AVPlayer 一開檔就得等整支下載完。
//  所以引擎不該對 dataless 檔開檔，改由這裡觸發下載，抓完才交給播放器。
//
//  **不設總時限。** 檔案大小與網速都不是我們能假設的；抓不到的代價只是
//  繼續播現在這支，不是把好片送進冷卻。
//
//  帳只記自己抓的。播完後釋放（設定開著時）只動這些，不碰使用者手動下載的。

import Foundation

public actor VideoPrefetcher {

    public typealias Probe = @Sendable (URL) -> VideoSourceLocation
    public typealias Trigger = @Sendable (URL) throws -> Void
    public typealias Fallback = @Sendable (URL) async -> Void
    public typealias Evict = @Sendable (URL) throws -> Void

    private var fetchedByUs: Set<String>
    private var inflight: [String: Task<Bool, Never>] = [:]
    private var waiters: [String: Int] = [:]
    /// 同一支重新開抓時加一。取消回呼晚到時用它認「這不是我那輪」，
    /// 才不會把剛開始的下一輪一起清掉。
    private var generation: [String: Int] = [:]

    private let ledgerURL: URL?
    private let probe: Probe
    private let trigger: Trigger
    private let fallback: Fallback
    private let evict: Evict
    private let pollInterval: Duration

    public init(
        ledgerURL: URL? = nil,
        probe: @escaping Probe = { VideoBufferPolicy.location(for: $0) },
        trigger: @escaping Trigger = { try FileManager.default.startDownloadingUbiquitousItem(at: $0) },
        fallback: @escaping Fallback = { url in
            await Task.detached(priority: .utility) {
                // 讀 1 byte 逼 File Provider 開始物化。startDownloading 丟錯時的退路。
                guard let handle = try? FileHandle(forReadingFrom: url) else { return }
                _ = try? handle.read(upToCount: 1)
                try? handle.close()
            }.value
        },
        evict: @escaping Evict = { try FileManager.default.evictUbiquitousItem(at: $0) },
        pollInterval: Duration = .seconds(1)
    ) {
        self.ledgerURL = ledgerURL
        self.probe = probe
        self.trigger = trigger
        self.fallback = fallback
        self.evict = evict
        self.pollInterval = pollInterval
        if let ledgerURL,
           let data = try? Data(contentsOf: ledgerURL),
           let stored = try? JSONDecoder().decode(Set<String>.self, from: data) {
            fetchedByUs = stored
        } else {
            fetchedByUs = []
        }
    }

    /// 抓這支，抓完回 true。同一支的併發呼叫共用一次觸發。
    ///
    /// 呼叫端取消時，沒有其他人在等就停掉輪詢。已經在本機的不記帳——
    /// 那不是我們抓的，之後的釋放不能動它。
    public func fetch(_ url: URL) async -> Bool {
        let key = Self.key(url)
        let (generation, task) = enlist(key, url)
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.dropWaiter(key, generation: generation, cancelIfLast: true) }
        }
        if !Task.isCancelled {
            dropWaiter(key, generation: generation, cancelIfLast: false)
        }
        return Task.isCancelled ? false : outcome
    }

    /// 只釋放帳上有的。帳外的（使用者自己下載的）連 evict 都不呼叫。
    @discardableResult
    public func release(_ url: URL) -> Bool {
        let key = Self.key(url)
        guard fetchedByUs.contains(key) else { return false }
        do {
            try evict(url)
        } catch {
            // Provider 暫時拒絕時保留帳目，之後（包含重開 app）才能再試。
            return false
        }
        fetchedByUs.remove(key)
        persist()
        return true
    }

    /// 設定剛打開時，把已經播完、沒人在用的那些還回去。
    public func releaseAll(keeping: Set<URL>) {
        let keep = Set(keeping.map(Self.key))
        let victims = fetchedByUs.subtracting(keep)
        for key in victims {
            release(URL(fileURLWithPath: key))
        }
    }

    public func isFetchedByUs(_ url: URL) -> Bool {
        fetchedByUs.contains(Self.key(url))
    }

    // MARK: - 私有

    private func enlist(_ key: String, _ url: URL) -> (Int, Task<Bool, Never>) {
        if let existing = inflight[key], !existing.isCancelled {
            waiters[key, default: 0] += 1
            return (generation[key] ?? 0, existing)
        }
        let id = (generation[key] ?? 0) + 1
        generation[key] = id
        let task = Task { await self.perform(url) }
        inflight[key] = task
        waiters[key] = 1
        return (id, task)
    }

    private func dropWaiter(_ key: String, generation expected: Int, cancelIfLast: Bool) {
        guard generation[key] == expected else { return }
        waiters[key, default: 1] -= 1
        guard (waiters[key] ?? 0) <= 0, generation[key] == expected else { return }
        if cancelIfLast { inflight[key]?.cancel() }
        inflight[key] = nil
        waiters[key] = nil
    }

    private func perform(_ url: URL) async -> Bool {
        // resource values 會快取在 URL 實例上，每輪都建一顆新的。
        if !probe(Self.fresh(url)).isNetworked { return true }

        do {
            try trigger(url)
        } catch {
            await fallback(url)
        }

        while !Task.isCancelled {
            if !probe(Self.fresh(url)).isNetworked {
                fetchedByUs.insert(Self.key(url))
                persist()
                return true
            }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return false
            }
        }
        return false
    }

    private func persist() {
        guard let ledgerURL else { return }
        let directory = ledgerURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(fetchedByUs).write(to: ledgerURL, options: .atomic)
    }

    /// 檔案用標準化路徑當帳本鍵，同一支不會因為 URL 寫法不同記兩筆。
    static func key(_ url: URL) -> String {
        url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }

    private static func fresh(_ url: URL) -> URL {
        url.isFileURL ? URL(fileURLWithPath: url.path) : url
    }
}
