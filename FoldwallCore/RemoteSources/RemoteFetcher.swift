//  RemoteFetcher.swift
//  網路來源 → 本機檔案。下載進 Caches，之後就和資料夾來源走同一條管線。

import Foundation

public struct RemoteFetcher: Sendable {

    /// 網路來源快取上限，與 SMB 快取分開計算。
    public static let defaultCacheLimitBytes = 1024 * 1024 * 1024   // 1GB

    private let cacheDirectory: URL
    private let limitBytes: Int
    private let session: URLSession
    private let credits: CreditStore

    public init(
        cacheDirectory: URL,
        limitBytes: Int = RemoteFetcher.defaultCacheLimitBytes,
        session: URLSession = .shared
    ) {
        self.cacheDirectory = cacheDirectory
        self.limitBytes = limitBytes
        self.session = session
        self.credits = CreditStore(directory: cacheDirectory)
    }

    /// 抓清單、下載、回傳本機路徑。單張失敗只跳過那張，不中斷整批。
    public func fetch(source: any RemotePhotoSource, limit: Int) async throws -> [URL] {
        let (data, response) = try await session.data(for: try source.listRequest(limit: limit))
        try Self.validate(response)

        let images = try source.parse(data)
        guard !images.isEmpty else { return [] }

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        var local: [URL] = []
        for image in images.prefix(limit) {
            if let url = try? await download(image, from: source) {
                local.append(url)
            }
        }

        try? Materializer.evict(directory: cacheDirectory, limitBytes: limitBytes)
        // 汰舊之後把出處表裡的孤兒一併清掉，不然它只會一直長
        credits.prune(keeping: (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil)) ?? [])
        return local
    }

    /// 只打一次清單、解析、回報數量——**不下載任何圖**。
    /// 設定視窗的「測試」用這個：使用者要知道 key 對不對、路由通不通，
    /// 不是要它現在就抓一批圖回來。
    public func probe(source: any RemotePhotoSource) async throws -> Int {
        let (data, response) = try await session.data(for: try source.listRequest(limit: 8))
        try Self.validate(response)
        return try source.parse(data).count
    }

    /// 已經下載過就直接用，不重抓。
    public func cacheURL(for image: RemoteImage, kind: RemoteSourceKind) -> URL {
        let ext = image.url.pathExtension.lowercased()
        let name = "\(kind.rawValue)-\(Self.digest(image.id))"
        return cacheDirectory.appending(path: ext.isEmpty ? "\(name).jpg" : "\(name).\(ext)")
    }

    private func download(_ image: RemoteImage, from source: any RemotePhotoSource) async throws -> URL {
        // 快取名用 image.id，而 id 在兩段式來源裡從清單頁就定了——
        // 所以這個檢查在解析詳細頁**之前**做，已經有的就完全不必再進去那一層。
        let destination = cacheURL(for: image, kind: source.kind)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        let image = try await resolve(image, from: source)
        // 串流落地，不整檔吃進記憶體：原圖一張可能 10–30MB，一批 12 張
        // 用 data(for:) 等於平白多一份整檔的暫存峰值。
        let (temp, response) = try await session.download(for: source.downloadRequest(for: image))
        do {
            try Self.validate(response)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }

        // 授權要求標註作者，而現在是唯一知道作者是誰的時候——快取裡只剩檔案。
        credits.record(image.attribution, for: destination)

        // Unsplash 規範：實際用到照片時要回報一次。失敗不影響已經抓好的圖，
        // 所以吞掉錯誤——但**不能不打**，那是拿 production 額度的硬性要求。
        if let trigger = source.downloadTriggerRequest(for: image) {
            _ = try? await session.data(for: trigger)
        }
        return destination
    }

    /// 兩段式來源的第二段：進詳細頁把原圖網址挖出來。一段式來源直接原樣回傳。
    private func resolve(
        _ image: RemoteImage, from source: any RemotePhotoSource
    ) async throws -> RemoteImage {
        guard let request = source.detailRequest(for: image) else { return image }
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        guard let resolved = try source.parseDetail(data, for: image) else {
            throw RemoteSourceError.malformedResponse(source.kind)
        }
        return resolved
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw RemoteSourceError.httpStatus(http.statusCode)
        }
    }

    /// 檔名用的短雜湊。用 FNV-1a 就夠——這只是避免檔名衝突，不是安全用途。
    static func digest(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}
