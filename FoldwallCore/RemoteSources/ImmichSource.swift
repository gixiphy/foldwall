//  ImmichSource.swift
//  自架 Immich。用 API key（header `x-api-key`），不需要 OAuth。
//
//  注意：Immich 的 API 會隨版本改。這裡用 `POST /api/search/random`（較新版本），
//  下載走 `GET /api/assets/{id}/original`。伺服器版本太舊會回 404，
//  在設定視窗會顯示為「來源離線」而不是靜默失敗。

import Foundation

public struct ImmichSource: RemotePhotoSource {
    public let kind = RemoteSourceKind.immich
    let key: String
    let server: URLComponents

    public init(key: String, server: String) throws {
        self.key = key
        let trimmed = server.trimmingCharacters(in: .whitespaces)
        // 允許使用者只打 host，補上 scheme
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: normalized),
              components.host?.isEmpty == false else {
            throw RemoteSourceError.badEndpoint(server)
        }
        self.server = components
    }

    private func url(path: String) throws -> URL {
        var components = server
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + path
        components.query = nil
        guard let url = components.url else { throw RemoteSourceError.badEndpoint(server.string ?? "") }
        return url
    }

    public func listRequest(limit: Int) throws -> URLRequest {
        var request = URLRequest(url: try url(path: "/api/search/random"))
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "size": min(max(limit, 1), 100),
            "type": "IMAGE",
            "withExif": false,
        ])
        return request
    }

    private struct Asset: Decodable {
        let id: String
        let originalFileName: String?
        let type: String?
    }

    public func parse(_ data: Data) throws -> [RemoteImage] {
        guard let assets = try? JSONDecoder().decode([Asset].self, from: data) else {
            throw RemoteSourceError.malformedResponse(kind)
        }
        return assets.compactMap { asset in
            guard asset.type == nil || asset.type == "IMAGE",
                  let url = try? url(path: "/api/assets/\(asset.id)/original")
            else { return nil }
            return RemoteImage(id: asset.id, url: url, attribution: "Immich")
        }
    }

    /// 下載也要帶 key，否則 401。
    public func downloadRequest(for image: RemoteImage) -> URLRequest {
        var request = URLRequest(url: image.url)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        return request
    }
}
