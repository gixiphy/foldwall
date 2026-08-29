import XCTest
@testable import FoldwallCore

/// 測試用的 in-memory defaults，取代 UserDefaults。
private final class MemoryDefaults: BookmarkDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    func loadBookmarks() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func saveBookmarks(_ bookmarks: [Data]) {
        lock.lock(); defer { lock.unlock() }
        storage = bookmarks
    }
}

final class BookmarkCodecTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL.temporaryDirectory.appending(path: "foldwall-bm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeFolder(_ name: String) throws -> URL {
        let url = tmp.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Codec

    func testBookmarkRoundTrip() throws {
        let folder = try makeFolder("sources")
        let data = try BookmarkCodec.data(for: folder)
        let resolved = try BookmarkCodec.resolve(data)

        XCTAssertEqual(resolved.url.standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertFalse(resolved.isStale)
    }

    func testBookmarkSurvivesRename() throws {
        let folder = try makeFolder("before")
        let data = try BookmarkCodec.data(for: folder)

        let renamed = tmp.appending(path: "after")
        try FileManager.default.moveItem(at: folder, to: renamed)

        let resolved = try BookmarkCodec.resolve(data)
        XCTAssertEqual(resolved.url.standardizedFileURL.path, renamed.standardizedFileURL.path,
                       "普通 bookmark 應跟著改名走")
    }

    // MARK: - FolderStore（Step 1b：移除）

    func testRemoveFolderPersists() throws {
        let a = try makeFolder("a")
        let b = try makeFolder("b")
        let defaults = MemoryDefaults()

        let store = FolderStore(defaults: defaults)
        try store.add(a)
        try store.add(b)
        XCTAssertEqual(store.resolvedFolders().count, 2)

        XCTAssertTrue(try store.remove(a))
        XCTAssertEqual(store.resolvedFolders().map(\.lastPathComponent), ["b"])

        // 重開（用同一份 defaults 新建 store）後仍只剩 b
        let reopened = FolderStore(defaults: defaults)
        XCTAssertEqual(reopened.resolvedFolders().map(\.lastPathComponent), ["b"])
    }

    func testAddIsIdempotent() throws {
        let a = try makeFolder("a")
        let defaults = MemoryDefaults()
        let store = FolderStore(defaults: defaults)

        try store.add(a)
        try store.add(a)
        XCTAssertEqual(store.resolvedFolders().count, 1, "同一資料夾不應重複加入")
    }

    func testDeletedFolderCountsAsOffline() throws {
        let a = try makeFolder("a")
        let b = try makeFolder("b")
        let defaults = MemoryDefaults()
        let store = FolderStore(defaults: defaults)
        try store.add(a)
        try store.add(b)

        try FileManager.default.removeItem(at: b)

        let resolution = store.resolve()
        XCTAssertEqual(resolution.readable.map(\.lastPathComponent), ["a"])
        XCTAssertEqual(resolution.offlineCount, 1, "讀不到的來源算離線，不是消失")
    }

    /// 連 bookmark 都解析不出來時（整顆碟沒掛就是這樣：resolve 會試著掛載，
    /// 掛不上就 throw）仍然要交得出**路徑**。
    ///
    /// 少了它，那個根會從上層拿到的清單裡整個消失，FolderIndex 會當成使用者
    /// 移除了它——把那顆碟的整份索引篩掉並落地，掛回來得再付一次全量重掃。
    func testUnresolvableBookmarkStillReportsItsLastKnownPath() throws {
        let a = try makeFolder("a")
        let defaults = MemoryDefaults()
        let store = FolderStore(defaults: defaults)
        try store.add(a)

        try FileManager.default.removeItem(at: a)

        let resolution = store.resolve()
        XCTAssertTrue(resolution.readable.isEmpty)
        // bookmark 記的是**實體路徑**：TMPDIR 的 `/var/…` 會撈回 `/private/var/…`。
        // 只有 `/private` 底下那幾個系統目錄有這個 symlink，來源住的
        // `/Volumes/…`、`/Users/…` 沒有——所以只在測試裡把它抹平就好。
        XCTAssertEqual(resolution.offline.map(Self.withoutPrivatePrefix),
                       [Self.withoutPrivatePrefix(a)],
                       "路徑要從 bookmark 裡撈回來，不能只回一個計數")
        XCTAssertEqual(resolution.unresolvedCount, 0)
    }

    /// 碟沒掛的來源在設定裡列得出來，就要按得動「移除」。
    /// bookmark 解不開時只認解出來的 URL 的話，這顆按鈕會靜靜地沒反應。
    func testOfflineSourceCanStillBeRemoved() throws {
        let a = try makeFolder("a")
        let b = try makeFolder("b")
        let defaults = MemoryDefaults()
        let store = FolderStore(defaults: defaults)
        try store.add(a)
        try store.add(b)

        try FileManager.default.removeItem(at: b)
        let offline = store.resolve().offline
        XCTAssertEqual(offline.count, 1)

        XCTAssertTrue(try store.remove(offline[0]), "離線的來源要移除得掉")
        let after = store.resolve()
        XCTAssertEqual(after.readable.map(\.lastPathComponent), ["a"])
        XCTAssertEqual(after.offlineCount, 0)
    }

    private static func withoutPrivatePrefix(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
}
