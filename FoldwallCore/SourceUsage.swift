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

/// 預先算好的根目錄比對表。
///
/// **重點是「算一次」。** 原本 `root(of:in:)` 對每個 URL 都把每個根目錄重新
/// standardize 一次——68 萬個檔就是 68 萬次多餘的字串配置。實測那個版本
/// 走完 68 萬筆要 4.39 秒，而它跑在主執行緒上、每輪 refresh 一次。
public struct RootMatcher: Sendable {

    /// (根目錄, 不含結尾斜線的路徑)
    private let bases: [(root: URL, path: String)]

    public init(_ roots: [URL]) {
        // 只有根目錄需要 standardize（數量是個位數）。被比對的檔案 URL 來自
        // FileManager 的列舉器或存下來的絕對路徑，本來就沒有 `..` 要化簡，
        // 對它們做 standardize 就是純浪費（實測佔了 7 倍的時間）。
        self.bases = roots.map { root in
            let path = root.standardizedFileURL.path(percentEncoded: false)
            return (root, path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path)
        }
    }

    public var isEmpty: Bool { bases.isEmpty }
    public var roots: [URL] { bases.map(\.root) }

    /// 這個檔屬於哪個根目錄。都不屬於就回 nil。
    public func root(of url: URL) -> URL? {
        let path = url.path(percentEncoded: false)
        // 比到路徑分隔為止：`/Volumes/Arch` 不該吃掉 `/Volumes/Archive`
        for base in bases where path == base.path || path.hasPrefix(base.path + "/") {
            return base.root
        }
        return nil
    }
}

public enum SourceUsageMap {

    /// 把 URL 對應回它所屬的根目錄。
    ///
    /// 一次性的查詢用這個就好；要走過大量檔案請改用 `RootMatcher`，
    /// 它把根目錄的路徑先算好，不會每個檔案重算一次。
    public static func root(of url: URL, in roots: [URL]) -> URL? {
        RootMatcher(roots).root(of: url)
    }

    /// 只留下用途包含 `needed` 的根目錄。
    ///
    /// - Parameter usage: 根目錄 → 用途。查不到的當成 `.both`（預設兩者都用）。
    public static func allowedRoots(
        _ roots: [URL], usage: [String: SourceUsage], needing needed: SourceUsage
    ) -> [URL] {
        roots.filter { (usage[$0.standardizedFileURL.path] ?? .both).contains(needed) }
    }

    /// 只留下所屬根目錄有標記 `needed` 用途的項目。
    ///
    /// **走過大量檔案時請在背景執行緒呼叫。** 68 萬筆要花 0.6 秒左右，
    /// 那不是可以放在主執行緒上的東西。
    public static func filter(
        _ urls: [URL],
        roots: [URL],
        usage: [String: SourceUsage],
        needing needed: SourceUsage
    ) -> [URL] {
        let allowed = allowedRoots(roots, usage: usage, needing: needed)
        guard allowed.count != roots.count else { return urls }   // 全都要就不必逐一比對
        guard !allowed.isEmpty else { return [] }

        let matcher = RootMatcher(allowed)
        return urls.filter { matcher.root(of: $0) != nil }
    }
}
