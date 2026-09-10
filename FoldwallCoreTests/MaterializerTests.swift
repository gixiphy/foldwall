import XCTest
@testable import FoldwallCore

final class MaterializerTests: XCTestCase {

    private var root: URL!
    private var cache: URL!

    override func setUpWithError() throws {
        root = URL.temporaryDirectory.appending(path: "foldwall-mat-\(UUID().uuidString)")
        cache = root.appending(path: "smb")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, bytes: Int, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? root!).appending(path: name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    // MARK: - prepare

    func testLocalFileReturnsOriginalURL() async throws {
        let file = try write("local.png", bytes: 16)
        let prepared = try await Materializer(cacheDirectory: cache).prepare(file)
        XCTAssertEqual(prepared, file, "本機檔不必拷貝")
    }

    func testMissingFileThrows() async {
        let missing = root.appending(path: "nope.png")
        do {
            _ = try await Materializer(cacheDirectory: cache).prepare(missing)
            XCTFail("不存在的檔案應該 throw，讓上層標離線換下一張")
        } catch {
            XCTAssertEqual(error as? Materializer.Failure, .unavailable(missing))
        }
    }

    func testNetworkVolumePathIsCached() throws {
        // /Volumes/ 底下的檔案要先拷到本機再合成
        XCTAssertTrue(Materializer.needsLocalCopy(URL(filePath: "/Volumes/NAS/photos/a.jpg")))
        XCTAssertFalse(Materializer.needsLocalCopy(URL(filePath: "/Users/me/Pictures/a.jpg")))
    }

    func testCachePathIsStableAndUnique() {
        let mat = Materializer(cacheDirectory: cache)
        let a = URL(filePath: "/Volumes/NAS/a.jpg")
        let b = URL(filePath: "/Volumes/NAS/b.jpg")

        XCTAssertEqual(mat.cacheURL(for: a), mat.cacheURL(for: a), "同一來源要對到同一份快取")
        XCTAssertNotEqual(mat.cacheURL(for: a), mat.cacheURL(for: b))
        XCTAssertEqual(mat.cacheURL(for: a).pathExtension, "jpg", "保留副檔名，ImageIO 才好認")
    }

    // MARK: - LRU 淘汰

    func testEvictKeepsCacheUnderLimit() throws {
        for index in 0..<5 {
            let url = try write("f\(index).bin", bytes: 1000, in: cache)
            // 存取時間遞增：f0 最舊
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000 + Double(index) * 100)],
                ofItemAtPath: url.path
            )
        }

        try Materializer.evict(directory: cache, limitBytes: 2_500)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: cache.path).sorted()
        let total = try remaining.reduce(0) { sum, name in
            let attrs = try FileManager.default.attributesOfItem(atPath: cache.appending(path: name).path)
            return sum + (attrs[.size] as? Int ?? 0)
        }

        XCTAssertLessThanOrEqual(total, 2_500, "淘汰後總量要低於上限")
        XCTAssertFalse(remaining.contains("f0.bin"), "先砍最舊的")
        XCTAssertTrue(remaining.contains("f4.bin"), "最新的要留著")
    }

    func testEvictUnderLimitDoesNothing() throws {
        _ = try write("small.bin", bytes: 100, in: cache)
        try Materializer.evict(directory: cache, limitBytes: 1_000)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), ["small.bin"])
    }

    /// 正在播的那支被砍掉的話：AVPlayer 抓著句柄所以畫面不會馬上壞，
    /// 但下一輪排片找不到它就換片，而磁碟空間在句柄關掉前根本沒釋放。
    func testEvictNeverRemovesAFileInUse() throws {
        var urls: [URL] = []
        for index in 0..<5 {
            let url = try write("f\(index).bin", bytes: 1000, in: cache)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000 + Double(index) * 100)],
                ofItemAtPath: url.path
            )
            urls.append(url)
        }

        // f0 是最舊的，本來第一個被砍——但它正在播。
        try Materializer.evict(directory: cache, limitBytes: 2_500, protecting: [urls[0]])

        let remaining = try FileManager.default.contentsOfDirectory(atPath: cache.path).sorted()
        XCTAssertTrue(remaining.contains("f0.bin"), "正在播的不可以被砍，再舊都一樣")
        XCTAssertFalse(remaining.contains("f1.bin"), "改砍次舊的那個")
    }

    /// 全部都在用的時候砍不動——**那是對的**。桌布用量超標不該拿正在播的去換。
    func testEvictStopsRatherThanRemovingProtectedFiles() throws {
        var urls: [URL] = []
        for index in 0..<3 {
            urls.append(try write("f\(index).bin", bytes: 1000, in: cache))
        }

        let removed = try Materializer.evict(
            directory: cache, limitBytes: 500, protecting: Set(urls))

        XCTAssertEqual(removed, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path).count, 3)
    }

    /// 保護的檔案仍然算進總量——它們確實佔著空間，不能因為砍不到就當成不存在。
    func testProtectedFilesStillCountTowardTheLimit() throws {
        let pinned = try write("pinned.bin", bytes: 3000, in: cache)
        _ = try write("spare.bin", bytes: 100, in: cache)

        let removed = try Materializer.evict(
            directory: cache, limitBytes: 2_500, protecting: [pinned])

        XCTAssertEqual(removed, 1, "總量已經超標，該砍的還是要砍")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: cache.path)
            .contains("spare.bin"))
    }

    func testProtectedFilesBoxRoundTrips() {
        let box = ProtectedFiles()
        XCTAssertTrue(box.current.isEmpty)
        box.update([URL(filePath: "/tmp/a.mp4")])
        XCTAssertEqual(box.current, [URL(filePath: "/tmp/a.mp4")])
        box.update([])
        XCTAssertTrue(box.current.isEmpty)
    }

    func testDefaultLimitIsTwoGigabytes() {
        XCTAssertEqual(Materializer.defaultCacheLimitBytes, 2 * 1024 * 1024 * 1024)
    }
}
