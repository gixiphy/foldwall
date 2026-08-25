//  RemoteSource.swift
//  免 OAuth 的網路來源。全部只用 API key 或完全免驗證——需要 OAuth 的來源
//  （SmugMug、Flickr 私人相簿）刻意不做，見設計文件的「不做」清單。
//
//  刻意把「建請求」和「解回應」拆開：測試才能餵 fixture，不必碰網路。

import Foundation

public enum RemoteSourceKind: String, Codable, CaseIterable, Sendable {
    case unsplash, pexels, pixabay, wallhaven, flickr, immich, rss, pexelsVideo
    case fourKWallpapers

    public var displayName: String {
        switch self {
        case .unsplash: "Unsplash"
        case .pexels: "Pexels"
        case .pixabay: "Pixabay"
        case .wallhaven: "Wallhaven"
        case .flickr: "Flickr（公開搜尋）"
        case .immich: "Immich"
        case .rss: "RSS 相片來源"
        case .pexelsVideo: "Pexels 影片"
        case .fourKWallpapers: "4KWallpapers"
        }
    }

    /// 需要 API key 才能用。
    public var requiresKey: Bool {
        switch self {
        case .unsplash, .pexels, .pixabay, .flickr, .immich, .pexelsVideo: true
        // Wallhaven 公開內容免 key；RSS 完全免驗證；
        // 4kwallpapers 沒有 API，是抓公開網頁，本來就沒有 key 這回事
        case .wallhaven, .rss, .fourKWallpapers: false
        }
    }

    /// 需要一個網址（Immich 伺服器、RSS feed）。
    public var requiresEndpoint: Bool {
        switch self {
        case .immich, .rss: true
        default: false
        }
    }

    /// 去哪裡申請 key。設定視窗直接做成可點的連結，不要只寫網址叫人自己打。
    public var keyRequestURL: URL? {
        switch self {
        case .unsplash: URL(string: "https://unsplash.com/oauth/applications")
        case .pexels, .pexelsVideo: URL(string: "https://www.pexels.com/api/new/")
        case .pixabay: URL(string: "https://pixabay.com/api/docs/")
        case .flickr: URL(string: "https://www.flickr.com/services/apps/create/apply/")
        case .wallhaven: URL(string: "https://wallhaven.cc/settings/account")
        case .immich: URL(string: "https://immich.app/docs/features/command-line-interface/")
        case .fourKWallpapers: URL(string: "https://4kwallpapers.com/")
        case .rss: nil
        }
    }

    /// 搜尋關鍵字有意義嗎。
    public var supportsQuery: Bool {
        switch self {
        case .unsplash, .pexels, .pixabay, .wallhaven, .flickr, .pexelsVideo: true
        // 4kwallpapers 的 robots.txt **明確 Disallow /search/**，所以不做關鍵字搜尋。
        // 那個欄位在這個來源是「分類」（anime、cars、nature…），留白就取首頁混合。
        case .fourKWallpapers: true
        case .immich, .rss: false
        }
    }

    /// 這個來源送出來的是圖還是片。決定下載到哪個池——影片不進靜態蒙太奇池。
    public var media: MediaKind {
        switch self {
        case .pexelsVideo: .video
        default: .image
        }
    }
}

public struct RemoteImage: Sendable, Equatable, Identifiable {
    public var id: String
    public var url: URL
    /// 有些服務（Unsplash／Pexels／Flickr）的授權要求標註作者。
    /// 會被燒進合成圖的角落，見 MontageComposer。
    public var attribution: String?
    /// 作者頁。標註要「連得回去」，桌布上沒辦法點，但記著才能在別處用。
    public var profileURL: URL?
    /// 下載完要回報的端點（Unsplash 的 `links.download_location`）。
    public var downloadTrigger: URL?

    public init(id: String, url: URL, attribution: String? = nil, profileURL: URL? = nil) {
        self.id = id
        self.url = url
        self.attribution = attribution
        self.profileURL = profileURL
    }
}

public struct RemoteSourceConfig: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: RemoteSourceKind
    public var isEnabled: Bool
    /// 搜尋關鍵字（stock 站）或 Immich／RSS 的網址。API key **不放這裡**，放 Keychain。
    public var query: String
    public var endpoint: String

    public init(
        id: UUID = UUID(), kind: RemoteSourceKind, isEnabled: Bool = true,
        query: String = "", endpoint: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.isEnabled = isEnabled
        self.query = query
        self.endpoint = endpoint
    }
}

extension RemoteSourceConfig {

    /// 逐筆解碼，認不得的 `kind` 直接丟掉。
    ///
    /// **不要直接 decode 整個陣列。** 那樣只要有一筆的 kind 不認得，整份設定就解不開，
    /// 呼叫端的 `?? []` 會讓使用者**所有**網路來源一起消失。移除某個來源型別
    /// （像 0.5.1 拿掉 RSSHub）不該有這種連坐。
    public static func decodeList(_ data: Data) -> [RemoteSourceConfig] {
        struct Lenient: Decodable {
            let value: RemoteSourceConfig?
            init(from decoder: any Decoder) throws {
                value = try? RemoteSourceConfig(from: decoder)
            }
        }
        let decoded = (try? JSONDecoder().decode([Lenient].self, from: data)) ?? []
        return decoded.compactMap(\.value)
    }

    /// 清單上要顯示的標題。
    ///
    /// **不能只用 kind.displayName**：同一個站可以加好幾條、各自不同關鍵字
    /// （例如兩個 Wallhaven，一個搜 Hololive 一個取隨機），只顯示站名就完全分不出來。
    public var displayTitle: String {
        let detail = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty { return "\(kind.displayName)：\(detail)" }

        if kind.requiresEndpoint {
            let host = URL(string: endpoint)?.host()
            if let host { return "\(kind.displayName)：\(host)" }
        }
        // 沒有關鍵字＝取精選／隨機，講清楚比留白好
        return kind.supportsQuery ? "\(kind.displayName)：隨機" : kind.displayName
    }
}

public enum RemoteSourceError: Error, Equatable {
    case missingKey(RemoteSourceKind)
    case missingEndpoint(RemoteSourceKind)
    case badEndpoint(String)
    case malformedResponse(RemoteSourceKind)
    case httpStatus(Int)
}

public protocol RemotePhotoSource: Sendable {
    var kind: RemoteSourceKind { get }
    /// 取候選清單的請求。
    func listRequest(limit: Int) throws -> URLRequest
    /// 把回應解析成可下載的影像清單。
    func parse(_ data: Data) throws -> [RemoteImage]
    /// 下載單張的請求。Immich 需要帶 api key header，所以開放覆寫。
    func downloadRequest(for image: RemoteImage) -> URLRequest

    /// **第二段請求。** 清單頁只給得出詳細頁網址、原圖網址得再進去一層時用
    /// （4kwallpapers 就是這種）。回 nil＝一段就夠，多數 API 走這條。
    ///
    /// 為什麼不直接在來源裡發網路請求：這個協定刻意「只建請求、只解回應」，
    /// 測試才能餵 fixture 不碰網路。多一段也維持同樣的形狀。
    func detailRequest(for image: RemoteImage) -> URLRequest?
    /// 從詳細頁挖出真正的原圖網址。回 nil＝這張放棄。
    func parseDetail(_ data: Data, for image: RemoteImage) throws -> RemoteImage?

    /// 下載完之後要不要回報給來源。
    ///
    /// Unsplash 的 API 規範要求「應用程式實際用到某張照片時」打一次 download 端點
    /// （`photo.links.download_location`）——那是他們統計作者被使用次數的方式，
    /// 不做就拿不到 production 額度。回 nil＝這個來源沒有這種要求。
    func downloadTriggerRequest(for image: RemoteImage) -> URLRequest?
}

extension RemotePhotoSource {
    public func downloadRequest(for image: RemoteImage) -> URLRequest {
        URLRequest(url: image.url)
    }

    public func detailRequest(for image: RemoteImage) -> URLRequest? { nil }
    public func parseDetail(_ data: Data, for image: RemoteImage) throws -> RemoteImage? { image }
    public func downloadTriggerRequest(for image: RemoteImage) -> URLRequest? { nil }
}

public enum RemoteSourceFactory {
    /// - Parameter key: 從 Keychain 取得，沒有就傳 nil。
    public static func make(config: RemoteSourceConfig, key: String?) throws -> any RemotePhotoSource {
        if config.kind.requiresKey, key?.isEmpty != false {
            throw RemoteSourceError.missingKey(config.kind)
        }
        if config.kind.requiresEndpoint, config.endpoint.isEmpty {
            throw RemoteSourceError.missingEndpoint(config.kind)
        }

        switch config.kind {
        case .unsplash: return UnsplashSource(key: key ?? "", query: config.query)
        case .pexels: return PexelsSource(key: key ?? "", query: config.query)
        case .pixabay: return PixabaySource(key: key ?? "", query: config.query)
        case .wallhaven: return WallhavenSource(key: key, query: config.query)
        case .flickr: return FlickrSource(key: key ?? "", query: config.query)
        case .immich: return try ImmichSource(key: key ?? "", server: config.endpoint)
        case .rss: return try RSSPhotoSource(feed: config.endpoint)
        case .pexelsVideo: return PexelsVideoSource(key: key ?? "", query: config.query)
        case .fourKWallpapers: return FourKWallpapersSource(category: config.query)
        }
    }
}

// MARK: - 共用小工具

enum RemoteSourceHelper {
    static func components(_ string: String, path: String? = nil) throws -> URLComponents {
        guard var components = URLComponents(string: string), components.scheme != nil else {
            throw RemoteSourceError.badEndpoint(string)
        }
        if let path {
            components.path = components.path.hasSuffix("/")
                ? String(components.path.dropLast()) + path
                : components.path + path
        }
        return components
    }

    static func url(_ components: URLComponents, kind: RemoteSourceKind) throws -> URL {
        guard let url = components.url else {
            throw RemoteSourceError.badEndpoint(components.string ?? "")
        }
        return url
    }
}
