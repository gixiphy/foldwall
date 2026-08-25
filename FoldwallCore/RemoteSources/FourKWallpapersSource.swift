//  FourKWallpapersSource.swift
//  4kwallpapers.com。**沒有 API**，是抓公開網頁。
//
//  robots.txt（2026-08-25 查）：`Allow: /`，但明確
//  `Disallow: /search/`、`/recent/`、`/thumbs/`、`/thumbs_2t/`、`/cdn-cgi/`。
//  所以**不做關鍵字搜尋**——`query` 在這個來源是**分類**（anime、cars、nature…），
//  留白就取首頁的混合內容。分類頁與詳細頁都在允許範圍內。
//
//  兩段式：清單頁只有縮圖，原圖網址在詳細頁的 `<a id="resolution">` 裡。
//  第二段由 RemoteFetcher 觸發，而且**只對還沒下載過的**跑，見它的 download。
//
//  解析用正規表示式而不是 HTML parser：要抓的東西形狀很固定，
//  而 Foundation 沒有內建 HTML parser，為了兩個標籤扛一個相依不划算。
//  站方改版就會壞——壞了是整個來源回空清單，不會弄壞別的來源。

import Foundation

public struct FourKWallpapersSource: RemotePhotoSource {

    public let kind = RemoteSourceKind.fourKWallpapers

    /// 分類 slug（`anime`、`cars`、`nature`…）。空＝首頁混合。
    let category: String

    public init(category: String) {
        self.category = category
    }

    private static let host = "https://4kwallpapers.com"

    /// 站方會擋掉沒有 UA 的請求，而且明著說自己是誰比假裝成瀏覽器好。
    private static let userAgent = "Foldwall/1.0 (macOS wallpaper app)"

    /// 常見分類，給設定視窗做下拉用。不是白名單——使用者仍可自己打別的。
    public static let categories = [
        "anime", "nature", "cars", "games", "movies", "abstract",
        "black-dark", "minimal", "space", "photography", "girls", "animals",
    ]

    public func listRequest(limit: Int) throws -> URLRequest {
        let slug = category.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            // 只留 slug 允許的字元：使用者可能貼進整條網址或帶空白
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }

        let path = slug.isEmpty ? "/" : "/\(slug)/"
        guard let url = URL(string: Self.host + path) else {
            throw RemoteSourceError.badEndpoint(path)
        }
        _ = limit   // 一頁固定 24 筆，取幾張由下載端決定
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// 清單頁 → 詳細頁網址。`id` 用網址尾巴那組數字，快取檔名靠它，
    /// 所以同一張圖不管從哪個分類看到都只會下載一次。
    ///
    /// 形狀：`https://4kwallpapers.com/<分類>/<slug>-<id>.html`
    private static let detailPattern = try! NSRegularExpression(
        pattern: #"https://4kwallpapers\.com/([a-z0-9\-]+)/([a-z0-9\-]+)-(\d+)\.html"#)

    public func parse(_ data: Data) throws -> [RemoteImage] {
        guard let html = String(data: data, encoding: .utf8) else {
            throw RemoteSourceError.malformedResponse(kind)
        }

        var seen: Set<String> = []
        var images: [RemoteImage] = []
        let range = NSRange(html.startIndex..., in: html)

        for match in Self.detailPattern.matches(in: html, range: range) {
            guard let whole = Range(match.range, in: html),
                  let idRange = Range(match.range(at: 3), in: html)
            else { continue }
            let id = String(html[idRange])
            guard seen.insert(id).inserted, let url = URL(string: String(html[whole]))
            else { continue }
            images.append(RemoteImage(id: id, url: url, attribution: "4kwallpapers.com"))
        }

        guard !images.isEmpty else { throw RemoteSourceError.malformedResponse(kind) }
        return images
    }

    // MARK: - 第二段：詳細頁 → 原圖

    public func detailRequest(for image: RemoteImage) -> URLRequest? {
        var request = URLRequest(url: image.url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// 詳細頁把可下載的解析度列成一串 `<a ... href="/images/wallpapers/<slug>-<W>x<H>-<id>.jpg">`。
    /// `id="resolution"` 那兩條是「4K」與「Original」。
    private static let wallpaperPattern = try! NSRegularExpression(
        pattern: #"/images/wallpapers/[a-z0-9\-]+-(\d+)x(\d+)-\d+\.(jpg|jpeg|png|webp)"#)

    /// **取最大的那張。** 這個站常給到 7680×4320（實測一張 12.6 MB），
    /// 抓小一點確實能省頻寬與快取，但那是拿畫質換空間——不做。
    /// 快取滿了有 Materializer.evict 汰舊，那是它該處理的事。
    public func parseDetail(_ data: Data, for image: RemoteImage) throws -> RemoteImage? {
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        let range = NSRange(html.startIndex..., in: html)

        var best: (path: String, pixels: Int)?
        for match in Self.wallpaperPattern.matches(in: html, range: range) {
            guard let whole = Range(match.range, in: html),
                  let wRange = Range(match.range(at: 1), in: html),
                  let hRange = Range(match.range(at: 2), in: html),
                  let width = Int(html[wRange]), let height = Int(html[hRange])
            else { continue }
            let pixels = width * height
            if best == nil || pixels > best!.pixels {
                best = (String(html[whole]), pixels)
            }
        }

        guard let best, let url = URL(string: Self.host + best.path) else { return nil }
        var resolved = image
        resolved.url = url
        return resolved
    }

    /// 原圖直連不需要 referer（實測 200），但 UA 還是要帶。
    public func downloadRequest(for image: RemoteImage) -> URLRequest {
        var request = URLRequest(url: image.url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }
}
