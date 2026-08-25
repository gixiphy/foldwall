import XCTest
@testable import FoldwallCore

final class CacheLocationTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL.temporaryDirectory.appending(path: "foldwall-cache-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func location(_ url: URL) -> CacheLocation {
        CacheLocation(id: "x", name: "n", purpose: "p", url: url, isPurgeable: false)
    }

    /// 路徑要能貼進 Finder 的「前往檔案夾」，家目錄縮成 ~ 比較好讀。
    func testDisplayPathAbbreviatesHome() {
        let inside = location(URL.homeDirectory.appending(path: "Library/Caches/Foldwall/remote"))
        XCTAssertEqual(inside.displayPath, "~/Library/Caches/Foldwall/remote")

        let outside = location(URL(filePath: "/Volumes/Archive/x"))
        XCTAssertEqual(outside.displayPath, "/Volumes/Archive/x")
    }

    func testMissingDirectoryMeasuresAsEmpty() {
        let measured = location(root.appending(path: "nope")).measure()
        XCTAssertEqual(measured.count, 0)
        XCTAssertEqual(measured.bytes, 0)
    }

    func testMeasuresFilesInDirectory() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1000).write(to: root.appending(path: "a.jpg"))
        try Data(repeating: 0, count: 2000).write(to: root.appending(path: "b.jpg"))

        let measured = location(root).measure()
        XCTAssertEqual(measured.count, 2)
        XCTAssertEqual(measured.bytes, 3000)
    }

    /// 影片是 <uuid>/<檔名> 兩層結構，只數第一層會回報 0 位元組。
    func testMeasuresNestedVideoLayout() throws {
        let entry = root.appending(path: "UUID-1")
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 5000).write(to: entry.appending(path: "clip.mp4"))

        let measured = location(root).measure()
        XCTAssertEqual(measured.count, 1, "第一層是一個目錄＝一支影片")
        XCTAssertEqual(measured.bytes, 5000, "大小要往下數一層才算得到")
    }

    /// 只有 Caches 底下的才會被系統清掉；合成輸出放 Application Support 是刻意的。
    func testOnlyCachesAreMarkedPurgeable() {
        let paths = AppPaths.standard()
        let byID = Dictionary(uniqueKeysWithValues: paths.locations.map { ($0.id, $0) })

        XCTAssertEqual(byID["wallpapers"]?.isPurgeable, false)
        XCTAssertEqual(byID["remote"]?.isPurgeable, true)
        XCTAssertEqual(byID["smb"]?.isPurgeable, true)
        for location in paths.locations where location.isPurgeable {
            XCTAssertTrue(location.url.path.contains("/Caches/"), "\(location.id) 標了可清除卻不在 Caches 底下")
        }
    }

    func testEveryLocationHasAUniqueIDAndPath() {
        let locations = AppPaths.standard().locations
        XCTAssertEqual(Set(locations.map(\.id)).count, locations.count)
        XCTAssertEqual(Set(locations.map(\.url)).count, locations.count)
    }
}

extension CacheLocationTests {

    func testClearRemovesContentsButKeepsDirectory() throws {
        let dir = URL.temporaryDirectory.appending(path: "foldwall-clear-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appending(path: "a.jpg"))
        try Data([2]).write(to: dir.appending(path: "b.jpg"))
        defer { try? FileManager.default.removeItem(at: dir) }

        let location = CacheLocation(id: "x", name: "n", purpose: "p", url: dir, isPurgeable: true)
        XCTAssertEqual(try location.clearContents(), 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "目錄本身要留著")
        XCTAssertEqual(location.measure().count, 0)
    }

    func testClearRemovesNestedVideoEntries() throws {
        let dir = URL.temporaryDirectory.appending(path: "foldwall-clearv-\(UUID().uuidString)")
        let entry = dir.appending(path: "UUID-1")
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try Data([1]).write(to: entry.appending(path: "clip.mp4"))
        defer { try? FileManager.default.removeItem(at: dir) }

        let location = CacheLocation(id: "x", name: "n", purpose: "p", url: dir, isPurgeable: false)
        XCTAssertEqual(try location.clearContents(), 1)
        XCTAssertEqual(location.measure().count, 0)
    }

    /// 安全閥：刪除不可逆，路徑不在 Foldwall 自己的目錄底下就一律拒絕。
    func testClearRefusesPathsOutsideAppDirectories() throws {
        let dir = URL.temporaryDirectory.appending(path: "somebody-elses-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appending(path: "precious.jpg"))
        defer { try? FileManager.default.removeItem(at: dir) }

        let location = CacheLocation(id: "x", name: "n", purpose: "p", url: dir, isPurgeable: true)
        XCTAssertThrowsError(try location.clearContents()) { error in
            XCTAssertEqual(error as? CacheLocation.ClearError, .refusedOutsideAppDirectories(dir))
        }
        XCTAssertEqual(location.measure().count, 1, "一個檔案都不能少")
    }

    func testEveryRealLocationPassesTheSafetyGuard() {
        for location in AppPaths.standard().locations {
            XCTAssertTrue(location.url.path.lowercased().contains("foldwall"),
                          "\(location.id) 會被安全閥擋下，使用者按了清除不會有反應")
        }
    }

    func testClearOnMissingDirectoryIsHarmless() throws {
        let missing = URL.temporaryDirectory.appending(path: "foldwall-gone-\(UUID().uuidString)")
        let location = CacheLocation(id: "x", name: "n", purpose: "p", url: missing, isPurgeable: true)
        XCTAssertEqual(try location.clearContents(), 0)
    }
}
