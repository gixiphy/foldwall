//  RSSHubSource.swift
//  RSSHub（https://github.com/DIYgod/RSSHub）：幫沒有 RSS 的網站生成 RSS。
//
//  **只接自架 instance。** 官方的 rsshub.app 已明講「僅供測試，不應作為正式來源」，
//  實測匿名請求直接回 403 並附上那段說明，換瀏覽器 UA 則撞上 Cloudflare 挑戰頁。
//  繞過那個是爬蟲行為，在規格的禁碰清單裡——所以這個來源要求使用者填自己的
//  instance 網址，跟 Immich 同一個模式。
//
//  回傳的是一般 RSS，抓圖邏輯與 RSSPhotoSource 共用。

import Foundation

/// 路由的正規化。使用者手上的路由可能長成好幾種樣子：
/// 從 RSSHub 文件複製是 `/pixiv/ranking/day`，從 RSSHub Radar 複製是
/// `rsshub://pixiv/ranking/day`，從瀏覽器網址列複製則是完整網址。
/// 三種都該貼了就能用，而不是要使用者自己去頭去尾。
public struct RSSHubRoute: Sendable, Equatable {

    public var path: String
    public var queryItems: [URLQueryItem]

    public init?(_ input: String) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // rsshub://pixiv/ranking/day —— Radar 的慣例寫法
        if let range = text.range(of: "rsshub://", options: .caseInsensitive) {
            text = String(text[range.upperBound...])
        } else if text.contains("://") {
            // 完整網址：只取 path 之後，instance 由設定決定
            guard let url = URL(string: text) else { return nil }
            text = url.path + (url.query.map { "?\($0)" } ?? "")
        }

        // 路由本身可以帶 query（例如 ?limit=10），要拆開，
        // 否則整串當 path 塞進去時 `?` 會被百分比編碼，RSSHub 收到的是壞路由。
        let parts = text.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var routePath = String(parts[0])
        guard !routePath.isEmpty, routePath != "/" else { return nil }
        if !routePath.hasPrefix("/") { routePath = "/" + routePath }
        // 尾斜線對 RSSHub 沒意義，去掉避免同一路由存成兩種寫法
        if routePath.count > 1, routePath.hasSuffix("/") { routePath.removeLast() }

        self.path = routePath
        self.queryItems = parts.count > 1
            ? URLComponents(string: "?" + parts[1])?.queryItems ?? []
            : []
    }

    /// 存回設定時用的正規形式。
    public var canonical: String {
        guard !queryItems.isEmpty else { return path }
        var components = URLComponents()
        components.queryItems = queryItems
        return path + "?" + (components.percentEncodedQuery ?? "")
    }
}

public struct RSSHubSource: RemotePhotoSource {
    public let kind = RemoteSourceKind.rsshub

    let instance: URL
    let route: RSSHubRoute
    /// RSSHub 的存取控制（`?key=`）。沒設就不帶。
    let key: String?

    /// - Parameters:
    ///   - instance: 自架 instance 的網址，例如 `http://localhost:1200`。
    ///   - route: 路由，例如 `/pixiv/user/12345`。
    public init(instance: String, route: String, key: String? = nil) throws {
        let trimmed = instance.trimmingCharacters(in: .whitespaces)
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized), url.host?.isEmpty == false else {
            throw RemoteSourceError.badEndpoint(instance)
        }
        guard let parsed = RSSHubRoute(route) else {
            // 沒有路由就只是 instance 首頁，那是一份說明文件不是 feed
            throw RemoteSourceError.missingEndpoint(.rsshub)
        }

        self.instance = url
        self.route = parsed
        self.key = key?.isEmpty == false ? key : nil
    }

    public func listRequest(limit: Int) throws -> URLRequest {
        _ = limit   // feed 給多少就是多少，下載端自行取用

        var components = try RemoteSourceHelper.components(instance.absoluteString)
        // instance 可能帶子路徑（反向代理常見），路由接在後面
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + route.path

        var items = (components.queryItems ?? []) + route.queryItems
        if let key { items.append(URLQueryItem(name: "key", value: key)) }
        components.queryItems = items.isEmpty ? nil : items

        var request = URLRequest(url: try RemoteSourceHelper.url(components, kind: kind))
        request.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml",
                         forHTTPHeaderField: "Accept")
        return request
    }

    public func parse(_ data: Data) throws -> [RemoteImage] {
        try RSSImageExtractor.images(from: data, kind: kind, attribution: instance.host)
    }
}
