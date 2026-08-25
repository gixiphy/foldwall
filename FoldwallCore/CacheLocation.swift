//  CacheLocation.swift
//  「東西放在哪」的描述。設定視窗用它列表，使用者可以直接複製路徑——
//  例如把系統的螢幕保護程式來源指到照片快取。
//
//  **一組可以涵蓋多個目錄。** 使用者心裡只有「照片」和「影片」兩類，
//  不需要知道網路下載、相簿匯出、SMB 副本各自躺在哪個子目錄。
//  `url` 是這組的代表目錄（複製路徑／在 Finder 顯示用），
//  `members` 是清除與統計要涵蓋的全部。

import Foundation

public struct CacheLocation: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var purpose: String
    /// 這組的代表目錄：複製路徑與「在 Finder 顯示」用這個。
    public var url: URL
    /// 這組實際涵蓋的所有目錄。統計與清除走這份清單。
    public var members: [URL]
    /// 放在 `~/Library/Caches` 底下：**系統空間不足時會被清掉**，
    /// 拿它當螢保來源要有心理準備。
    public var isPurgeable: Bool

    public init(
        id: String, name: String, purpose: String,
        url: URL, members: [URL]? = nil, isPurgeable: Bool
    ) {
        self.id = id
        self.name = name
        self.purpose = purpose
        self.url = url
        self.members = members ?? [url]
        self.isPurgeable = isPurgeable
    }

    /// 貼進「前往檔案夾」或終端機都能用的形式。
    public var displayPath: String {
        let home = URL.homeDirectory.path
        return url.path.hasPrefix(home)
            ? "~" + url.path.dropFirst(home.count)
            : url.path
    }

    public enum ClearError: Error, Equatable {
        /// 安全閥：路徑不在 Foldwall 自己的目錄底下，一律拒絕。
        case refusedOutsideAppDirectories(URL)
    }

    /// 清空目錄**內容**（保留目錄本身）。
    ///
    /// 為什麼要有安全閥：這個型別的 url 目前都來自 AppPaths，但刪除是不可逆的，
    /// 哪天有人多加一個來源、或設定被改壞，這道檢查就是最後一關。
    /// 同樣的理由，VideoLibrary.remove 也只接受 UUID 形狀的目錄名。
    @discardableResult
    public func clearContents() throws -> Int {
        // 先把整組檢查過一遍再動手：有一個不合格就整組不做，
        // 免得刪到一半才發現問題、留下半清空的狀態。
        for directory in members where !directory.path.lowercased().contains("foldwall") {
            throw ClearError.refusedOutsideAppDirectories(directory)
        }

        let fm = FileManager.default
        var removed = 0
        for directory in members {
            let entries = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for entry in entries where (try? fm.removeItem(at: entry)) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// 整組加總有幾個檔、共多少位元組。目錄不存在就當成空的。
    public func measure() -> (count: Int, bytes: Int64) {
        members.reduce(into: (count: 0, bytes: Int64(0))) { total, directory in
            let one = Self.measure(directory)
            total.count += one.count
            total.bytes += one.bytes
        }
    }

    private static func measure(_ directory: URL) -> (count: Int, bytes: Int64) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
        ) else { return (0, 0) }

        var bytes: Int64 = 0
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true {
                // 影片是 <uuid>/<檔名> 的兩層結構，要往下數一層
                let inner = (try? fm.contentsOfDirectory(
                    at: entry, includingPropertiesForKeys: [.fileSizeKey])) ?? []
                for file in inner {
                    bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                }
            } else {
                bytes += Int64(values?.fileSize ?? 0)
            }
        }
        return (entries.count, bytes)
    }
}
