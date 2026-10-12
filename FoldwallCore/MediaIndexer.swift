//  MediaIndexer.swift
//  掃根目錄、分類、濾掉 sidecar。不解析書籤、不物化、不開檔。
//
//  **只看副檔名。** 短邊 <256px 的雜訊圖不在這裡濾——那要開檔讀 metadata，
//  走 SMB 是每檔一次網路往返：實測 90 萬檔的相簿，純列舉 3589 項/秒（4.2 分鐘），
//  逐檔讀 header 只有 9.1 張/秒（27 小時）。門檻改由 StillPipeline 在抽中時驗，
//  一輪只付 6–12 張的成本。
//
//  走訪本身交給 TreeScanner（getattrlistbulk＋目錄層級平行）。這個型別留著，
//  是給只需要「全量掃一次、拿平面清單」的呼叫端與既有測試。

import Foundation

/// 一輪掃描的結果。
///
/// `unreadableRoots` 是這個型別存在的理由：**「掃過但沒東西」和「根本打不開」
/// 必須分得開。** 兩者都回空清單的話，NAS 沒掛載時上層會以為來源真的空了，
/// 影片差異同步就把 extension container 裡還在的影片全刪掉。
public struct MediaScan: Sendable, Equatable {
    public var items: [IndexedItem]
    /// 打不開的根目錄：磁碟沒掛、被刪、TCC 拒絕。
    public var unreadableRoots: [URL]

    public init(items: [IndexedItem] = [], unreadableRoots: [URL] = []) {
        self.items = items
        self.unreadableRoots = unreadableRoots
    }
}

public protocol MediaIndexing: Sendable {
    func scan(roots: [URL]) async -> MediaScan
}

public struct MediaIndexer: MediaIndexing {

    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif", "avif",
    ]
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// 短邊低於此值視為 icon 等雜訊圖，抽片時剔除（見 StillPipeline）。影片不受此限。
    public static let minimumShortSide = 256

    public init() {}

    public func scan(roots: [URL]) async -> MediaScan {
        let keys = roots.map(DirectoryTree.key(for:))
        let result = await TreeScanner().scan(
            previous: DirectoryTree(), roots: keys, scope: nil, relistAll: true)
        let (images, videos) = result.tree.flattened()
        // 圖與影片混在一起照路徑排：同一 seed 的蒙太奇要可重現（跟舊行為一致）
        var keyed = images.map { (key: $0, kind: MediaKind.image) }
            + videos.map { (key: $0, kind: MediaKind.video) }
        keyed.sort { $0.key < $1.key }
        let unreadable = Set(result.unreadableRoots)
        return MediaScan(
            items: keyed.map {
                IndexedItem(url: URL(filePath: $0.key, directoryHint: .notDirectory), kind: $0.kind)
            },
            unreadableRoots: roots
                .filter { unreadable.contains(DirectoryTree.key(for: $0)) }
                .sorted { $0.path < $1.path })
    }

    /// 依檔名分類。隱藏檔（含 AppleDouble `._*`）與 sidecar 回 nil。
    public static func kind(ofName name: String) -> MediaKind? {
        guard !name.hasPrefix(".") else { return nil }
        let ext = (name as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }
}
