import XCTest
@testable import FoldwallCore

final class SourceUsageTests: XCTestCase {

    private let photos = URL(filePath: "/Volumes/Photos")
    private let clips = URL(filePath: "/Volumes/Clips")
    private var roots: [URL] { [photos, clips] }

    private func file(_ root: URL, _ name: String) -> URL { root.appending(path: name) }

    /// 沒設定過的資料夾兩者都用——加入資料夾當下的直覺就是這樣。
    func testUnconfiguredFolderIsUsedForBoth() {
        let urls = [file(photos, "a.jpg"), file(clips, "b.jpg")]
        XCTAssertEqual(SourceUsageMap.filter(urls, roots: roots, usage: [:], needing: .montage), urls)
        XCTAssertEqual(SourceUsageMap.filter(urls, roots: roots, usage: [:], needing: .video), urls)
    }

    func testMontageOnlyFolderIsExcludedFromVideo() {
        let usage = [photos.path: SourceUsage.montage, clips.path: SourceUsage.video]
        let urls = [file(photos, "a.jpg"), file(clips, "b.mp4")]

        XCTAssertEqual(SourceUsageMap.filter(urls, roots: roots, usage: usage, needing: .montage),
                       [file(photos, "a.jpg")])
        XCTAssertEqual(SourceUsageMap.filter(urls, roots: roots, usage: usage, needing: .video),
                       [file(clips, "b.mp4")])
    }

    func testFolderWithNoUsageAtAllContributesNothing() {
        let usage = [photos.path: SourceUsage(), clips.path: SourceUsage()]
        let urls = [file(photos, "a.jpg"), file(clips, "b.jpg")]
        XCTAssertTrue(SourceUsageMap.filter(urls, roots: roots, usage: usage, needing: .montage).isEmpty)
    }

    /// 路徑邊界：/Volumes/Photos 的設定不該套用到 /Volumes/PhotosArchive。
    func testPrefixDoesNotLeakAcrossFolders() {
        let archive = URL(filePath: "/Volumes/PhotosArchive")
        let usage = [photos.path: SourceUsage.montage, archive.path: SourceUsage.video]
        let urls = [file(photos, "a.jpg"), file(archive, "b.jpg")]

        XCTAssertEqual(
            SourceUsageMap.filter(urls, roots: [photos, archive], usage: usage, needing: .montage),
            [file(photos, "a.jpg")])
    }

    func testRootLookupMatchesTheDeepestFile() {
        let deep = photos.appending(path: "2026/summer/a.jpg")
        XCTAssertEqual(SourceUsageMap.root(of: deep, in: roots), photos)
        XCTAssertNil(SourceUsageMap.root(of: URL(filePath: "/tmp/x.jpg"), in: roots))
    }

    func testUsageSurvivesEncoding() throws {
        let usage: [String: SourceUsage] = [photos.path: .montage, clips.path: .both]
        let data = try JSONEncoder().encode(usage)
        XCTAssertEqual(try JSONDecoder().decode([String: SourceUsage].self, from: data), usage)
    }

    func testBothIsTheUnionOfTheTwo() {
        XCTAssertTrue(SourceUsage.both.contains(.montage))
        XCTAssertTrue(SourceUsage.both.contains(.video))
    }

    // MARK: - RootMatcher

    /// 兩個資料夾用途不同時 filter 的捷徑會失效，於是要逐一比對 68 萬筆。
    /// 這條路必須正確而且不能慢——實測舊版 4.39 秒、新版 0.63 秒。
    func testMatcherAssignsFilesToTheirRoot() {
        let a = URL(filePath: "/Volumes/Archive/Tablescape", directoryHint: .isDirectory)
        let b = URL(filePath: "/Users/me/Box/寫真", directoryHint: .isDirectory)
        let matcher = RootMatcher([a, b])

        XCTAssertEqual(matcher.root(of: URL(filePath: "/Volumes/Archive/Tablescape/x/1.jpg")), a)
        XCTAssertEqual(matcher.root(of: URL(filePath: "/Users/me/Box/寫真/v.mp4")), b)
        XCTAssertNil(matcher.root(of: URL(filePath: "/tmp/other.jpg")))
    }

    /// 根目錄本身也算它自己底下。
    func testMatcherMatchesTheRootItself() {
        let a = URL(filePath: "/Volumes/A", directoryHint: .isDirectory)
        XCTAssertEqual(RootMatcher([a]).root(of: URL(filePath: "/Volumes/A")), a)
    }

    /// `/Volumes/Arch` 不該吃掉 `/Volumes/Archive`。
    func testMatcherRespectsPathBoundary() {
        let arch = URL(filePath: "/Volumes/Arch", directoryHint: .isDirectory)
        let archive = URL(filePath: "/Volumes/Archive", directoryHint: .isDirectory)
        let matcher = RootMatcher([arch, archive])
        XCTAssertEqual(matcher.root(of: URL(filePath: "/Volumes/Archive/x.jpg")), archive)
        XCTAssertEqual(matcher.root(of: URL(filePath: "/Volumes/Arch/x.jpg")), arch)
    }

    /// 根目錄的 URL 帶不帶結尾斜線都要比得中——bookmark 解出來的目錄會帶。
    func testMatcherHandlesTrailingSlashOnRoot() {
        let withSlash = URL(fileURLWithPath: "/Volumes/A/", isDirectory: true)
        XCTAssertNotNil(RootMatcher([withSlash]).root(of: URL(filePath: "/Volumes/A/x.jpg")))
    }

    func testAllowedRootsFiltersByUsage() {
        let montage = URL(filePath: "/m", directoryHint: .isDirectory)
        let video = URL(filePath: "/v", directoryHint: .isDirectory)
        let usage = ["/m": SourceUsage.montage, "/v": SourceUsage.video]

        XCTAssertEqual(SourceUsageMap.allowedRoots([montage, video], usage: usage, needing: .montage),
                       [montage])
        XCTAssertEqual(SourceUsageMap.allowedRoots([montage, video], usage: usage, needing: .video),
                       [video])
    }

    /// 沒設定過的根目錄一律 .both。
    func testUnsetRootDefaultsToBoth() {
        let x = URL(filePath: "/x", directoryHint: .isDirectory)
        XCTAssertEqual(SourceUsageMap.allowedRoots([x], usage: [:], needing: .montage), [x])
        XCTAssertEqual(SourceUsageMap.allowedRoots([x], usage: [:], needing: .video), [x])
    }
}
