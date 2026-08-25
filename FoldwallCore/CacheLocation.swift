//  CacheLocation.swift
//  「東西放在哪」的描述。設定視窗用它列表，使用者可以直接複製路徑——
//  例如把系統的螢幕保護程式來源指到網路來源的原圖目錄。

import Foundation

public struct CacheLocation: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var purpose: String
    public var url: URL
    /// 放在 `~/Library/Caches` 底下：**系統空間不足時會被清掉**，
    /// 拿它當螢保來源要有心理準備。
    public var isPurgeable: Bool

    public init(id: String, name: String, purpose: String, url: URL, isPurgeable: Bool) {
        self.id = id
        self.name = name
        self.purpose = purpose
        self.url = url
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
        guard url.path.lowercased().contains("foldwall") else {
            throw ClearError.refusedOutsideAppDirectories(url)
        }
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for entry in entries where (try? fm.removeItem(at: entry)) != nil {
            removed += 1
        }
        return removed
    }

    /// 目前有幾個檔、共多少位元組。目錄不存在就回 (0, 0)。
    public func measure() -> (count: Int, bytes: Int64) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
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
