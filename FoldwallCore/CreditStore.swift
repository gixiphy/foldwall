//  CreditStore.swift
//  記住「這個快取檔是誰拍的」。
//
//  為什麼需要：Unsplash 與 Pexels 的授權都要求標註作者，而抓下來的那一刻是唯一
//  知道作者是誰的時候——快取目錄裡只剩檔案，合成時再也問不出來。所以下載完
//  順手記一筆，合成時查回去、燒進圖片角落（見 MontageComposer）。
//
//  一個目錄一份 JSON，鍵是檔名。不用每檔一個 sidecar：那些檔案會被
//  MediaIndexer 掃到、被 AggregateFolder 硬連結，多一種副檔名就多一處要排除。

import Foundation

public protocol CreditLookup: Sendable {
    /// 這個檔案的出處。nil＝本機來源，不必標。
    func credit(for file: URL) -> String?
}

public struct CreditStore: CreditLookup {

    public static let fileName = "credits.json"

    private let directory: URL
    private var indexURL: URL { directory.appending(path: Self.fileName) }

    public init(directory: URL) {
        self.directory = directory
    }

    public func credit(for file: URL) -> String? {
        // 只認自己目錄底下的檔案；別的來源（資料夾、相簿）本來就沒有出處要標
        guard file.deletingLastPathComponent().standardizedFileURL
            == directory.standardizedFileURL else { return nil }
        return load()[file.lastPathComponent]
    }

    /// 記一筆。`credit` 是 nil 就不記——免得在 JSON 裡塞一堆空值。
    public func record(_ credit: String?, for file: URL) {
        guard let credit, !credit.isEmpty else { return }
        var table = load()
        guard table[file.lastPathComponent] != credit else { return }
        table[file.lastPathComponent] = credit
        save(table)
    }

    /// 快取被汰舊之後把孤兒清掉，不然這份表會一直長。
    public func prune(keeping files: [URL]) {
        let alive = Set(files.map(\.lastPathComponent))
        let table = load()
        let kept = table.filter { alive.contains($0.key) }
        if kept.count != table.count { save(kept) }
    }

    // MARK: - 私有

    /// 讀過的表留在記憶體裡。合成時**每一片**都要查一次出處，
    /// 沒有這層就是每片一次「讀檔＋解 JSON」，乘上片數×螢幕數×每 5 分鐘一輪。
    /// 寫入都經過 `save`（同程序內沒有別人動這個檔），所以快取只在 save 時更新。
    private final class TableCache: @unchecked Sendable {
        private let lock = NSLock()
        private var tables: [String: [String: String]] = [:]

        func table(at url: URL, loader: () -> [String: String]) -> [String: String] {
            let key = url.path
            if let cached = lock.withLock({ tables[key] }) { return cached }
            let loaded = loader()
            lock.withLock { tables[key] = loaded }
            return loaded
        }

        func update(_ table: [String: String], at url: URL) {
            lock.withLock { tables[url.path] = table }
        }
    }

    private static let cache = TableCache()

    private func load() -> [String: String] {
        Self.cache.table(at: indexURL) {
            guard let data = try? Data(contentsOf: indexURL),
                  let table = try? JSONDecoder().decode([String: String].self, from: data)
            else { return [:] }
            return table
        }
    }

    private func save(_ table: [String: String]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(table) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
        Self.cache.update(table, at: indexURL)
    }
}

/// 好幾個快取目錄各有一份，合成時要一起查。
public struct CombinedCreditLookup: CreditLookup {
    private let stores: [any CreditLookup]

    public init(_ stores: [any CreditLookup]) {
        self.stores = stores
    }

    public func credit(for file: URL) -> String? {
        for store in stores {
            if let credit = store.credit(for: file) { return credit }
        }
        return nil
    }
}
