//  StockPhotoSources.swift
//  只用 API key 的圖庫來源。全部不需要 OAuth。

import Foundation

// MARK: - Unsplash

public struct UnsplashSource: RemotePhotoSource {
    public let kind = RemoteSourceKind.unsplash
    let key: String
    let query: String

    public func listRequest(limit: Int) throws -> URLRequest {
        var components = try RemoteSourceHelper.components("https://api.unsplash.com/photos/random")
        var items = [
            URLQueryItem(name: "count", value: String(min(max(limit, 1), 30))),
            URLQueryItem(name: "orientation", value: "landscape"),
        ]
        if !query.isEmpty { items.append(URLQueryItem(name: "query", value: query)) }
        components.queryItems = items

        var request = URLRequest(url: try RemoteSourceHelper.url(components, kind: kind))
        request.setValue("Client-ID \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("v1", forHTTPHeaderField: "Accept-Version")
        return request
    }

    private struct Photo: Decodable {
        struct URLs: Decodable { let full: String; let regular: String }
        struct Links: Decodable { let download_location: String? }
        struct UserLinks: Decodable { let html: String? }
        struct User: Decodable { let name: String?; let username: String?; let links: UserLinks? }
        let id: String
        let urls: URLs
        let user: User?
        let links: Links?
    }

    /// 連回 Unsplash 的網址都要帶 utm，這是 API 規範明文要求的。
    static func referral(_ raw: String) -> URL? {
        guard var components = URLComponents(string: raw) else { return nil }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "utm_source", value: "Foldwall"),
            URLQueryItem(name: "utm_medium", value: "referral"),
        ]
        return components.url
    }

    public func parse(_ data: Data) throws -> [RemoteImage] {
        // 帶 query 時回傳的是單一物件，不帶時是陣列
        let photos: [Photo]
        if let many = try? JSONDecoder().decode([Photo].self, from: data) {
            photos = many
        } else if let one = try? JSONDecoder().decode(Photo.self, from: data) {
            photos = [one]
        } else {
            throw RemoteSourceError.malformedResponse(kind)
        }

        return photos.compactMap { photo in
            guard let url = URL(string: photo.urls.full) ?? URL(string: photo.urls.regular)
            else { return nil }
            // 規範要求的寫法是「Photo by <作者> on Unsplash」
            let credit = photo.user?.name.map { "Photo by \($0) on Unsplash" }
            let profile = photo.user?.links?.html.flatMap(Self.referral)
                ?? photo.user?.username.flatMap { Self.referral("https://unsplash.com/@\($0)") }
            var image = RemoteImage(id: photo.id, url: url,
                                    attribution: credit, profileURL: profile)
            // download_location 原樣帶著，觸發時要加上 Client-ID
            image.downloadTrigger = photo.links?.download_location.flatMap(URL.init(string:))
            return image
        }
    }

    /// 下載完回報一次。**這是拿 production 額度的硬性要求**：
    /// Unsplash 靠它統計作者被使用的次數。
    public func downloadTriggerRequest(for image: RemoteImage) -> URLRequest? {
        guard let trigger = image.downloadTrigger else { return nil }
        var request = URLRequest(url: trigger)
        request.setValue("Client-ID \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("v1", forHTTPHeaderField: "Accept-Version")
        return request
    }
}

// MARK: - Pexels

public struct PexelsSource: RemotePhotoSource {
    public let kind = RemoteSourceKind.pexels
    let key: String
    let query: String

    public func listRequest(limit: Int) throws -> URLRequest {
        let path = query.isEmpty ? "https://api.pexels.com/v1/curated"
                                 : "https://api.pexels.com/v1/search"
        var components = try RemoteSourceHelper.components(path)
        var items = [
            URLQueryItem(name: "per_page", value: String(min(max(limit, 1), 80))),
            URLQueryItem(name: "orientation", value: "landscape"),
        ]
        if !query.isEmpty { items.append(URLQueryItem(name: "query", value: query)) }
        components.queryItems = items

        var request = URLRequest(url: try RemoteSourceHelper.url(components, kind: kind))
        request.setValue(key, forHTTPHeaderField: "Authorization")
        return request
    }

    private struct Response: Decodable {
        struct Photo: Decodable {
            struct Source: Decodable { let original: String; let large2x: String? }
            let id: Int
            let src: Source
            let photographer: String?
        }
        let photos: [Photo]
    }

    public func parse(_ data: Data) throws -> [RemoteImage] {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw RemoteSourceError.malformedResponse(kind)
        }
        return response.photos.compactMap { photo in
            guard let url = URL(string: photo.src.original) else { return nil }
            return RemoteImage(id: String(photo.id), url: url,
                               attribution: photo.photographer.map { "Photo by \($0) on Pexels" })
        }
    }
}

// MARK: - Pixabay

public struct PixabaySource: RemotePhotoSource {
    public let kind = RemoteSourceKind.pixabay
    let key: String
    let query: String

    public func listRequest(limit: Int) throws -> URLRequest {
        var components = try RemoteSourceHelper.components("https://pixabay.com/api/")
        var items = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "image_type", value: "photo"),
            URLQueryItem(name: "orientation", value: "horizontal"),
            URLQueryItem(name: "safesearch", value: "true"),
            // per_page 合法範圍 3...200
            URLQueryItem(name: "per_page", value: String(min(max(limit, 3), 200))),
        ]
        if !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        components.queryItems = items
        return URLRequest(url: try RemoteSourceHelper.url(components, kind: kind))
    }

    private struct Response: Decodable {
        struct Hit: Decodable {
            let id: Int
            let largeImageURL: String?
            let fullHDURL: String?
            let user: String?
        }
        let hits: [Hit]
    }

    public func parse(_ data: Data) throws -> [RemoteImage] {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw RemoteSourceError.malformedResponse(kind)
        }
        return response.hits.compactMap { hit in
            guard let string = hit.fullHDURL ?? hit.largeImageURL,
                  let url = URL(string: string) else { return nil }
            return RemoteImage(id: String(hit.id), url: url,
                               attribution: hit.user.map { "\($0) / Pixabay" })
        }
    }
}

// MARK: - Wallhaven（公開內容免 key）

public struct WallhavenSource: RemotePhotoSource {
    public let kind = RemoteSourceKind.wallhaven
    let key: String?
    let query: String

    public func listRequest(limit: Int) throws -> URLRequest {
        var components = try RemoteSourceHelper.components("https://wallhaven.cc/api/v1/search")
        var items = [
            URLQueryItem(name: "sorting", value: "random"),
            // categories/purity 皆為 general + SFW
            URLQueryItem(name: "categories", value: "100"),
            URLQueryItem(name: "purity", value: "100"),
            URLQueryItem(name: "atleast", value: "1920x1080"),
        ]
        if !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let key, !key.isEmpty { items.append(URLQueryItem(name: "apikey", value: key)) }
        components.queryItems = items
        _ = limit   // API 一頁固定 24 筆，下載端自行取用需要的數量
        return URLRequest(url: try RemoteSourceHelper.url(components, kind: kind))
    }

    private struct Response: Decodable {
        struct Wallpaper: Decodable { let id: String; let path: String }
        let data: [Wallpaper]
    }

    public func parse(_ data: Data) throws -> [RemoteImage] {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw RemoteSourceError.malformedResponse(kind)
        }
        return response.data.compactMap { wallpaper in
            guard let url = URL(string: wallpaper.path) else { return nil }
            return RemoteImage(id: wallpaper.id, url: url, attribution: "Wallhaven")
        }
    }
}

// MARK: - Flickr（只做公開搜尋；私人相簿要 OAuth，不做）

public struct FlickrSource: RemotePhotoSource {
    public let kind = RemoteSourceKind.flickr
    let key: String
    let query: String

    public func listRequest(limit: Int) throws -> URLRequest {
        var components = try RemoteSourceHelper.components("https://api.flickr.com/services/rest/")
        components.queryItems = [
            URLQueryItem(name: "method", value: "flickr.photos.search"),
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "text", value: query.isEmpty ? "landscape" : query),
            URLQueryItem(name: "sort", value: "interestingness-desc"),
            URLQueryItem(name: "safe_search", value: "1"),
            URLQueryItem(name: "content_type", value: "1"),
            URLQueryItem(name: "extras", value: "url_l,url_o,owner_name"),
            URLQueryItem(name: "per_page", value: String(min(max(limit, 1), 100))),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "nojsoncallback", value: "1"),
        ]
        return URLRequest(url: try RemoteSourceHelper.url(components, kind: kind))
    }

    private struct Response: Decodable {
        struct Container: Decodable {
            struct Photo: Decodable {
                let id: String
                let url_l: String?
                let url_o: String?
                let ownername: String?
            }
            let photo: [Photo]
        }
        let photos: Container
    }

    public func parse(_ data: Data) throws -> [RemoteImage] {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw RemoteSourceError.malformedResponse(kind)
        }
        return response.photos.photo.compactMap { photo in
            guard let string = photo.url_o ?? photo.url_l, let url = URL(string: string)
            else { return nil }
            return RemoteImage(id: photo.id, url: url,
                               attribution: photo.ownername.map { "\($0) / Flickr" })
        }
    }
}
