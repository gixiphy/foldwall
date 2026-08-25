import XCTest
@testable import FoldwallCore

/// 全部離線測：只測「請求怎麼建」與「回應怎麼解」，不碰網路。
final class RemoteSourceTests: XCTestCase {

    private func query(_ request: URLRequest) -> [String: String] {
        guard let url = request.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return [:] }
        return Dictionary(items.compactMap { item in
            item.value.map { (item.name, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Unsplash

    func testUnsplashRequestCarriesClientIDHeader() throws {
        let request = try UnsplashSource(key: "KEY123", query: "mountains").listRequest(limit: 8)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Client-ID KEY123",
                       "key 必須走 header，不能塞在 URL 裡（會進日誌）")
        XCTAssertEqual(query(request)["count"], "8")
        XCTAssertEqual(query(request)["query"], "mountains")
        XCTAssertEqual(query(request)["orientation"], "landscape")
    }

    func testUnsplashClampsCount() throws {
        let request = try UnsplashSource(key: "K", query: "").listRequest(limit: 999)
        XCTAssertEqual(query(request)["count"], "30", "API 上限 30，超過要夾住")
    }

    func testUnsplashParsesArrayAndSingle() throws {
        let source = UnsplashSource(key: "K", query: "")
        let array = Data("""
        [{"id":"a1","urls":{"full":"https://images.unsplash.com/a1","regular":"https://x/r"},
          "user":{"name":"Ann"}}]
        """.utf8)
        let images = try source.parse(array)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0].id, "a1")
        XCTAssertEqual(images[0].url.absoluteString, "https://images.unsplash.com/a1")
        XCTAssertEqual(images[0].attribution, "Ann / Unsplash", "授權要求標註作者")

        // 帶 query 時 API 回傳單一物件而不是陣列
        let single = Data("""
        {"id":"b2","urls":{"full":"https://images.unsplash.com/b2","regular":"https://x/r"},"user":null}
        """.utf8)
        XCTAssertEqual(try source.parse(single).map(\.id), ["b2"])
    }

    func testUnsplashRejectsGarbage() {
        XCTAssertThrowsError(try UnsplashSource(key: "K", query: "").parse(Data("nope".utf8)))
    }

    // MARK: - Pexels

    func testPexelsUsesCuratedWithoutQuery() throws {
        let curated = try PexelsSource(key: "K", query: "").listRequest(limit: 5)
        XCTAssertEqual(curated.url?.path, "/v1/curated")
        let search = try PexelsSource(key: "K", query: "forest").listRequest(limit: 5)
        XCTAssertEqual(search.url?.path, "/v1/search")
        XCTAssertEqual(query(search)["query"], "forest")
        XCTAssertEqual(search.value(forHTTPHeaderField: "Authorization"), "K")
    }

    func testPexelsParse() throws {
        let data = Data("""
        {"photos":[{"id":42,"src":{"original":"https://images.pexels.com/42.jpg","large2x":"https://x"},
                    "photographer":"Bo"}]}
        """.utf8)
        let images = try PexelsSource(key: "K", query: "").parse(data)
        XCTAssertEqual(images.map(\.id), ["42"])
        XCTAssertEqual(images[0].attribution, "Bo / Pexels")
    }

    // MARK: - Pixabay

    func testPixabayClampsPerPageToLegalRange() throws {
        // API 只接受 3...200，傳 1 會直接 400
        XCTAssertEqual(query(try PixabaySource(key: "K", query: "").listRequest(limit: 1))["per_page"], "3")
        XCTAssertEqual(query(try PixabaySource(key: "K", query: "").listRequest(limit: 500))["per_page"], "200")
    }

    func testPixabayPrefersFullHD() throws {
        let data = Data("""
        {"hits":[{"id":7,"largeImageURL":"https://pixabay.com/large.jpg",
                  "fullHDURL":"https://pixabay.com/hd.jpg","user":"Cy"}]}
        """.utf8)
        let images = try PixabaySource(key: "K", query: "").parse(data)
        XCTAssertEqual(images[0].url.absoluteString, "https://pixabay.com/hd.jpg")
    }

    // MARK: - Wallhaven

    func testWallhavenWorksWithoutKeyAndStaysSFW() throws {
        let request = try WallhavenSource(key: nil, query: "").listRequest(limit: 10)
        let items = query(request)
        XCTAssertEqual(items["purity"], "100", "只抓 SFW")
        XCTAssertEqual(items["categories"], "100")
        XCTAssertEqual(items["sorting"], "random")
        XCTAssertNil(items["apikey"], "沒 key 就不要送空的 apikey 參數")
    }

    func testWallhavenParse() throws {
        let data = Data("""
        {"data":[{"id":"abc123","path":"https://w.wallhaven.cc/full/abc.jpg"}]}
        """.utf8)
        XCTAssertEqual(try WallhavenSource(key: nil, query: "").parse(data).map(\.id), ["abc123"])
    }

    // MARK: - Flickr

    func testFlickrIsPublicSearchOnly() throws {
        let request = try FlickrSource(key: "K", query: "").listRequest(limit: 6)
        let items = query(request)
        XCTAssertEqual(items["method"], "flickr.photos.search", "只做公開搜尋，私人相簿要 OAuth")
        XCTAssertEqual(items["safe_search"], "1")
        XCTAssertEqual(items["nojsoncallback"], "1")
        XCTAssertEqual(items["text"], "landscape", "沒給關鍵字時要有預設，否則 API 回空")
    }

    func testFlickrPrefersOriginalOverLarge() throws {
        let data = Data("""
        {"photos":{"photo":[{"id":"9","url_l":"https://l.jpg","url_o":"https://o.jpg","ownername":"Dee"}]}}
        """.utf8)
        let images = try FlickrSource(key: "K", query: "").parse(data)
        XCTAssertEqual(images[0].url.absoluteString, "https://o.jpg")
        XCTAssertEqual(images[0].attribution, "Dee / Flickr")
    }

    // MARK: - Immich

    func testImmichNormalizesServerAndCarriesKey() throws {
        let source = try ImmichSource(key: "SECRET", server: "photos.example.com")
        let request = try source.listRequest(limit: 12)

        XCTAssertEqual(request.url?.absoluteString, "https://photos.example.com/api/search/random",
                       "只打 host 也要能用")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "SECRET")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["size"] as? Int, 12)
        XCTAssertEqual(json["type"] as? String, "IMAGE")
    }

    func testImmichDownloadAlsoCarriesKey() throws {
        let source = try ImmichSource(key: "SECRET", server: "https://p.example.com")
        let images = try source.parse(Data("""
        [{"id":"asset-1","originalFileName":"a.jpg","type":"IMAGE"}]
        """.utf8))

        XCTAssertEqual(images[0].url.absoluteString,
                       "https://p.example.com/api/assets/asset-1/original")
        let request = source.downloadRequest(for: images[0])
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "SECRET",
                       "下載沒帶 key 會 401")
    }

    func testImmichSkipsNonImageAssets() throws {
        let source = try ImmichSource(key: "K", server: "https://p.example.com")
        let images = try source.parse(Data("""
        [{"id":"v1","type":"VIDEO"},{"id":"i1","type":"IMAGE"}]
        """.utf8))
        XCTAssertEqual(images.map(\.id), ["i1"])
    }

    func testImmichRejectsBadServer() {
        XCTAssertThrowsError(try ImmichSource(key: "K", server: ""))
    }

    // MARK: - RSS

    func testRSSFindsMediaContentEnclosureAndInlineImages() throws {
        let feed = """
        <?xml version="1.0"?>
        <rss xmlns:media="http://search.yahoo.com/mrss/"><channel>
          <item>
            <media:content url="https://cdn.example.com/one.jpg" type="image/jpeg"/>
          </item>
          <item>
            <enclosure url="https://cdn.example.com/two.png" type="image/png"/>
          </item>
          <item>
            <description><![CDATA[<p>hi</p><img src="https://cdn.example.com/three.jpg"/>]]></description>
          </item>
          <item>
            <enclosure url="https://cdn.example.com/track.mp3" type="audio/mpeg"/>
          </item>
        </channel></rss>
        """
        let images = try RSSPhotoSource(feed: "https://example.com/feed").parse(Data(feed.utf8))
        let urls = images.map(\.url.absoluteString)

        XCTAssertTrue(urls.contains("https://cdn.example.com/one.jpg"))
        XCTAssertTrue(urls.contains("https://cdn.example.com/two.png"))
        XCTAssertTrue(urls.contains("https://cdn.example.com/three.jpg"), "description 裡的 img 也要抓")
        XCTAssertFalse(urls.contains { $0.hasSuffix(".mp3") }, "非影像的 enclosure 不能收")
    }

    func testRSSDeduplicates() throws {
        let feed = """
        <rss xmlns:media="http://search.yahoo.com/mrss/"><channel>
          <item><media:content url="https://cdn.example.com/dup.jpg" type="image/jpeg"/></item>
          <item><media:content url="https://cdn.example.com/dup.jpg" type="image/jpeg"/></item>
        </channel></rss>
        """
        XCTAssertEqual(try RSSPhotoSource(feed: "https://e.com/f").parse(Data(feed.utf8)).count, 1)
    }

    func testRSSRejectsMalformedXML() throws {
        let source = try RSSPhotoSource(feed: "https://e.com/f")
        XCTAssertThrowsError(try source.parse(Data("<rss><unclosed>".utf8)))
    }

    // MARK: - 工廠與設定

    func testFactoryRejectsMissingCredentials() {
        let needsKey = RemoteSourceConfig(kind: .unsplash)
        XCTAssertThrowsError(try RemoteSourceFactory.make(config: needsKey, key: nil)) { error in
            XCTAssertEqual(error as? RemoteSourceError, .missingKey(.unsplash))
        }
        XCTAssertThrowsError(try RemoteSourceFactory.make(config: needsKey, key: ""))

        let needsEndpoint = RemoteSourceConfig(kind: .immich)
        XCTAssertThrowsError(try RemoteSourceFactory.make(config: needsEndpoint, key: "K")) { error in
            XCTAssertEqual(error as? RemoteSourceError, .missingEndpoint(.immich))
        }
    }

    func testFactoryAllowsKeylessSources() throws {
        XCTAssertNoThrow(try RemoteSourceFactory.make(config: RemoteSourceConfig(kind: .wallhaven), key: nil))
        XCTAssertNoThrow(try RemoteSourceFactory.make(
            config: RemoteSourceConfig(kind: .rss, endpoint: "https://e.com/feed"), key: nil))
    }

    func testKindCapabilitiesAreConsistent() {
        // OAuth 來源刻意不存在
        XCTAssertEqual(Set(RemoteSourceKind.allCases.map(\.rawValue)),
                       ["unsplash", "pexels", "pixabay", "wallhaven", "flickr", "immich", "rss",
                        "pexelsVideo", "rsshub"])
        XCTAssertFalse(RemoteSourceKind.wallhaven.requiresKey)
        XCTAssertFalse(RemoteSourceKind.rss.requiresKey)
        XCTAssertTrue(RemoteSourceKind.immich.requiresEndpoint)
        XCTAssertTrue(RemoteSourceKind.rss.requiresEndpoint)
        XCTAssertFalse(RemoteSourceKind.immich.supportsQuery)
    }

    /// 沒有任何 Google／YouTube 來源：規格第一條。
    /// YouTube 三條路全不通——Data API 是 Google API；官方 IFrame 嵌入要求播放器
    /// 可見不被遮蔽（桌布定義上就違反）；抽串流網址是規避技術保護措施。
    func testNoGoogleBackedSources() {
        for kind in RemoteSourceKind.allCases {
            let name = kind.rawValue.lowercased() + kind.displayName.lowercased()
            XCTAssertFalse(name.contains("google"), "\(kind) 不該存在")
            XCTAssertFalse(name.contains("youtube"), "\(kind) 不該存在")
        }
    }

    // MARK: - Pexels 影片

    func testPexelsVideoUsesPopularWithoutQuery() throws {
        let popular = try PexelsVideoSource(key: "K", query: "").listRequest(limit: 5)
        XCTAssertEqual(popular.url?.path, "/videos/popular")
        XCTAssertEqual(query(popular)["max_duration"], "60", "桌布是短迴圈，不要長片")
        XCTAssertEqual(popular.value(forHTTPHeaderField: "Authorization"), "K")

        let search = try PexelsVideoSource(key: "K", query: "ocean").listRequest(limit: 5)
        XCTAssertEqual(search.url?.path, "/videos/search")
        XCTAssertEqual(query(search)["query"], "ocean")
        XCTAssertEqual(query(search)["orientation"], "landscape")
    }

    func testPexelsVideoPicksLargestMP4WithinBudget() throws {
        let data = Data("""
        {"videos":[{"id":7,"user":{"name":"Ana"},"video_files":[
          {"link":"https://v.pexels.com/4k.mp4","width":3840,"height":2160,"file_type":"video/mp4"},
          {"link":"https://v.pexels.com/hd.mp4","width":1920,"height":1080,"file_type":"video/mp4"},
          {"link":"https://v.pexels.com/sd.mp4","width":640,"height":360,"file_type":"video/mp4"}]}]}
        """.utf8)
        let items = try PexelsVideoSource(key: "K", query: "").parse(data)
        XCTAssertEqual(items.map(\.id), ["7"])
        XCTAssertEqual(items[0].url.lastPathComponent, "hd.mp4",
                       "4K 檔案大好幾倍、縮放後看不出差別，還會撞到單檔上限")
        XCTAssertEqual(items[0].attribution, "Ana / Pexels")
    }

    func testPexelsVideoFallsBackToSmallestWhenAllOversized() throws {
        let data = Data("""
        {"videos":[{"id":8,"user":{"name":"Bo"},"video_files":[
          {"link":"https://v.pexels.com/8k.mp4","width":7680,"height":4320,"file_type":"video/mp4"},
          {"link":"https://v.pexels.com/4k.mp4","width":3840,"height":2160,"file_type":"video/mp4"}]}]}
        """.utf8)
        let items = try PexelsVideoSource(key: "K", query: "").parse(data)
        XCTAssertEqual(items[0].url.lastPathComponent, "4k.mp4", "全都超過預算就挑最小的")
    }

    func testPexelsVideoSkipsNonMP4() throws {
        let data = Data("""
        {"videos":[{"id":9,"user":{"name":"Cy"},"video_files":[
          {"link":"https://v.pexels.com/x.webm","width":1920,"height":1080,"file_type":"video/webm"}]}]}
        """.utf8)
        XCTAssertTrue(try PexelsVideoSource(key: "K", query: "").parse(data).isEmpty)
    }

    /// 實測 /videos/popular 回的前三支全是直式短影音，且該端點不支援 orientation——
    /// 這條擋的就是那個。直式素材當桌布是災難。
    func testPexelsVideoRejectsPortraitClips() throws {
        let data = Data("""
        {"videos":[
          {"id":1,"width":1080,"height":1920,"user":{"name":"A"},"video_files":[
            {"link":"https://v/p.mp4","width":1080,"height":1920,"file_type":"video/mp4"}]},
          {"id":2,"width":1920,"height":1080,"user":{"name":"B"},"video_files":[
            {"link":"https://v/l.mp4","width":1920,"height":1080,"file_type":"video/mp4"}]}]}
        """.utf8)
        let items = try PexelsVideoSource(key: "K", query: "").parse(data)
        XCTAssertEqual(items.map(\.id), ["2"], "只留橫式")
    }

    func testPexelsVideoSkipsPortraitFileVariants() throws {
        let data = Data("""
        {"videos":[{"id":3,"width":1920,"height":1080,"user":{"name":"C"},"video_files":[
          {"link":"https://v/portrait.mp4","width":1080,"height":1920,"file_type":"video/mp4"},
          {"link":"https://v/land.mp4","width":1280,"height":720,"file_type":"video/mp4"}]}]}
        """.utf8)
        let items = try PexelsVideoSource(key: "K", query: "").parse(data)
        XCTAssertEqual(items[0].url.lastPathComponent, "land.mp4")
    }

    func testPexelsVideoIsRoutedToVideoPool() {
        XCTAssertEqual(RemoteSourceKind.pexelsVideo.media, .video)
        XCTAssertEqual(RemoteSourceKind.pexels.media, .image, "同一個站，圖片來源仍走靜態池")
    }

    func testPexelsVideoRejectsMalformedResponse() {
        XCTAssertThrowsError(try PexelsVideoSource(key: "K", query: "").parse(Data("nope".utf8)))
    }

    func testCacheFilenameIsStableAndKeepsExtension() {
        let fetcher = RemoteFetcher(cacheDirectory: URL(filePath: "/tmp/foldwall-remote"))
        let image = RemoteImage(id: "abc", url: URL(filePath: "/x/photo.png"))

        let first = fetcher.cacheURL(for: image, kind: .unsplash)
        XCTAssertEqual(first, fetcher.cacheURL(for: image, kind: .unsplash))
        XCTAssertEqual(first.pathExtension, "png")
        XCTAssertNotEqual(first, fetcher.cacheURL(for: image, kind: .pexels),
                          "不同來源的同 id 不能撞檔名")

        let noExt = RemoteImage(id: "abc", url: URL(string: "https://e.com/download")!)
        XCTAssertEqual(fetcher.cacheURL(for: noExt, kind: .immich).pathExtension, "jpg",
                       "沒副檔名要補一個，ImageIO 才好認")
    }
}

/// 同一個站可以加好幾條、各自不同關鍵字。清單只顯示站名的話完全分不出來。
final class RemoteSourceTitleTests: XCTestCase {

    func testQueryDistinguishesSameKind() {
        let hololive = RemoteSourceConfig(kind: .wallhaven, query: "Hololive")
        let random = RemoteSourceConfig(kind: .wallhaven, query: "")
        XCTAssertEqual(hololive.displayTitle, "Wallhaven：Hololive")
        XCTAssertEqual(random.displayTitle, "Wallhaven：隨機")
        XCTAssertNotEqual(hololive.displayTitle, random.displayTitle)
    }

    func testWhitespaceQueryCountsAsEmpty() {
        XCTAssertEqual(RemoteSourceConfig(kind: .pexels, query: "   ").displayTitle, "Pexels：隨機")
    }

    func testEndpointSourcesShowTheirHost() {
        let feed = RemoteSourceConfig(kind: .rss, endpoint: "https://www.nasa.gov/feeds/iotd-feed/")
        XCTAssertEqual(feed.displayTitle, "RSS 相片來源：www.nasa.gov")
    }

    func testSourceWithoutQuerySupportKeepsPlainName() {
        XCTAssertEqual(RemoteSourceConfig(kind: .rss).displayTitle, "RSS 相片來源")
    }

    func testVideoSourceIsDistinguishableToo() {
        XCTAssertEqual(RemoteSourceConfig(kind: .pexelsVideo, query: "ocean").displayTitle,
                       "Pexels 影片：ocean")
    }
}

/// RSSHub 只接自架 instance：官方 rsshub.app 明講「僅供測試」，
/// 實測匿名請求回 403、換 UA 撞 Cloudflare 挑戰頁，繞過那個在禁碰清單裡。
final class RSSHubSourceTests: XCTestCase {

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testComposesInstanceAndRoute() throws {
        let request = try RSSHubSource(instance: "http://localhost:1200",
                                       route: "/pixiv/user/12345").listRequest(limit: 10)
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:1200/pixiv/user/12345")
    }

    func testRouteWithoutLeadingSlashStillWorks() throws {
        let request = try RSSHubSource(instance: "https://rss.example.com",
                                       route: "bilibili/user/dynamic/1").listRequest(limit: 10)
        XCTAssertEqual(request.url?.path, "/bilibili/user/dynamic/1")
    }

    /// 反向代理常見：instance 掛在子路徑底下。
    func testInstanceWithSubpathKeepsIt() throws {
        let request = try RSSHubSource(instance: "https://example.com/rsshub/",
                                       route: "/pixiv/user/1").listRequest(limit: 10)
        XCTAssertEqual(request.url?.path, "/rsshub/pixiv/user/1")
    }

    func testAccessKeyIsAppended() throws {
        let request = try RSSHubSource(instance: "https://rss.example.com",
                                       route: "/x", key: "secret").listRequest(limit: 10)
        XCTAssertEqual(query(request)["key"], "secret")
    }

    func testNoKeyMeansNoQueryItem() throws {
        let request = try RSSHubSource(instance: "https://rss.example.com",
                                       route: "/x", key: "").listRequest(limit: 10)
        XCTAssertNil(request.url?.query)
    }

    /// 沒有路由就只是 instance 首頁，那是說明文件不是 feed。
    func testEmptyRouteIsRejected() {
        XCTAssertThrowsError(try RSSHubSource(instance: "https://rss.example.com", route: "  "))
    }

    func testBadInstanceIsRejected() {
        XCTAssertThrowsError(try RSSHubSource(instance: "", route: "/x"))
    }

    /// RSSHub 產的是一般 RSS，抓圖邏輯與 RSSPhotoSource 共用。
    func testParsesRSSHubShapedFeed() throws {
        let data = Data(#"""
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel>
          <title>Pixiv User</title>
          <item>
            <title>作品一</title>
            <description><![CDATA[<img src="https://i.pximg.net/a.jpg" referrerpolicy="no-referrer">]]></description>
          </item>
          <item>
            <title>作品二</title>
            <description><![CDATA[<img src="https://i.pximg.net/b.png"><img src="https://i.pximg.net/c.png">]]></description>
          </item>
        </channel></rss>
        """#.utf8)

        let images = try RSSHubSource(instance: "http://localhost:1200", route: "/pixiv/user/1")
            .parse(data)
        XCTAssertEqual(images.map(\.url.lastPathComponent), ["a.jpg", "b.png", "c.png"])
        XCTAssertEqual(images.first?.attribution, "localhost")
    }

    func testKindRoutesToPhotoPool() {
        XCTAssertEqual(RemoteSourceKind.rsshub.media, .image)
        XCTAssertTrue(RemoteSourceKind.rsshub.requiresEndpoint, "要填自架 instance 網址")
        XCTAssertFalse(RemoteSourceKind.rsshub.requiresKey, "key 是自架者自己設的存取控制，可有可無")
        XCTAssertTrue(RemoteSourceKind.rsshub.supportsQuery, "關鍵字欄位放的是路由")
    }

    func testFactoryBuildsItWithoutAKey() throws {
        let config = RemoteSourceConfig(kind: .rsshub, query: "/pixiv/user/1",
                                        endpoint: "http://localhost:1200")
        XCTAssertNoThrow(try RemoteSourceFactory.make(config: config, key: nil))
    }

    func testTitleShowsTheRoute() {
        let config = RemoteSourceConfig(kind: .rsshub, query: "/pixiv/user/12345",
                                        endpoint: "http://localhost:1200")
        XCTAssertEqual(config.displayTitle, "RSSHub（自架）：/pixiv/user/12345")
    }
}
