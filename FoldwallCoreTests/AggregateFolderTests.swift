import XCTest
@testable import FoldwallCore

final class AggregateFolderTests: XCTestCase {

    private var root: URL!
    private var destination: URL!
    private let farm = AggregateFolder()

    override func setUpWithError() throws {
        root = URL.temporaryDirectory.appending(path: "foldwall-agg-\(UUID().uuidString)")
        destination = root.appending(path: "aggregate")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func makeSource(_ name: String, files: [String]) throws -> URL {
        let dir = root.appending(path: name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in files {
            try Data(repeating: 7, count: 64).write(to: dir.appending(path: file))
        }
        return dir
    }

    private var linkNames: Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(
            at: destination, includingPropertiesForKeys: nil)) ?? []).map(\.lastPathComponent))
    }

    func testGathersEveryCacheIntoOneFolder() throws {
        let a = try makeSource("remote", files: ["pexels-1.jpg"])
        let b = try makeSource("photos", files: ["photos-2.jpg"])
        let c = try makeSource("smb", files: ["abc123.webp"])

        let outcome = try farm.sync(sources: [a, b, c], into: destination)
        XCTAssertEqual(outcome.linked, 3)
        XCTAssertEqual(linkNames, ["pexels-1.jpg", "photos-2.jpg", "abc123.webp"],
                       "三個快取的圖都要在同一個資料夾裡出現")
    }

    /// 硬連結：同一個磁碟上不佔額外空間，而且連到的是同一份資料。
    func testLinksShareTheSameInode() throws {
        let source = try makeSource("remote", files: ["a.jpg"])
        try farm.sync(sources: [source], into: destination)

        let original = try FileManager.default.attributesOfItem(atPath: source.appending(path: "a.jpg").path)
        let link = try FileManager.default.attributesOfItem(atPath: destination.appending(path: "a.jpg").path)
        XCTAssertEqual(original[.systemFileNumber] as? Int, link[.systemFileNumber] as? Int)
    }

    /// **這條是這個型別存在的理由。** 硬連結會讓 inode 的參照數不歸零，
    /// 快取淘汰刪了原檔也不會釋放空間——所以來源消失時一定要把連結清掉。
    func testPrunesLinksWhoseSourceIsGone() throws {
        let source = try makeSource("remote", files: ["a.jpg", "b.jpg"])
        try farm.sync(sources: [source], into: destination)
        XCTAssertEqual(linkNames.count, 2)

        try FileManager.default.removeItem(at: source.appending(path: "b.jpg"))
        let outcome = try farm.sync(sources: [source], into: destination)

        XCTAssertEqual(outcome.pruned, 1)
        XCTAssertEqual(linkNames, ["a.jpg"], "來源沒了，連結也不能留")
    }

    func testSecondSyncDoesNotRelinkWhatIsAlreadyThere() throws {
        let source = try makeSource("remote", files: ["a.jpg", "b.jpg"])
        try farm.sync(sources: [source], into: destination)

        let outcome = try farm.sync(sources: [source], into: destination)
        XCTAssertEqual(outcome, AggregateFolder.Outcome(linked: 0, pruned: 0, symlinked: 0))
    }

    /// 螢保要的是圖。影片和 sidecar 不該混進去。
    func testOnlyImagesAreLinked() throws {
        let source = try makeSource("mixed", files: ["a.jpg", "clip.mp4", "note.json", "b.HEIC"])
        try farm.sync(sources: [source], into: destination)
        XCTAssertEqual(linkNames, ["a.jpg", "b.HEIC"])
    }

    func testClearingEverySourceEmptiesTheFolder() throws {
        let source = try makeSource("remote", files: ["a.jpg", "b.jpg"])
        try farm.sync(sources: [source], into: destination)

        for file in ["a.jpg", "b.jpg"] {
            try FileManager.default.removeItem(at: source.appending(path: file))
        }
        try farm.sync(sources: [source], into: destination)
        XCTAssertTrue(linkNames.isEmpty, "快取被清空後，彙整資料夾也要跟著空")
    }

    func testMissingSourceDirectoryIsHarmless() throws {
        let outcome = try farm.sync(sources: [root.appending(path: "nope")], into: destination)
        XCTAssertEqual(outcome.linked, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path), "目的地照樣要建出來")
    }

    func testCountIgnoresBrokenLinks() throws {
        let source = try makeSource("remote", files: ["a.jpg"])
        try farm.sync(sources: [source], into: destination)
        XCTAssertEqual(farm.count(in: destination), 1)

        // 手動造一條斷掉的符號連結，模擬跨磁碟退化後原檔消失
        try FileManager.default.createSymbolicLink(
            at: destination.appending(path: "ghost.jpg"),
            withDestinationURL: root.appending(path: "gone.jpg"))
        XCTAssertEqual(farm.count(in: destination), 1, "斷鏈不算數")
    }

    func testAggregateFolderLivesWhereUsersCanFindIt() {
        let paths = AppPaths.standard()
        XCTAssertTrue(paths.aggregateFolder.path.contains("/Pictures/"))
        XCTAssertEqual(Set(paths.aggregateSources),
                       [paths.remoteCache, paths.photosCache, paths.smbCache])
        XCTAssertEqual(paths.locations().first { $0.id == "photos" }?.url, paths.aggregateFolder,
                       "複製路徑要給彙整資料夾，不是其中一個快取")
    }
}
