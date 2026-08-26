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
}
