//  AggregateFolder.swift
//  把散在三個快取目錄裡的圖，彙整成**一個實體資料夾**，讓系統的螢幕保護程式
//  能一次指到全部。
//
//  為什麼需要這層：快取分成 remote／photos／smb 三個目錄（各自有不同的淘汰預算），
//  但螢保的來源只能選一個資料夾，而且不保證會遞迴子目錄。
//
//  用**硬連結**而不是拷貝：同一個磁碟上不佔額外空間。代價是連結會讓 inode 的
//  參照數不歸零——快取淘汰刪掉原檔時，空間不會真的釋放。所以每次同步都必須
//  把來源已消失的連結一併清掉，這是這個型別存在的主要理由。

import Foundation

public struct AggregateFolder: Sendable {

    public struct Outcome: Sendable, Equatable {
        public var linked = 0
        public var pruned = 0
        /// 硬連結建不起來（跨磁碟）而改用符號連結的數量。
        public var symlinked = 0

        public init(linked: Int = 0, pruned: Int = 0, symlinked: Int = 0) {
            self.linked = linked
            self.pruned = pruned
            self.symlinked = symlinked
        }
    }

    public init() {}

    /// 讓 `destination` 的內容剛好對應 `sources` 裡的所有影像檔。
    @discardableResult
    public func sync(sources: [URL], into destination: URL) throws -> Outcome {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        // 想要的：所有來源目錄裡的影像檔，以檔名為鍵。
        // 檔名本身已經帶來源前綴或雜湊（pexels-／photos-／smb 的 sha），不會撞。
        var wanted: [String: URL] = [:]
        for source in sources {
            let entries = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
            for entry in entries
            where MediaIndexer.imageExtensions.contains(entry.pathExtension.lowercased()) {
                wanted[entry.lastPathComponent] = entry
            }
        }

        var outcome = Outcome()
        let existing = (try? fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)) ?? []

        // 清掉來源已消失的連結。**這一步不能省**：硬連結會讓原檔的 inode
        // 一直活著，快取淘汰刪了原檔也不會釋放空間。
        for entry in existing where wanted[entry.lastPathComponent] == nil {
            if (try? fm.removeItem(at: entry)) != nil { outcome.pruned += 1 }
        }

        let present = Set(existing.map(\.lastPathComponent))
        for (name, source) in wanted where !present.contains(name) {
            let link = destination.appending(path: name)
            do {
                try fm.linkItem(at: source, to: link)
                outcome.linked += 1
            } catch {
                // 跨磁碟就退回符號連結：內容一樣看得到，只是原檔沒了會變成斷鏈
                if (try? fm.createSymbolicLink(at: link, withDestinationURL: source)) != nil {
                    outcome.symlinked += 1
                }
            }
        }
        return outcome
    }

    /// 目前有幾個可用的連結。斷鏈不算。
    public func count(in destination: URL) -> Int {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { fm.fileExists(atPath: $0.resolvingSymlinksInPath().path) }.count
    }
}
