//  SourceUsage.swift
//  一個來源要餵給哪條管線。
//
//  資料夾是唯一「兩用」的來源：同一個資料夾裡的圖進蒙太奇池、影片進影片庫。
//  使用者不見得兩者都要——放滿影片的資料夾可能只想拿來當影片桌布，
//  相簿資料夾則只想進蒙太奇。所以用途要能逐個資料夾勾選。
//
//  照片相簿只有圖、Pexels 影片只有片，那些由來源種類決定，不給勾。

import Foundation

public struct SourceUsage: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let montage = SourceUsage(rawValue: 1 << 0)
    public static let video   = SourceUsage(rawValue: 1 << 1)

    /// 沒設定過的資料夾兩者都用——與加入資料夾當下的直覺一致。
    public static let both: SourceUsage = [.montage, .video]
}

public enum SourceUsageMap {

    /// 把 URL 對應回它所屬的根目錄。
    /// 比到路徑分隔為止：`/Volumes/Arch` 不該吃掉 `/Volumes/Archive`。
    public static func root(of url: URL, in roots: [URL]) -> URL? {
        let path = url.standardizedFileURL.path
        return roots.first { root in
            let base = root.standardizedFileURL.path
            return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }

    /// 只留下所屬根目錄有標記 `needed` 用途的項目。
    ///
    /// - Parameter usage: 根目錄 → 用途。查不到的當成 `.both`（預設兩者都用）。
    public static func filter(
        _ urls: [URL],
        roots: [URL],
        usage: [String: SourceUsage],
        needing needed: SourceUsage
    ) -> [URL] {
        // 先算好每個根目錄要不要，避免每個檔案都重算
        let allowed = roots.filter { root in
            (usage[root.standardizedFileURL.path] ?? .both).contains(needed)
        }
        guard allowed.count != roots.count else { return urls }   // 全都要就不必逐一比對
        guard !allowed.isEmpty else { return [] }

        return urls.filter { root(of: $0, in: allowed) != nil }
    }
}
