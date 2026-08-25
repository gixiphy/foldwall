//  RemoteFetcher.swift
//  網路來源 → 本機檔案。下載進 Caches，之後就和資料夾來源走同一條管線。

import Foundation

public struct RemoteFetcher: Sendable {

    /// 網路來源快取上限，與 SMB 快取分開計算。
    public static let defaultCacheLimitBytes = 1024 * 1024 * 1024   // 1GB

    private let cacheDirectory: URL
    private let limitBytes: Int
    private let session: URLSession

    public init(
        cacheDirectory: URL,
        limitBytes: Int = RemoteFetcher.defaultCacheLimitBytes,
        session: URLSession = .shared
    ) {
        self.cacheDirectory = cacheDirectory
        self.limitBytes = limitBytes
        self.session = session
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
        return local
    }

    /// 已經下載過就直接用，不重抓。
    public func cacheURL(for image: RemoteImage, kind: RemoteSourceKind) -> URL {
        let ext = image.url.pathExtension.lowercased()
        let name = "\(kind.rawValue)-\(Self.digest(image.id))"
        return cacheDirectory.appending(path: ext.isEmpty ? "\(name).jpg" : "\(name).\(ext)")
    }

    private func download(_ image: RemoteImage, from source: any RemotePhotoSource) async throws -> URL {
        let destination = cacheURL(for: image, kind: source.kind)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        let (data, response) = try await session.data(for: source.downloadRequest(for: image))
        try Self.validate(response)
        try data.write(to: destination, options: .atomic)
        return destination
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
