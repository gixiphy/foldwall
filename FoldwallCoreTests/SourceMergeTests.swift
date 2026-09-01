import XCTest
@testable import FoldwallCore

/// 共用目錄併回本機時，**這台的開關要活下來**。
final class SourceMergeTests: XCTestCase {

    private let keep = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let fresh = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let gone = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    // MARK: - 網路來源

    /// 規則 2：定義以目錄為準，`isEnabled` 留本機的。
    func testKeepsLocalEnabledFlagAndTakesCatalogDefinition() {
        let local = [RemoteSourceConfig(id: keep, kind: .pexels, isEnabled: false, query: "舊關鍵字")]
        let catalog = [SourceCatalog.Remote(id: keep, kind: .pexels, query: "新關鍵字", endpoint: "")]

        let merged = SourceMerge.apply(catalog, to: local)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].query, "新關鍵字", "定義以目錄為準")
        XCTAssertFalse(merged[0].isEnabled, "在這台關掉的來源，別台把它打開不算數")
    }

    /// 規則 1：沒見過的來源預設是開的——跟使用者自己按「新增」當下的直覺一致。
    func testNewCatalogEntryArrivesEnabled() {
        let catalog = [SourceCatalog.Remote(id: fresh, kind: .unsplash, query: "苔", endpoint: "")]
        let merged = SourceMerge.apply(catalog, to: [])
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].isEnabled)
    }

    /// 規則 3：目錄裡沒有就移除。不做減法的話，在一台刪掉的來源永遠清不乾淨。
    func testEntryMissingFromCatalogIsRemoved() {
        let local = [
            RemoteSourceConfig(id: keep, kind: .pexels, query: "a"),
            RemoteSourceConfig(id: gone, kind: .unsplash, query: "b"),
        ]
        let catalog = [SourceCatalog.Remote(id: keep, kind: .pexels, query: "a", endpoint: "")]
        XCTAssertEqual(SourceMerge.apply(catalog, to: local).map(\.id), [keep])
    }

    /// 順序跟著目錄走，三台的清單看起來才會一樣。
    func testOrderFollowsCatalog() {
        let local = [
            RemoteSourceConfig(id: keep, kind: .pexels, query: "a"),
            RemoteSourceConfig(id: fresh, kind: .unsplash, query: "b"),
        ]
        let catalog = [
            SourceCatalog.Remote(id: fresh, kind: .unsplash, query: "b", endpoint: ""),
            SourceCatalog.Remote(id: keep, kind: .pexels, query: "a", endpoint: ""),
        ]
        XCTAssertEqual(SourceMerge.apply(catalog, to: local).map(\.id), [fresh, keep])
    }

    // MARK: - 片單

    /// `resolvedTitle` 是這台的解析快取，不在目錄裡，合併時要留著。
    func testPlaylistKeepsLocalCacheAndFlag() {
        let local = [
            PlaylistSource(
                id: keep, title: "夜景", urlString: "https://example.com/a",
                isEnabled: false, resolvedTitle: "這台解析回來的")
        ]
        let catalog = [
            SourceCatalog.Playlist(id: keep, title: "夜景（改名）", urlString: "https://example.com/a")
        ]

        let merged = SourceMerge.apply(catalog, to: local)

        XCTAssertEqual(merged[0].title, "夜景（改名）")
        XCTAssertFalse(merged[0].isEnabled)
        XCTAssertEqual(merged[0].resolvedTitle, "這台解析回來的")
    }

    func testNewPlaylistArrivesEnabledWithEmptyCache() {
        let catalog = [
            SourceCatalog.Playlist(id: fresh, title: "", urlString: "https://example.com/b")
        ]
        let merged = SourceMerge.apply(catalog, to: [])
        XCTAssertTrue(merged[0].isEnabled)
        XCTAssertEqual(merged[0].resolvedTitle, "")
    }

    // MARK: - 資料夾

    func testFolderDeltaAddsAndRemoves() {
        let delta = SourceMerge.folderDelta(
            catalog: ["/Volumes/A", "/Volumes/B"], local: ["/Volumes/B", "/Volumes/C"])
        XCTAssertEqual(delta.add, ["/Volumes/A"])
        XCTAssertEqual(delta.remove, ["/Volumes/C"])
    }

    /// 結尾斜線不同不該被判成兩個資料夾——那會變成每 15 秒加一次、刪一次。
    func testFolderDeltaIgnoresTrailingSlash() {
        let delta = SourceMerge.folderDelta(
            catalog: ["/Volumes/A/"], local: ["/Volumes/A"])
        XCTAssertTrue(delta.add.isEmpty)
        XCTAssertTrue(delta.remove.isEmpty)
    }

    /// 要移除的回傳本機原本的寫法：呼叫端要拿它去比對自己手上的 URL。
    func testFolderDeltaRemovalKeepsLocalSpelling() {
        let delta = SourceMerge.folderDelta(catalog: [], local: ["/Volumes/C/"])
        XCTAssertEqual(delta.remove, ["/Volumes/C/"])
    }

    func testNormalizedStripsTrailingSlashButKeepsRoot() {
        XCTAssertEqual(SourceMerge.normalized("/Volumes/A/"), "/Volumes/A")
        XCTAssertEqual(SourceMerge.normalized("/"), "/")
    }

    // MARK: - 第一次加入

    /// 打開自動同步的當下，這台手上的來源還沒進過目錄。
    /// 照減法套下去就是把它們清光——第一次要聯集。
    func testJoinKeepsLocalSourcesMissingFromCatalog() {
        let local = [
            RemoteSourceConfig(id: gone, kind: .unsplash, isEnabled: false, query: "只有這台有")
        ]
        let catalog = [SourceCatalog.Remote(id: keep, kind: .pexels, query: "a", endpoint: "")]

        let merged = SourceMerge.apply(catalog, to: local, keepingExtras: true)

        XCTAssertEqual(merged.map(\.id), [keep, gone], "目錄的排前面，這台多出來的接在後面")
        XCTAssertFalse(merged[1].isEnabled, "留下來的要連開關一起留")
    }

    func testJoinKeepsLocalPlaylistsMissingFromCatalog() {
        let local = [PlaylistSource(id: gone, urlString: "https://example.com/only-here")]
        let merged = SourceMerge.apply([], to: local, keepingExtras: true)
        XCTAssertEqual(merged.map(\.id), [gone])
    }

    func testJoinNeverRemovesFolders() {
        let delta = SourceMerge.folderDelta(
            catalog: ["/Volumes/A"], local: ["/Volumes/C"], keepingExtras: true)
        XCTAssertEqual(delta.add, ["/Volumes/A"])
        XCTAssertTrue(delta.remove.isEmpty, "第一次加入不做減法")
    }
}
