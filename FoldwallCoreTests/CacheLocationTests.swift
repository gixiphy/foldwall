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

    /// 使用者心裡只有照片與影片兩類，不該被迫理解六個子目錄。
    func testOnlyTwoGroupsAreExposed() {
        let locations = AppPaths.standard().locations()
        XCTAssertEqual(locations.map(\.id), ["photos", "videos"])
    }

    /// 合成輸出是正掛在桌面上的檔案，不是快取——不能出現在可清除的清單裡。
    func testLiveWallpaperIsNotListedAsCache() {
        let paths = AppPaths.standard()
        let everyMember = paths.locations().flatMap(\.members)
        XCTAssertFalse(everyMember.contains(paths.wallpapers))
        for directory in everyMember {
            XCTAssertTrue(directory.path.contains("/Caches/") || directory.path.contains("Containers"),
                          "\(directory.lastPathComponent) 不該被列成可清除的快取")
        }
    }

    /// 照片那組要涵蓋三個來源目錄，清除才會真的清乾淨。
    func testPhotoGroupCoversEverySourceCache() {
        let paths = AppPaths.standard()
        let photos = paths.locations().first { $0.id == "photos" }
        XCTAssertEqual(Set(photos?.members ?? []),
                       [paths.remoteCache, paths.photosCache, paths.smbCache])
        XCTAssertEqual(photos?.url, paths.remoteCache, "複製路徑要給螢保指得到的那一個")
    }

    func testVideoGroupIncludesTheExtensionContainer() {
        let container = URL(filePath: "/tmp/foldwall-container/videos")
        let videos = AppPaths.standard().locations(videoContainer: container)
            .first { $0.id == "videos" }
        XCTAssertEqual(videos?.members.count, 2)
        XCTAssertTrue(videos?.members.contains(container) == true)
    }

    func testEveryLocationHasAUniqueIDAndPath() {
        let locations = AppPaths.standard().locations()
        XCTAssertEqual(Set(locations.map(\.id)).count, locations.count)
        XCTAssertEqual(Set(locations.map(\.url)).count, locations.count)
    }

    /// 一組多目錄時，統計與清除都要跨目錄。
    func testMeasureAndClearSpanEveryMember() throws {
        let root = URL.temporaryDirectory.appending(path: "foldwall-group-\(UUID().uuidString)")
        let a = root.appending(path: "a"), b = root.appending(path: "b")
        for dir in [a, b] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0, count: 100).write(to: dir.appending(path: "f.jpg"))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let group = CacheLocation(id: "g", name: "n", purpose: "p",
                                  url: a, members: [a, b], isPurgeable: true)
        XCTAssertEqual(group.measure().count, 2)
        XCTAssertEqual(group.measure().bytes, 200)
        XCTAssertEqual(try group.clearContents(), 2)
        XCTAssertEqual(group.measure().count, 0)
    }

    /// 整組有一個目錄不合格就整組不做，不留半清空的狀態。
    func testClearRefusesWholeGroupIfAnyMemberIsOutside() throws {
        let ok = URL.temporaryDirectory.appending(path: "foldwall-ok-\(UUID().uuidString)")
        let bad = URL.temporaryDirectory.appending(path: "elsewhere-\(UUID().uuidString)")
        for dir in [ok, bad] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data([1]).write(to: dir.appending(path: "f.jpg"))
        }
        defer { for dir in [ok, bad] { try? FileManager.default.removeItem(at: dir) } }

        let group = CacheLocation(id: "g", name: "n", purpose: "p",
                                  url: ok, members: [ok, bad], isPurgeable: true)
        XCTAssertThrowsError(try group.clearContents())
        XCTAssertEqual(group.measure().count, 2, "一個檔案都不能少")
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
        let container = VideoLibraryPathStub.container
        for location in AppPaths.standard().locations(videoContainer: container) {
            for directory in location.members {
                XCTAssertTrue(directory.path.lowercased().contains("foldwall"),
                              "\(directory.path) 會被安全閥擋下，使用者按了清除不會有反應")
            }
        }
    }

    func testClearOnMissingDirectoryIsHarmless() throws {
        let missing = URL.temporaryDirectory.appending(path: "foldwall-gone-\(UUID().uuidString)")
        let location = CacheLocation(id: "x", name: "n", purpose: "p", url: missing, isPurgeable: true)
        XCTAssertEqual(try location.clearContents(), 0)
    }
}


/// extension container 的實際路徑在 app target，測試這邊用同樣的形狀。
private enum VideoLibraryPathStub {
    static let container = URL.homeDirectory
        .appending(path: "Library/Containers/app.foldwall.extension/Data/Documents/videos")
}
