import XCTest
@testable import FoldwallCore

/// 全部離線：保留舊版絕對連結與 2026-09-19 實際頁面的相對連結。
/// fixture 鎖住已知格式；網站後續改版仍需實際連線確認。
final class FourKWallpapersSourceTests: XCTestCase {

    private let source = FourKWallpapersSource(category: "")

    // MARK: - 清單頁請求

    func testEmptyCategoryUsesHomepage() throws {
        let request = try source.listRequest(limit: 12)
        XCTAssertEqual(request.url?.absoluteString, "https://4kwallpapers.com/")
    }

    func testCategoryBecomesPathSegment() throws {
        let request = try FourKWallpapersSource(category: "anime").listRequest(limit: 12)
        XCTAssertEqual(request.url?.absoluteString, "https://4kwallpapers.com/anime/")
    }

    /// 使用者可能貼進帶空白或大寫的東西。
    func testCategoryIsSanitised() throws {
        let request = try FourKWallpapersSource(category: " Black Dark ").listRequest(limit: 12)
        XCTAssertEqual(request.url?.absoluteString, "https://4kwallpapers.com/black-dark/")
    }

    /// 站方會擋沒有 UA 的請求，而且明說自己是誰比假裝成瀏覽器好。
    func testRequestsIdentifyThemselves() throws {
        let list = try source.listRequest(limit: 4)
        XCTAssertEqual(list.value(forHTTPHeaderField: "User-Agent"),
                       "Foldwall/1.0 (macOS wallpaper app)")

        let image = RemoteImage(id: "1", url: URL(string: "https://4kwallpapers.com/a/b-1.html")!)
        XCTAssertNotNil(source.detailRequest(for: image)?.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertNotNil(source.downloadRequest(for: image).value(forHTTPHeaderField: "User-Agent"))
    }

    // MARK: - 清單頁解析

    private let listing = Data("""
    <div class="wallpapers__item">
      <a href="https://4kwallpapers.com/movies/spider-man-brand-27093.html">
        <img src="https://4kwallpapers.com/images/walls/thumbs/27093.jpg">
      </a>
      <a href="https://4kwallpapers.com/cars/lamborghini-27048.html">
        <img src="https://4kwallpapers.com/images/walls/thumbs/27048.jpg">
      </a>
      <a href="https://4kwallpapers.com/movies/spider-man-brand-27093.html">重複的連結</a>
      <a href="https://4kwallpapers.com/anime/">分類頁，不是圖</a>
      <a href="/wallpapers-for-iphone/">相對連結，不是圖</a>
    </div>
    """.utf8)

    func testParsesDetailLinksAndDedupes() throws {
        let images = try source.parse(listing)
        XCTAssertEqual(images.map(\.id), ["27093", "27048"], "同一張只算一次，分類頁不算")
        XCTAssertEqual(images[0].url.absoluteString,
                       "https://4kwallpapers.com/movies/spider-man-brand-27093.html")
        XCTAssertEqual(images[0].attribution, "4kwallpapers.com")
    }

    func testParsesRootRelativeDetailLinks() throws {
        let html = Data("""
        <a data-ripples class="wallpapers__canvas_image" href="/abstract/xiaomi-18-fold-27263.html">
          <img src="/images/walls/thumbs/27263.jpg">
        </a>
        <a class="wallpapers__canvas_image" href='/anime/ichigo-kurosaki-27177.html'>Ichigo</a>
        <a href="/anime/">分類</a>
        <a href="/iphone-18-pro-stock-wallpapers/">合集</a>
        """.utf8)

        let images = try source.parse(html)
        XCTAssertEqual(images.map(\.id), ["27263", "27177"])
        XCTAssertEqual(images.map(\.url.absoluteString), [
            "https://4kwallpapers.com/abstract/xiaomi-18-fold-27263.html",
            "https://4kwallpapers.com/anime/ichigo-kurosaki-27177.html",
        ])
        let image = try XCTUnwrap(images.first)
        XCTAssertEqual(source.detailRequest(for: image)?.url?.absoluteString,
                       "https://4kwallpapers.com/abstract/xiaomi-18-fold-27263.html")
        XCTAssertEqual(image.attribution, "4kwallpapers.com")
    }

    func testMixedLinkFormatsDeduplicateByIDInPageOrder() throws {
        let html = Data("""
        <a href="/anime/ichigo-kurosaki-27177.html">相對連結</a>
        <a href="https://4kwallpapers.com/abstract/xiaomi-18-fold-27263.html">另一張</a>
        <a href="https://4kwallpapers.com/anime/ichigo-kurosaki-27177.html">絕對連結</a>
        """.utf8)

        XCTAssertEqual(try source.parse(html).map(\.id), ["27177", "27263"])
    }

    func testExternalDetailPathsAreNotResolvedOntoSite() throws {
        let html = Data("""
        <a href="https://example.com/anime/unrelated-1.html">其他網站</a>
        <a href="//example.com/anime/unrelated-2.html">其他網站</a>
        <a href="/anime/ichigo-kurosaki-27177.html">本站</a>
        """.utf8)

        XCTAssertEqual(try source.parse(html).map(\.id), ["27177"])
    }

    /// 抓網頁最可能的失敗是「頁面變了、什麼都抓不到」。
    /// 那要當成錯誤往上丟，不能安靜回空清單裝作沒事。
    func testUnrecognisedPageIsAnError() {
        XCTAssertThrowsError(try source.parse(Data("<html>改版了</html>".utf8))) { error in
            XCTAssertEqual(error as? RemoteSourceError, .malformedResponse(.fourKWallpapers))
        }
    }

    // MARK: - 詳細頁解析

    private let detail = Data("""
    <a title="Download 4K Wallpaper" href="/images/wallpapers/spider-man-brand-3840x2160-27093.jpg"
       class="current" id="resolution" target="_blank">4K</a>
    <a title="Download Original Wallpaper" href="/images/wallpapers/spider-man-brand-5120x6485-27093.jpg"
       class="current" id="resolution" target="_blank">Original</a>
    <a href="/images/wallpapers/spider-man-brand-1920x1080-27093.jpg">1920x1080</a>
    <a href="/images/wallpapers/spider-man-brand-2560x1440-27093.jpg">2560x1440</a>
    <img src="https://4kwallpapers.com/images/walls/thumbs_2t/27093.jpg">
    """.utf8)

    /// 取最大：不拿畫質換空間。快取滿了由 Materializer.evict 汰舊。
    func testPicksTheLargestResolution() throws {
        let listed = try source.parse(listing)[0]
        let resolved = try XCTUnwrap(source.parseDetail(detail, for: listed))
        XCTAssertEqual(resolved.url.absoluteString,
                       "https://4kwallpapers.com/images/wallpapers/spider-man-brand-5120x6485-27093.jpg")
        XCTAssertEqual(resolved.id, "27093", "id 不變——快取檔名靠它")
    }

    func testDetailWithoutWallpaperLinksYieldsNil() throws {
        let listed = try source.parse(listing)[0]
        XCTAssertNil(try source.parseDetail(Data("<html>改版了</html>".utf8), for: listed))
    }

    /// 縮圖路徑（robots.txt 禁止的那些）不該被誤認成原圖。
    func testThumbnailPathsAreNotTreatedAsWallpapers() throws {
        let listed = try source.parse(listing)[0]
        let onlyThumbs = Data("""
        <img src="https://4kwallpapers.com/images/walls/thumbs/27093.jpg">
        <img src="https://4kwallpapers.com/images/walls/thumbs_2t/27093.jpg">
        """.utf8)
        XCTAssertNil(try source.parseDetail(onlyThumbs, for: listed))
    }

    // MARK: - 型別設定

    func testKindNeedsNoKeyAndNoEndpoint() {
        XCTAssertFalse(RemoteSourceKind.fourKWallpapers.requiresKey, "沒有 API 就沒有 key")
        XCTAssertFalse(RemoteSourceKind.fourKWallpapers.requiresEndpoint)
        XCTAssertEqual(RemoteSourceKind.fourKWallpapers.media, .image)
    }

    func testFactoryBuildsItWithoutAKey() throws {
        let config = RemoteSourceConfig(kind: .fourKWallpapers, query: "anime")
        let made = try RemoteSourceFactory.make(config: config, key: nil)
        XCTAssertEqual(made.kind, .fourKWallpapers)
    }

    /// 一段式來源不該被這次改動影響。
    func testSinglePhaseSourcesHaveNoDetailStep() {
        let image = RemoteImage(id: "x", url: URL(string: "https://example.com/a.jpg")!)
        XCTAssertNil(WallhavenSource(key: nil, query: "").detailRequest(for: image))
    }
}
