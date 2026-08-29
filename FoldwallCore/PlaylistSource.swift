//  PlaylistSource.swift
//  片單網址：存一條網址，**先只問裡面有哪些影片，不下載**。
//
//  跟「按一下就抓一支」的差別在時機：片單可能有幾百支，全抓下來是幾十 GB，
//  而桌布一次只播一支。所以這裡分兩段：
//
//  1. **解析**（`listArguments`）：`yt-dlp --flat-playlist --dump-single-json`
//     只讀清單的 metadata，不碰影片本體。幾百支也只是一次請求。
//  2. **下載**：等輪替真的抽到某一支，才去抓那一支（見 PlaylistService）。
//
//  解析與下載都是呼叫使用者自己安裝的 yt-dlp——Foldwall 不實作串流解析，
//  理由見 VideoDownload.swift。

import Foundation

/// 使用者加的一條片單網址。
public struct PlaylistSource: Codable, Sendable, Equatable, Identifiable {

    public var id: UUID
    /// 使用者自訂名稱；留白就用解析回來的片單標題。
    public var title: String
    public var urlString: String
    public var isEnabled: Bool
    /// 上次解析回來的片單標題，只給 UI 顯示。
    public var resolvedTitle: String

    public init(
        id: UUID = UUID(), title: String = "", urlString: String,
        isEnabled: Bool = true, resolvedTitle: String = ""
    ) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.isEnabled = isEnabled
        self.resolvedTitle = resolvedTitle
    }

    /// 合法就回 URL。只收 http(s)——其他 scheme yt-dlp 也處理不了。
    public static func validate(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    public var url: URL? { Self.validate(urlString) }

    public var displayTitle: String {
        if !title.isEmpty { return title }
        if !resolvedTitle.isEmpty { return resolvedTitle }
        return url?.host() ?? urlString
    }
}

/// 片單裡的一支。**只有 metadata，沒有檔案。**
public struct PlaylistEntry: Codable, Sendable, Equatable, Identifiable {

    /// yt-dlp 給的 id。下載後的檔名會帶著它（`… [id].mp4`），
    /// 所以之後靠它就能認出「這支抓過了」。
    public var id: String
    public var title: String
    /// 餵回 yt-dlp 下載用的網址。
    public var urlString: String

    public init(id: String, title: String, urlString: String) {
        self.id = id
        self.title = title
        self.urlString = urlString
    }
}

public enum PlaylistCodec {

    public enum Failure: Error, Equatable {
        case unreadable
        /// 解析得出來但一支都沒有——多半是網址指到的不是片單。
        case empty
        /// yt-dlp 說裡面有幾支，卻一支也沒吐出來。
        ///
        /// **這不是空片單。** yt-dlp 自認成功（exit 0），只是 extractor
        /// 追不上網站改版——多半是它自己太舊。2026 年中 YouTube 把片單頁
        /// 換成 lockup view model，舊版就是這個症狀：`playlist_count` 有數字、
        /// `entries` 全空，stderr 留一行 WARNING。分開這個 case 才講得出
        /// 「去更新 yt-dlp」，而不是把使用者往「片單是不是空的」帶偏。
        case nothingExtracted(expected: Int)
    }

    /// 解析 `yt-dlp --flat-playlist --dump-single-json` 的輸出。
    ///
    /// 單一影片的網址不會有 `entries`，那時整個物件本身就是那一支——
    /// 使用者貼單支影片的網址也該能用，不必逼他分辨那是不是片單。
    public static func parse(_ data: Data) throws -> (title: String, entries: [PlaylistEntry]) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unreadable
        }
        let title = (root["title"] as? String) ?? ""

        guard let rawEntries = root["entries"] as? [[String: Any]] else {
            guard let single = entry(from: root) else { throw Failure.empty }
            return (title.isEmpty ? single.title : title, [single])
        }

        let entries = rawEntries.compactMap(entry(from:))
        guard !entries.isEmpty else {
            // yt-dlp 自己數過有幾支，卻一支也沒給——那就不是空片單，是它解不動。
            let expected = (root["playlist_count"] as? Int) ?? 0
            throw expected > 0 ? Failure.nothingExtracted(expected: expected) : Failure.empty
        }
        return (title, entries)
    }

    private static func entry(from object: [String: Any]) -> PlaylistEntry? {
        guard let id = object["id"] as? String, !id.isEmpty else { return nil }
        // flat-playlist 給的是 `url`；單支影片給的是 `webpage_url`。
        // 都沒有就用 id 當網址——某些 extractor 只給得出 id。
        let url = (object["url"] as? String)
            ?? (object["webpage_url"] as? String)
            ?? id
        let title = (object["title"] as? String) ?? id
        return PlaylistEntry(id: id, title: title, urlString: url)
    }
}

extension VideoDownloadTool {

    /// 只問片單內容，**不下載**。
    ///
    /// `--flat-playlist` 是關鍵：少了它，yt-dlp 會逐支去抓完整 metadata，
    /// 一個幾百支的片單要跑很久，而我們這一步只需要 id 與標題。
    ///
    /// **不加 `--no-warnings`。** yt-dlp 解不動一個片單時常常還是 exit 0，
    /// 唯一的線索就是 stderr 那行 WARNING；關掉它等於把診斷丟了，
    /// 上層只能報一句「這個網址裡沒有可用的影片」，方向剛好相反。
    /// stderr 另外接著，不會混進 stdout 的 JSON。
    public static func listArguments(url: String) -> [String] {
        [
            "--flat-playlist",
            "--dump-single-json",
            "--ignore-config",
            url,
        ]
    }

    /// 這支抓過了嗎。
    ///
    /// 認檔名裡的 `[id]`——`arguments(url:destination:)` 的輸出樣板是
    /// `%(title).80B [%(id)s].%(ext)s`，所以已下載的檔一定帶著它。
    /// 這樣使用者手動抓的、以前抓的，也都認得出來，不必另外記一份帳。
    public static func localFile(for entryID: String, in directory: URL) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        let marker = "[\(entryID)]"
        return entries.first {
            videoExtensions.contains($0.pathExtension.lowercased())
                && $0.lastPathComponent.contains(marker)
        }
    }

    /// 一次把目錄裡「entry id → 已下載檔案」的對照表建好。
    ///
    /// **逐支呼叫 `localFile` 是 O(片單數 × 目錄檔數)**：每次都重列整個目錄。
    /// 幾百支的片單在每輪 refresh、每次影片播畢都要問一遍，那是幾十萬次系統呼叫。
    /// 這裡只列一次，之後查表。id 取檔名最後一組 `[…]`——輸出樣板
    /// `%(title).80B [%(id)s].%(ext)s` 保證它在結尾。
    public static func localFileMap(in directory: URL) -> [String: URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        var map: [String: URL] = [:]
        for file in entries where videoExtensions.contains(file.pathExtension.lowercased()) {
            let stem = file.deletingPathExtension().lastPathComponent
            guard stem.hasSuffix("]"), let open = stem.lastIndex(of: "[") else { continue }
            let id = String(stem[stem.index(after: open)..<stem.index(before: stem.endIndex)])
            if !id.isEmpty { map[id] = file }
        }
        return map
    }

    /// 下載後可能是哪些副檔名。
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv"]
}
