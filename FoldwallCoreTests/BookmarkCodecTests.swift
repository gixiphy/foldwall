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
}
