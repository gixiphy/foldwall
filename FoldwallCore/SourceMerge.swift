//  SourceMerge.swift
//  把共用的來源目錄併回本機，**不動這台的開關**。
//
//  合併而不是覆蓋，是這整套兩層設計唯一真正有難度的地方：目錄說「手上有這些來源」，
//  本機說「這台開著這幾個」，套用時兩邊都要活下來。規則就三條：
//
//  1. 目錄裡有、本機沒有 → **加進來，預設是開的**。跟使用者自己按「新增」當下的
//     直覺一致；預設關的話，在筆電加的來源會靜悄悄地以關著的樣子出現在桌機上。
//  2. 兩邊都有 → 定義（關鍵字、網址）以目錄為準，**`isEnabled` 留本機的**。
//  3. 目錄裡沒有、本機有 → **移除**。「全部同步」就是要能做減法，
//     不然在一台刪掉的來源永遠清不乾淨。
//
//  順序跟著目錄走，三台的清單看起來才會一樣。
//
//  **`keepingExtras` 是「第一次加入」用的。** 一台機器第一次連上共用目錄時，
//  它手上那些來源還沒進過目錄——照規則 3 一律移除的話，打開自動同步的當下
//  這台的來源就被清光了。第一次改成聯集：先把兩邊併起來推上去，
//  之後才開始做減法。減法要的是「使用者刪了它」，不是「這台還沒來得及上傳」。

import Foundation

public enum SourceMerge {

    /// 目錄 ∪ 本機 → 新的網路來源清單。`isEnabled` 一律留本機的。
    ///
    /// - Parameter keepingExtras: 目錄裡沒有的本機來源留著（接在後面）。第一次加入時用。
    public static func apply(
        _ catalog: [SourceCatalog.Remote], to local: [RemoteSourceConfig],
        keepingExtras: Bool = false
    ) -> [RemoteSourceConfig] {
        let byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let merged = catalog.map { entry in
            RemoteSourceConfig(
                id: entry.id,
                kind: entry.kind,
                // 沒見過的來源預設開著（規則 1）
                isEnabled: byID[entry.id]?.isEnabled ?? true,
                query: entry.query,
                endpoint: entry.endpoint
            )
        }
        guard keepingExtras else { return merged }
        let known = Set(catalog.map(\.id))
        return merged + local.filter { !known.contains($0.id) }
    }

    /// 同上，片單。`resolvedTitle` 也留本機的——那是這台的解析快取，不在目錄裡。
    public static func apply(
        _ catalog: [SourceCatalog.Playlist], to local: [PlaylistSource],
        keepingExtras: Bool = false
    ) -> [PlaylistSource] {
        let byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let merged = catalog.map { entry in
            PlaylistSource(
                id: entry.id,
                title: entry.title,
                urlString: entry.urlString,
                isEnabled: byID[entry.id]?.isEnabled ?? true,
                resolvedTitle: byID[entry.id]?.resolvedTitle ?? ""
            )
        }
        guard keepingExtras else { return merged }
        let known = Set(catalog.map(\.id))
        return merged + local.filter { !known.contains($0.id) }
    }

    /// 資料夾要加哪些、要移除哪些。
    ///
    /// 比對前先正規化（去掉結尾斜線），不然同一個資料夾的兩種寫法會被判成
    /// 「目錄裡沒有」而被移除，下一拍又加回來——每 15 秒抖一次。
    public static func folderDelta(
        catalog: [String], local: [String], keepingExtras: Bool = false
    ) -> (add: [String], remove: [String]) {
        let wanted = catalog.map(normalized)
        let have = local.map(normalized)
        let wantedSet = Set(wanted)
        let haveSet = Set(have)
        return (
            add: wanted.filter { !haveSet.contains($0) },
            // 回傳本機原本的寫法：呼叫端要拿它去比對自己手上的 URL
            remove: keepingExtras
                ? []
                : zip(local, have).filter { !wantedSet.contains($0.1) }.map(\.0)
        )
    }

    /// 目錄 URL 的 `path(percentEncoded:)` 會帶結尾斜線，兩邊表示法不一致就會
    /// 判成不同的資料夾（FolderIndex 踩過同一個坑）。
    public static func normalized(_ path: String) -> String {
        let standardized = URL(filePath: path, directoryHint: .isDirectory)
            .standardizedFileURL.path(percentEncoded: false)
        return standardized.count > 1 && standardized.hasSuffix("/")
            ? String(standardized.dropLast())
            : standardized
    }
}
