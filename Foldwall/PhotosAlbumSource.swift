//  PhotosAlbumSource.swift
//  Apple「照片」相簿。走 PhotoKit，**不需要 OAuth**，但首次會跳系統授權框。
//
//  匯出成 JPEG 進快取，之後就和其他來源走同一條管線（管線一律吃檔案 URL）。

import AppKit
import Photos
import FoldwallCore

struct PhotoAlbum: Identifiable, Hashable, Sendable {
    var id: String          // PHAssetCollection.localIdentifier
    var title: String
    var count: Int
}

@MainActor
final class PhotosAlbumSource {

    private let cacheDirectory: URL

    init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
    }

    // MARK: - 授權

    static var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    @discardableResult
    static func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: - 相簿清單

    /// 使用者相簿 + 智慧相簿（最近項目、我的最愛等）。空相簿不列。
    static func albums() -> [PhotoAlbum] {
        var result: [PhotoAlbum] = []

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "estimatedAssetCount > 0")

        let collections: [PHFetchResult<PHAssetCollection>] = [
            PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil),
            PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil),
        ]

        for fetch in collections {
            fetch.enumerateObjects { collection, _, _ in
                let assets = PHAsset.fetchAssets(in: collection, options: Self.imageFetchOptions())
                guard assets.count > 0 else { return }
                result.append(PhotoAlbum(
                    id: collection.localIdentifier,
                    title: collection.localizedTitle ?? "未命名相簿",
                    count: assets.count
                ))
            }
        }

        return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func imageFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        // 影片不進靜態池；影片桌布另有 extension 管線
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        return options
    }

    // MARK: - 匯出

    /// 從相簿隨機取 N 張匯出到快取，回傳本機路徑。
    /// 已匯出過的直接重用，不重複解碼。
    func export(albumID: String, limit: Int) async -> [URL] {
        guard Self.authorizationStatus == .authorized || Self.authorizationStatus == .limited else {
            return []
        }

        let collections = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumID], options: nil
        )
        guard let album = collections.firstObject else { return [] }

        let assets = PHAsset.fetchAssets(in: album, options: Self.imageFetchOptions())
        guard assets.count > 0 else { return [] }

        var picked: [PHAsset] = []
        for index in Array(0..<assets.count).shuffled().prefix(limit) {
            picked.append(assets.object(at: index))
        }

        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        var urls: [URL] = []
        for asset in picked {
            if let url = await export(asset) { urls.append(url) }
        }

        try? Materializer.evict(directory: cacheDirectory,
                                limitBytes: RemoteFetcher.defaultCacheLimitBytes)
        return urls
    }

    private func export(_ asset: PHAsset) async -> URL? {
        // localIdentifier 含 "/"，不能直接當檔名
        let name = asset.localIdentifier.replacingOccurrences(of: "/", with: "_")
        let destination = cacheDirectory.appending(path: "photos-\(name).jpg")

        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true   // iCloud 照片圖庫要能下載
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false

        let data: Data? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }

        guard let data else {
            Log.sources.error("照片匯出失敗：\(asset.localIdentifier, privacy: .public)")
            return nil
        }

        // 統一寫成 JPEG：HEIC 也能被後續管線讀，但副檔名要對得上內容
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else { return nil }

        do {
            try jpeg.write(to: destination, options: .atomic)
            return destination
        } catch {
            Log.sources.error("照片寫入快取失敗：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
