//  MediaIndexer.swift
//  掃根目錄、分類、濾掉 sidecar 與過小圖。不解析書籤、不物化、不 decode 影像。

import Foundation
import ImageIO

public protocol MediaIndexing: Sendable {
    func scan(roots: [URL]) async -> [IndexedItem]
}

public struct MediaIndexer: MediaIndexing {

    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif", "avif",
    ]
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// 短邊低於此值視為 icon 等雜訊圖，不進靜態池。影片不受此限。
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
            if kind == .image, !hasUsableDimensions(url) { continue }
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

    /// 只讀 metadata 判斷尺寸，**不 decode**。讀不到（壞檔）→ 不進池。
    private static func hasUsableDimensions(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return false }

        return min(width, height) >= minimumShortSide
    }
}
