import XCTest
@testable import FoldwallCore

final class PlaylistSourceTests: XCTestCase {

    // MARK: - 網址

    func testAcceptsHTTPAndHTTPS() {
        XCTAssertNotNil(PlaylistSource.validate("https://example.com/playlist?list=abc"))
        XCTAssertNotNil(PlaylistSource.validate("  http://example.com/c/name  "))
    }

    func testRejectsNonHTTP() {
        for bad in ["", "   ", "not a url", "ftp://example.com/x", "https://"] {
            XCTAssertNil(PlaylistSource.validate(bad), "應擋下：\(bad)")
        }
    }

    func testDisplayTitlePrefersUserNameThenResolvedThenHost() {
        var source = PlaylistSource(urlString: "https://example.com/list?a=1")
        XCTAssertEqual(source.displayTitle, "example.com", "都沒有就用 host")

        source.resolvedTitle = "某某頻道"
        XCTAssertEqual(source.displayTitle, "某某頻道")

        source.title = "我的片單"
        XCTAssertEqual(source.displayTitle, "我的片單", "使用者填的優先")
    }

    // MARK: - 只問清單、不下載

    /// `--flat-playlist` 是關鍵：少了它，yt-dlp 會逐支去抓完整 metadata，
    /// 幾百支的片單要跑很久，而這一步只需要 id 與標題。
    func testListArgumentsOnlyAskForMetadata() {
        let args = VideoDownloadTool.listArguments(url: "https://example.com/list")
        XCTAssertTrue(args.contains("--flat-playlist"))
        XCTAssertTrue(args.contains("--dump-single-json"))
        XCTAssertEqual(args.last, "https://example.com/list")
        XCTAssertFalse(args.contains("-o"), "解析階段不該有輸出路徑——那是下載才需要的")
        XCTAssertFalse(args.contains("-f"), "解析階段不該挑格式")
    }

    // MARK: - 解析輸出

    private let playlist = Data("""
    {"title":"某某片單","entries":[
      {"id":"aaa111","title":"第一支","url":"https://example.com/watch/aaa111"},
      {"id":"bbb222","title":"第二支","url":"https://example.com/watch/bbb222"}
    ]}
    """.utf8)

    func testParsesPlaylist() throws {
        let result = try PlaylistCodec.parse(playlist)
        XCTAssertEqual(result.title, "某某片單")
        XCTAssertEqual(result.entries.map(\.id), ["aaa111", "bbb222"])
        XCTAssertEqual(result.entries[0].urlString, "https://example.com/watch/aaa111")
    }

    /// 使用者貼單支影片的網址也該能用，不必逼他分辨那是不是片單。
    func testSingleVideoIsTreatedAsAOneEntryPlaylist() throws {
        let single = Data("""
        {"id":"solo9","title":"就這一支","webpage_url":"https://example.com/watch/solo9"}
        """.utf8)
        let result = try PlaylistCodec.parse(single)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].id, "solo9")
        XCTAssertEqual(result.entries[0].urlString, "https://example.com/watch/solo9")
        XCTAssertEqual(result.title, "就這一支")
    }

    func testEntriesWithoutIDAreSkipped() throws {
        let messy = Data("""
        {"title":"混的","entries":[
          {"title":"沒有 id"},
          {"id":"","title":"空 id"},
          {"id":"ok1","title":"好的","url":"https://e.com/1"}
        ]}
        """.utf8)
        XCTAssertEqual(try PlaylistCodec.parse(messy).entries.map(\.id), ["ok1"])
    }

    func testEmptyPlaylistIsAnError() {
        let empty = Data(#"{"title":"空的","entries":[]}"#.utf8)
        XCTAssertThrowsError(try PlaylistCodec.parse(empty)) {
            XCTAssertEqual($0 as? PlaylistCodec.Failure, .empty)
        }
    }

    func testGarbageIsAnError() {
        XCTAssertThrowsError(try PlaylistCodec.parse(Data("not json".utf8))) {
            XCTAssertEqual($0 as? PlaylistCodec.Failure, .unreadable)
        }
    }

    // MARK: - 認出已經抓過的

    /// 靠檔名裡的 `[id]` 認。下載的輸出樣板是 `%(title).80B [%(id)s].%(ext)s`，
    /// 所以使用者手動抓的、以前抓的也都認得出來，不必另外記一份帳。
    func testLocalFileIsFoundByIDMarker() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "foldwall-playlist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let wanted = directory.appending(path: "某支影片 [aaa111].mp4")
        try Data("x".utf8).write(to: wanted)
        // 比檔名不比整條 URL：contentsOfDirectory 回的是解析過符號連結的路徑
        // （/var → /private/var），整條比會假失敗。
        try Data("x".utf8).write(to: directory.appending(path: "別支 [zzz999].mp4"))
        try Data("x".utf8).write(to: directory.appending(path: "aaa111.txt"))

        XCTAssertEqual(VideoDownloadTool.localFile(for: "aaa111", in: directory)?.lastPathComponent,
                       wanted.lastPathComponent)
        XCTAssertNil(VideoDownloadTool.localFile(for: "nope", in: directory))
        XCTAssertNil(VideoDownloadTool.localFile(for: "aaa111", in: directory.appending(path: "無")))
    }

    /// 批次版：只列一次目錄就把整份「id → 檔案」的表建好。
    /// 逐支呼叫 localFile 是 O(片單數 × 目錄檔數)，幾百支的片單每輪都要問。
    func testLocalFileMapFindsAllDownloadsInOnePass() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "foldwall-playlist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("x".utf8).write(to: directory.appending(path: "某支影片 [aaa111].mp4"))
        // 標題自己帶方括號也不能認錯：id 是**最後**一組
        try Data("x".utf8).write(to: directory.appending(path: "標題[有括號] [bbb222].webm"))
        try Data("x".utf8).write(to: directory.appending(path: "aaa111.txt"))           // 不是影片
        try Data("x".utf8).write(to: directory.appending(path: "沒有標記.mp4"))          // 沒有 [id]

        let map = VideoDownloadTool.localFileMap(in: directory)
        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map["aaa111"]?.lastPathComponent, "某支影片 [aaa111].mp4")
        XCTAssertEqual(map["bbb222"]?.lastPathComponent, "標題[有括號] [bbb222].webm")
        XCTAssertNil(map["nope"])
        XCTAssertTrue(VideoDownloadTool.localFileMap(in: directory.appending(path: "無")).isEmpty)
    }

    /// 副檔名要是影片。同名的 .txt／.json（yt-dlp 的 sidecar）不算。
    func testNonVideoFilesAreNotMistakenForDownloads() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "foldwall-playlist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("x".utf8).write(to: directory.appending(path: "某支 [aaa111].info.json"))
        XCTAssertNil(VideoDownloadTool.localFile(for: "aaa111", in: directory))
    }
}
