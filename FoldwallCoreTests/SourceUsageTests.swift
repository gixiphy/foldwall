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
}
