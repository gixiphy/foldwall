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

public struct RSSHubSource: RemotePhotoSource {
    public let kind = RemoteSourceKind.rsshub

    let instance: URL
    let route: String
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
        let path = route.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else {
            // 沒有路由就只是 instance 首頁，那是一份說明文件不是 feed
            throw RemoteSourceError.missingEndpoint(.rsshub)
        }

        self.instance = url
        self.route = path.hasPrefix("/") ? path : "/" + path
        self.key = key?.isEmpty == false ? key : nil
    }

    public func listRequest(limit: Int) throws -> URLRequest {
        _ = limit   // feed 給多少就是多少，下載端自行取用

        var components = try RemoteSourceHelper.components(instance.absoluteString)
        // instance 可能帶子路徑（反向代理常見），路由接在後面
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + route
        if let key {
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "key", value: key)]
        }

        var request = URLRequest(url: try RemoteSourceHelper.url(components, kind: kind))
        request.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml",
                         forHTTPHeaderField: "Accept")
        return request
    }

    public func parse(_ data: Data) throws -> [RemoteImage] {
        try RSSImageExtractor.images(from: data, kind: kind, attribution: instance.host)
    }
}
