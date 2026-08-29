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

    /// PhotoKit 只有 `.addOnly` 與 `.readWrite` 兩級，**沒有唯讀**。
    /// Foldwall 只讀不寫，但要列相簿就只能要 `.readWrite`。
    nonisolated static let accessLevel = PHAccessLevel.readWrite

    nonisolated static var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: accessLevel)
    }

    @discardableResult
    static func requestAuthorization() async -> PHAuthorizationStatus {
        let before = authorizationStatus
        let after = await PHPhotoLibrary.requestAuthorization(for: accessLevel)
        Log.sources.info("照片授權：\(describe(before), privacy: .public) → \(describe(after), privacy: .public)")
        return after
    }

    static func describe(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: String(localized: "尚未詢問")
        case .restricted: String(localized: "受限")
        case .denied: String(localized: "已拒絕")
        case .authorized: String(localized: "已允許")
        case .limited: String(localized: "部分允許")
        @unknown default: String(localized: "未知(\(status.rawValue))")
        }
    }

    // MARK: - 相簿清單

    /// 使用者相簿 + 智慧相簿（最近項目、我的最愛等）。空相簿不列。
    /// `nonisolated`：PhotoKit 的 fetch 本來就可以在背景執行緒跑，
    /// 而列舉十萬張的圖庫要好幾秒——擋在主執行緒上啟動時選單列就點不開。
    nonisolated static func albums() -> [PhotoAlbum] {
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
                    title: collection.localizedTitle ?? String(localized: "未命名相簿"),
                    count: assets.count
                ))
            }
        }

        return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    nonisolated private static func imageFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        // 影片不進靜態池；影片桌布另有 extension 管線
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        return options
    }

    // MARK: - 匯出

    /// 從相簿隨機取 N 張匯出到快取，回傳本機路徑。
    /// 已匯出過的直接重用，不重複解碼。
    /// `nonisolated` 的理由同 `albums()`：`fetchAssets` 走一趟十萬張的相簿、
    /// `Materializer.evict` 要列整個快取目錄，都不該壓在主執行緒上。
    nonisolated func export(albumID: String, limit: Int) async -> [URL] {
        guard Self.authorizationStatus == .authorized || Self.authorizationStatus == .limited else {
            return []
        }

        let collections = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumID], options: nil
        )
        guard let album = collections.firstObject else { return [] }

        let assets = PHAsset.fetchAssets(in: album, options: Self.imageFetchOptions())
        guard assets.count > 0 else { return [] }

        // **不要**用 Array(0..<count).shuffled()：使用者的相簿實測有 101,046 張，
        // 那等於為了抽幾張而配置並洗牌十萬個 Int，每次補貨都來一次。
        var picked: [PHAsset] = []
        for index in RandomSample.indices(count: limit, total: assets.count) {
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

    nonisolated private func export(_ asset: PHAsset) async -> URL? {
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

        // 統一寫成 JPEG：HEIC 也能被後續管線讀，但副檔名要對得上內容。
        // 轉碼與寫檔都丟到背景：這個型別是 @MainActor，留在原地就是在主執行緒上
        // 解一張 4000×3000 的照片，一輪 20 張，畫面一定卡。
        let converted = await Task.detached(priority: .utility) {
            ImageTranscoder.jpegData(from: data)
        }.value
        guard let jpeg = converted else { return nil }

        do {
            try jpeg.write(to: destination, options: .atomic)
            return destination
        } catch {
            Log.sources.error("照片寫入快取失敗：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
