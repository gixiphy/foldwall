import Foundation
import Testing
@testable import FoldwallCore

@Suite("BulkDirectoryReader")
struct BulkDirectoryReaderTests {

    private func makeRoot() throws -> URL {
        let root = URL.temporaryDirectory.appending(path: "bulk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "子目錄"),
                                                withIntermediateDirectories: true)
        return root
    }

    @Test("Names, kinds, sizes and mtimes match FileManager")
    func matchesFileManager() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: 1234).write(to: root.appending(path: "照片.jpg"))
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "link.jpg"), withDestinationURL: root.appending(path: "照片.jpg"))

        let entries = try BulkDirectoryReader.read(root.path(percentEncoded: false))
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["照片.jpg", "link.jpg", "子目錄"])
        #expect(byName["照片.jpg"]?.kind == .file)
        #expect(byName["照片.jpg"]?.size == 1234)
        #expect(byName["子目錄"]?.kind == .directory)
        #expect(byName["link.jpg"]?.kind == .symlink)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appending(path: "照片.jpg").path(percentEncoded: false))
        let expected = try #require(attributes[.modificationDate] as? Date).timeIntervalSince1970
        #expect(abs((byName["照片.jpg"]?.modified ?? 0) - expected) < 0.000_01)
    }

    @Test("Finder-hidden flag is reported")
    func hiddenFlag() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var file = root.appending(path: "secret.jpg")
        try Data().write(to: file)
        var values = URLResourceValues()
        values.isHidden = true
        try file.setResourceValues(values)

        let entries = try BulkDirectoryReader.read(root.path(percentEncoded: false))
        #expect(entries.first { $0.name == "secret.jpg" }?.isHidden == true)
        #expect(entries.first { $0.name == "子目錄" }?.isHidden == false)
    }

    @Test("Directories larger than one buffer are read completely")
    func manyEntries() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // 一筆約 80 B＋檔名，256 KB 的緩衝一次裝不下 5000 筆，逼它多呼叫幾次
        for i in 0..<5000 { try Data().write(to: root.appending(path: "img-\(i).jpg")) }
        let entries = try BulkDirectoryReader.read(root.path(percentEncoded: false))
        #expect(entries.count == 5001)
    }

    @Test("Missing directory and plain file report their errno")
    func errors() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "a.jpg")
        try Data().write(to: file)

        #expect(throws: DirectoryReadError.unreadable(errno: ENOENT)) {
            try BulkDirectoryReader.read(root.appending(path: "nope").path(percentEncoded: false))
        }
        #expect(throws: DirectoryReadError.unreadable(errno: ENOTDIR)) {
            try BulkDirectoryReader.read(file.path(percentEncoded: false))
        }
    }

    @Test("modificationTime matches the directory's mtime")
    func directoryStamp() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.path(percentEncoded: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let expected = try #require(attributes[.modificationDate] as? Date).timeIntervalSince1970
        #expect(abs(try BulkDirectoryReader.modificationTime(of: path) - expected) < 0.000_01)
    }
}
