//  PexelsVideoSource.swift
//  Pexels Videos：免 OAuth、直接給 mp4 網址的**影片**來源。
//
//  為什麼是 Pexels 而不是 YouTube：YouTube 沒有任何合規途徑。官方 IFrame 嵌入要求
//  播放器可見、不被遮蔽、要顯示廣告——桌布是被所有視窗蓋住的最底層，定義上就違反；
//  抽 googlevideo 串流網址則是規避技術保護措施，而且光是「找片」的 Data API
//  就是 Google API，撞到規格第一條「放棄 Google」。
//
//  Pexels 用同一把 key（跟照片來源共用 Keychain 帳號是分開的，各自一組設定），
//  回應直接帶 mp4 直連網址，授權允許這樣用。

import Foundation

public struct PexelsVideoSource: RemotePhotoSource {
    public let kind = RemoteSourceKind.pexelsVideo
    let key: String
    let query: String

    /// 桌布不需要 4K 素材：檔案大好幾倍，縮放後看不出差別，還會撞到單檔上限。
    /// 挑「不超過這個寬度裡最大的一個」。
    static let preferredMaxWidth = 1920

    /// 桌布迴圈不需要長片。也順便壓住檔案大小。
    static let maxDurationSeconds = 60

    public init(key: String, query: String) {
        self.key = key
        self.query = query
    }

    public func listRequest(limit: Int) throws -> URLRequest {
        let path = query.isEmpty ? "https://api.pexels.com/videos/popular"
                                 : "https://api.pexels.com/videos/search"
        var components = try RemoteSourceHelper.components(path)
        var items = [
            URLQueryItem(name: "per_page", value: String(min(max(limit, 1), 80))),
            // 桌布是短迴圈：長片檔案大又沒必要
            URLQueryItem(name: "max_duration", value: String(Self.maxDurationSeconds)),
        ]
        if query.isEmpty {
            // popular **不支援** orientation（實測 min_width 也擋不掉直式），
            // 所以直式是在 parse 裡用實際尺寸濾掉的。
            items.append(URLQueryItem(name: "min_width", value: "1280"))
        } else {
            items.append(URLQueryItem(name: "query", value: query))
            items.append(URLQueryItem(name: "orientation", value: "landscape"))
        }
        components.queryItems = items

        var request = URLRequest(url: try RemoteSourceHelper.url(components, kind: kind))
        request.setValue(key, forHTTPHeaderField: "Authorization")
        return request
    }

    private struct Response: Decodable {
        struct Video: Decodable {
            struct File: Decodable {
                let link: String
                let width: Int?
                let height: Int?
                let file_type: String?
            }
            struct User: Decodable { let name: String? }
            let id: Int
            let width: Int?
            let height: Int?
            let video_files: [File]
            let user: User?
        }
        let videos: [Video]
    }

    public func parse(_ data: Data) throws -> [RemoteImage] {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw RemoteSourceError.malformedResponse(kind)
        }

        return response.videos.compactMap { video -> RemoteImage? in
            // 直式素材拿來當桌布是災難。實測 /videos/popular 回的前幾支全是直式短影音，
            // 而該端點不支援 orientation 參數——只能在這裡用實際尺寸擋掉。
            guard Self.isLandscape(width: video.width, height: video.height) else { return nil }
            guard let file = Self.bestFile(video.video_files),
                  let url = URL(string: file.link)
            else { return nil }

            let author = video.user?.name.map { "\($0) / Pexels" }
            return RemoteImage(id: String(video.id), url: url, attribution: author)
        }
    }

    /// 尺寸讀不到就放行（不同端點欄位不一定齊），讀得到就要求寬 > 高。
    private static func isLandscape(width: Int?, height: Int?) -> Bool {
        guard let width, let height, height > 0 else { return true }
        return width > height
    }

    /// 只收 mp4 且只收橫式；挑寬度不超過 preferredMaxWidth 裡最大的，全都超過就挑最小的。
    private static func bestFile(_ files: [Response.Video.File]) -> Response.Video.File? {
        let mp4 = files
            .filter { ($0.file_type ?? "").contains("mp4") }
            .filter { isLandscape(width: $0.width, height: $0.height) }
        guard !mp4.isEmpty else { return nil }

        let withinBudget = mp4.filter { ($0.width ?? 0) <= preferredMaxWidth }
        if let best = withinBudget.max(by: { ($0.width ?? 0) < ($1.width ?? 0) }) {
            return best
        }
        return mp4.min(by: { ($0.width ?? .max) < ($1.width ?? .max) })
    }
}
