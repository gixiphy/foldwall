//  MediaIndexer.swift
//  掃根目錄、分類、濾掉 sidecar。不解析書籤、不物化、不開檔。
//
//  **只看副檔名。** 短邊 <256px 的雜訊圖不在這裡濾——那要開檔讀 metadata，
//  走 SMB 是每檔一次網路往返：實測 90 萬檔的相簿，純列舉 3589 項/秒（4.2 分鐘），
//  逐檔讀 header 只有 9.1 張/秒（27 小時）。門檻改由 StillPipeline 在抽中時驗，
//  一輪只付 6–12 張的成本。

import Foundation

public protocol MediaIndexing: Sendable {
    func scan(roots: [URL]) async -> [IndexedItem]
}

public struct MediaIndexer: MediaIndexing {

    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif", "avif",
    ]
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// 短邊低於此值視為 icon 等雜訊圖，抽片時剔除（見 StillPipeline）。影片不受此限。
    public static let minimumShortSide = 256

    public init() {}

    public func scan(roots: [URL]) async -> [IndexedItem] {
        await withTaskGroup(of: [IndexedItem].self) { group in
            for root in roots {
                group.addTask { Self.scanRoot(root) }
            }
            var all: [IndexedItem] = []
            for await chunk in group {
                all.append(contentsOf: chunk)
            }
            // 固定順序：讓同一 seed 的蒙太奇可重現
            return all.sorted { $0.url.path < $1.url.path }
        }
    }

    private static func scanRoot(_ root: URL) -> [IndexedItem] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []   // 讀不到（不存在／TCC 拒絕）→ 空池，由上層標離線
        }

        var items: [IndexedItem] = []
        for case let url as URL in walker {
            guard let kind = classify(url) else { continue }
            items.append(IndexedItem(url: url, kind: kind))
        }
        return items
    }

    private static func classify(_ url: URL) -> MediaKind? {
        let name = url.lastPathComponent
        // .skipsHiddenFiles 已擋掉大部分，這裡再保險一次（含 AppleDouble `._*`）
        guard !name.hasPrefix(".") else { return nil }

        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil   // 含 .json 等 sidecar
    }
}
