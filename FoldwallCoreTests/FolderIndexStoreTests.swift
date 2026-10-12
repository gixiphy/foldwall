import XCTest
@testable import FoldwallCore

final class FolderIndexStoreTests: XCTestCase {

    private var directory: URL!
    private var store: FolderIndexStore!

    override func setUpWithError() throws {
        directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "foldwall-index-\(UUID().uuidString)")
        store = FolderIndexStore(url: directory.appending(path: "folder-index.plist"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sample(scannedAt: Date = Date(timeIntervalSince1970: 1_000_000)) -> PersistedFolderIndex {
        PersistedFolderIndex(
            roots: ["/Volumes/Archive/Tablescape"],
            scannedAt: scannedAt,
            images: ["/Volumes/Archive/Tablescape/a.jpg",
                     "/Volumes/Archive/Tablescape/子目錄/b 有空白.png"],
            videos: ["/Volumes/Archive/Tablescape/clip.mp4"]
        )
    }

    func testRoundTrip() {
        let original = sample()
        store.save(original)
        XCTAssertEqual(store.load(), original)
    }

    /// 目錄不存在也要寫得進去——第一次啟動時 Application Support 底下什麼都還沒有。
    func testSaveCreatesMissingDirectory() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        store.save(sample())
        XCTAssertNotNil(store.load())
    }

    func testLoadReturnsNilWhenFileMissing() {
        XCTAssertNil(store.load())
    }

    /// 半個檔比沒有檔危險：解出殘缺資料會讓上層以為索引是完整的。
    func testCorruptFileIsTreatedAsNoCache() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a plist".utf8)
            .write(to: directory.appending(path: "folder-index.plist"))
        XCTAssertNil(store.load())
    }

    func testFutureVersionIsTreatedAsNoCache() {
        var future = sample()
        future.version = FolderIndexStore.currentVersion + 1
        store.save(future)
        XCTAssertNil(store.load(), "格式對不上就重掃，別硬解出半套資料")
    }

    /// 壓縮是這個檔能不能留在磁碟上的關鍵：69 萬個路徑不壓是 127 MB。
    func testSavedFileIsCompressed() throws {
        let many = (0..<20_000).map { "/Volumes/Archive/Tablescape/#桜桃喵 - 蝴蝶结/\($0).webp" }
        store.save(PersistedFolderIndex(
            roots: ["/Volumes/Archive/Tablescape"],
            scannedAt: Date(timeIntervalSince1970: 1_000_000),
            images: many, videos: []))

        let written = try Data(contentsOf: directory.appending(path: "folder-index.plist")).count
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let uncompressed = try encoder.encode(many).count
        XCTAssertLessThan(written, uncompressed / 4, "路徑共用前綴，zlib 應該壓掉一大截")
    }

    /// 0.5.1 之前寫下的是未壓縮的 plist，換版後仍要讀得出來。
    func testUncompressedLegacyFileStillLoads() throws {
        let original = sample()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(original)
            .write(to: directory.appending(path: "folder-index.plist"))

        XCTAssertEqual(store.load(), original)
    }

    func testClearRemovesFile() {
        store.save(sample())
        store.clear()
        XCTAssertNil(store.load())
    }

    func testTreeRoundTripsThroughDisk() throws {
        let url = URL.temporaryDirectory.appending(path: "index-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        let tree = DirectoryTree(directories: [
            "/r": IndexedDirectory(modified: 123.5, files: [
                IndexedFile(name: "照片.jpg", kind: .image, size: 4_000_000, modified: 99.25),
                IndexedFile(name: "clip.mov", kind: .video, size: -1, modified: 0),
            ], subdirectories: ["a"]),
            "/r/a": IndexedDirectory(modified: DirectoryTree.unknownModified, files: [], subdirectories: []),
        ], rootIsMountPoint: ["/r": true])
        let fullScanAt = Date(timeIntervalSince1970: 1_000)
        let store = FolderIndexStore(url: url)
        store.save(PersistedFolderIndex(roots: ["/r"], scannedAt: .now, images: ["/r/照片.jpg"],
                                        videos: ["/r/clip.mov"], tree: tree, fullScanAt: fullScanAt))

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.version, 2)
        XCTAssertEqual(loaded.tree, tree)
        XCTAssertEqual(loaded.rootIsMountPoint, ["/r": true])
        XCTAssertEqual(loaded.fullScanAt, fullScanAt)
    }

    func testMissingRootIsMountPointKeyStillLoads() throws {
        let url = URL.temporaryDirectory.appending(path: "index-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        // 早期 v2：有 directories、沒有 rootIsMountPoint（也可能還有已廢棄的 rootDevices）
        struct EarlyV2: Codable {
            var version = 2
            var roots: [String]
            var scannedAt: Date
            var images: [String]
            var videos: [String]
            var isComplete: Bool
            var directories: [PersistedDirectory]
            var rootDevices: [String: UInt64]?
        }
        let directories = [
            PersistedDirectory(path: "/r", directory: IndexedDirectory(
                modified: 1, files: [IndexedFile(name: "a.jpg", kind: .image, size: 1, modified: 1)],
                subdirectories: [])),
        ]
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let plist = try encoder.encode(EarlyV2(
            roots: ["/r"], scannedAt: .now, images: ["/r/a.jpg"], videos: [],
            isComplete: true, directories: directories, rootDevices: ["/r": 42]))
        try ((plist as NSData).compressed(using: .zlib) as Data).write(to: url)

        let loaded = try XCTUnwrap(FolderIndexStore(url: url).load())
        XCTAssertEqual(loaded.rootIsMountPoint, [:], "缺鍵當空字典，下一輪掃描再補")
        XCTAssertEqual(loaded.tree?.flattened().images, ["/r/a.jpg"])
    }

    func testVersion1FileStillLoads() throws {
        let url = URL.temporaryDirectory.appending(path: "index-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        // 0.14 寫的檔：version 1、沒有 directories／fullScanAt
        struct V1: Codable {
            var version = 1; var roots: [String]; var scannedAt: Date
            var images: [String]; var videos: [String]; var isComplete: Bool
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let plist = try encoder.encode(V1(roots: ["/r"], scannedAt: .now, images: ["/r/a.jpg"],
                                          videos: [], isComplete: true))
        try ((plist as NSData).compressed(using: .zlib) as Data).write(to: url)

        let loaded = try XCTUnwrap(FolderIndexStore(url: url).load(), "升級不該讓使用者重掃四分鐘")
        XCTAssertEqual(loaded.images, ["/r/a.jpg"])
        XCTAssertNil(loaded.tree, "v1 沒有樹，呼叫端要從平面清單重建")
        XCTAssertNil(loaded.fullScanAt)
    }

    func testCorruptColumnsDropTheTreeButKeepTheLists() throws {
        var index = PersistedFolderIndex(roots: ["/r"], scannedAt: .now, images: ["/r/a.jpg"], videos: [],
                                         tree: DirectoryTree(directories: [
                                             "/r": IndexedDirectory(modified: 1, files: [
                                                 IndexedFile(name: "a.jpg", kind: .image, size: 1, modified: 1),
                                             ], subdirectories: []),
                                         ]))
        index.directories[0].sizes = Data([1, 2, 3])   // 長度不是 8 的倍數
        XCTAssertNil(index.tree)
        XCTAssertEqual(index.images, ["/r/a.jpg"])
    }
}
