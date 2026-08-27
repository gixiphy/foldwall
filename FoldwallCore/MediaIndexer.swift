//  MediaIndexer.swift
//  掃根目錄、分類、濾掉 sidecar。不解析書籤、不物化、不開檔。
//
//  **只看副檔名。** 短邊 <256px 的雜訊圖不在這裡濾——那要開檔讀 metadata，
//  走 SMB 是每檔一次網路往返：實測 90 萬檔的相簿，純列舉 3589 項/秒（4.2 分鐘），
//  逐檔讀 header 只有 9.1 張/秒（27 小時）。門檻改由 StillPipeline 在抽中時驗，
//  一輪只付 6–12 張的成本。

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
        await withTaskGroup(of: (URL, [IndexedItem]?).self) { group in
            for root in roots {
                group.addTask { (root, Self.scanRoot(root)) }
            }
            var all: [IndexedItem] = []
            var unreadable: [URL] = []
            for await (root, chunk) in group {
                if let chunk {
                    all.append(contentsOf: chunk)
                } else {
                    unreadable.append(root)
                }
            }
            // 固定順序：讓同一 seed 的蒙太奇可重現。
            // 排序鍵先算好：`URL.path` 每次取用都配置一個新 String，
            // 直接放進比較器等於 90 萬項 × log n 次的重複配置。
            var keyed = all.map { (key: $0.url.path, item: $0) }
            keyed.sort { $0.key < $1.key }
            return MediaScan(
                items: keyed.map(\.item),
                unreadableRoots: unreadable.sorted { $0.path < $1.path })
        }
    }

    /// - Returns: nil＝這個根目錄打不開（磁碟沒掛／被刪／TCC 拒絕）。
    ///   空陣列是另一回事：目錄在，只是裡面沒有影像檔。
    private static func scanRoot(_ root: URL) -> [IndexedItem]? {
        let fm = FileManager.default

        // 先確認目錄真的在。enumerator(at:) 對不存在的路徑**不一定**回 nil，
        // 它可能給一個第一次 nextObject 就結束的列舉器——那看起來跟「空目錄」
        // 一模一樣，正是要避免的誤判。
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }

        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        // 分批包 autoreleasepool：列舉器吐的是 autorelease 的 Foundation 物件，
        // 這個同步迴圈中途不會讓出，不排掉的話 90 萬檔（4 分鐘）的暫存物件
        // 會全部堆到走完才釋放。
        var items: [IndexedItem] = []
        var finished = false
        while !finished {
            autoreleasepool {
                var step = 0
                while step < 4096, let element = walker.nextObject() {
                    step += 1
                    guard let url = element as? URL, let kind = classify(url) else { continue }
                    items.append(IndexedItem(url: url, kind: kind))
                }
                if step < 4096 { finished = true }
            }
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
