import XCTest
import CoreGraphics
@testable import FoldwallCore

/// 系統圖片桌布 extension 的快取清理：只清自己寫過的解析度、留兩代、剛落地的不動。
final class WallpaperImageCacheTests: XCTestCase {

    private var root: URL!
    private var cache: WallpaperImageCache!
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private let ultrawide = DisplayTarget(id: 1, uuid: "AAAA", canvas: CGSize(width: 5120, height: 1440))
    private let laptop = DisplayTarget(id: 2, uuid: "BBBB", canvas: CGSize(width: 2880, height: 1800))

    override func setUpWithError() throws {
        root = URL.temporaryDirectory.appending(path: "foldwall-wpcache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cache = WallpaperImageCache(directory: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 照 extension 的命名寫一張假 BMP，修改時間往前推 `age` 秒。
    @discardableResult
    private func writeEntry(
        width: Int, height: Int, age: TimeInterval, bytes: Int = 16, tag: Int = 0
    ) throws -> URL {
        let hash = String(format: "%064x", UInt64(age) &* 31 &+ UInt64(width) &* 7 &+ UInt64(tag))
        let stamp = String(format: "%016x", UInt64(now.timeIntervalSinceReferenceDate - age))
        let url = root.appending(path: "\(hash)-\(width)-\(height)-0-\(stamp).bmp")
        try Data(repeating: 0, count: bytes).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    private func names() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
    }

    // MARK: - 檔名

    func testRecognisesExtensionFileNames() {
        let name = "02d9e856dc3a8e7c1d006707b86dfd7df105f51bbc2d9110fbd7c0308b102c0a-5120-1440-0-41c82986d93e7153.bmp"
        let size = WallpaperImageCache.dimensions(ofName: name)
        XCTAssertEqual(size?.width, 5120)
        XCTAssertEqual(size?.height, 1440)
    }

    func testRejectsAnythingElse() {
        XCTAssertNil(WallpaperImageCache.dimensions(ofName: ".DS_Store"))
        XCTAssertNil(WallpaperImageCache.dimensions(ofName: "AAAA-1789056428.jpg"), "我們自己的 JPEG 命名")
        XCTAssertNil(WallpaperImageCache.dimensions(
            ofName: "02d9e856-5120-1440-0-41c82986d93e7153.bmp"), "hash 長度不對")
        XCTAssertNil(WallpaperImageCache.dimensions(
            ofName: "02d9e856dc3a8e7c1d006707b86dfd7df105f51bbc2d9110fbd7c0308b102c0a-5120-1440-0-41c82986d93e7153.png"),
            "不是 .bmp")
    }

    // MARK: - 清理

    func testKeepsTwoGenerationsPerDisplayAndDeletesTheRest() throws {
        for age in [3600.0, 1800.0, 900.0, 300.0, 120.0] {
            try writeEntry(width: 5120, height: 1440, age: age)
        }
        let outcome = cache.prune(displays: [ultrawide], now: now)

        XCTAssertEqual(outcome.deletedCount, 3)
        XCTAssertEqual(outcome.deletedBytes, 48)
        let left = WallpaperImageCache.entries(in: root).map(\.modified).sorted(by: >)
        XCTAssertEqual(left, [now.addingTimeInterval(-120), now.addingTimeInterval(-300)], "留最新兩張")
    }

    func testOnlyTouchesResolutionsWeWrote() throws {
        for age in [3600.0, 1800.0, 900.0, 300.0] {
            try writeEntry(width: 5120, height: 1440, age: age)
            try writeEntry(width: 2880, height: 1800, age: age)
        }
        // 只寫了超寬那塊（筆電那塊在播影片、被 skip）
        let outcome = cache.prune(displays: [ultrawide], now: now)

        XCTAssertEqual(outcome.deletedCount, 2)
        let laptopLeft = WallpaperImageCache.entries(in: root).filter { $0.width == 2880 }
        XCTAssertEqual(laptopLeft.count, 4, "沒寫過的解析度一張都不動")
    }

    func testTwoDisplaysWithSameResolutionShareOneGroup() throws {
        let twin = DisplayTarget(id: 3, uuid: "CCCC", canvas: ultrawide.canvas)
        for age in [3600.0, 1800.0, 900.0, 600.0, 300.0, 120.0] {
            try writeEntry(width: 5120, height: 1440, age: age)
        }
        let outcome = cache.prune(displays: [ultrawide, twin], now: now)

        XCTAssertEqual(outcome.deletedCount, 2, "兩塊 × 兩代 ＝ 留四張")
        XCTAssertEqual(WallpaperImageCache.entries(in: root).count, 4)
    }

    func testFreshFilesAreLeftAloneEvenWhenOverBudget() throws {
        // 三張都是幾秒前落地的：extension 可能還在寫，一張都不能碰
        for age in [30.0, 20.0, 10.0] {
            try writeEntry(width: 5120, height: 1440, age: age)
        }
        let outcome = cache.prune(displays: [ultrawide], now: now)
        XCTAssertEqual(outcome, WallpaperImageCache.Outcome())
        XCTAssertEqual(try names().count, 3)
    }

    func testIgnoresForeignFilesInTheDirectory() throws {
        let stray = root.appending(path: ".DS_Store")
        try Data([1, 2, 3]).write(to: stray)
        let jpg = root.appending(path: "AAAA-1789056428.jpg")
        try Data([1, 2, 3]).write(to: jpg)
        for age in [3600.0, 1800.0, 900.0] {
            try writeEntry(width: 5120, height: 1440, age: age)
        }
        cache.prune(displays: [ultrawide], now: now)

        let left = try names()
        XCTAssertTrue(left.contains(".DS_Store"))
        XCTAssertTrue(left.contains("AAAA-1789056428.jpg"))
    }

    func testMissingDirectoryIsANoOp() {
        let missing = WallpaperImageCache(directory: root.appending(path: "nope"))
        XCTAssertEqual(missing.prune(displays: [ultrawide, laptop], now: now), WallpaperImageCache.Outcome())
        XCTAssertEqual(missing.measure().count, 0)
    }

    func testNoDisplaysMeansNothingIsDeleted() throws {
        for age in [3600.0, 1800.0, 900.0] {
            try writeEntry(width: 5120, height: 1440, age: age)
        }
        XCTAssertEqual(cache.prune(displays: [], now: now), WallpaperImageCache.Outcome())
        XCTAssertEqual(try names().count, 3)
    }

    func testMeasureCountsOnlyExtensionFiles() throws {
        try writeEntry(width: 5120, height: 1440, age: 100, bytes: 100)
        try writeEntry(width: 2880, height: 1800, age: 200, bytes: 50)
        try Data([1]).write(to: root.appending(path: ".DS_Store"))
        let measured = cache.measure()
        XCTAssertEqual(measured.count, 2)
        XCTAssertEqual(measured.bytes, 150)
    }

    func testDefaultDirectoryIsTheWallpaperAgentContainer() {
        let home = URL(filePath: "/Users/someone")
        XCTAssertEqual(
            WallpaperImageCache.defaultDirectory(home: home).path,
            "/Users/someone/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/extension-com.apple.wallpaper.extension.image")
    }
}
