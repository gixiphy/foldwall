import Foundation
import Testing
@testable import FoldwallCore

@Suite("DirectoryChangeMonitor")
struct DirectoryChangeMonitorTests {

    @Test("Real paths reported by FSEvents map back to the logical root")
    func translateMapsRealPathBackToLogicalRoot() {
        let mappings = [DirectoryChangeMonitor.Mapping(real: "/private/var/x", logical: "/var/x")]
        #expect(DirectoryChangeMonitor.translate("/private/var/x/sub/", mappings: mappings) == "/var/x/sub")
        #expect(DirectoryChangeMonitor.translate("/private/var/x", mappings: mappings) == "/var/x")
        #expect(DirectoryChangeMonitor.translate("/private/var/xy", mappings: mappings) == nil,
                "比到路徑分隔為止")
        #expect(DirectoryChangeMonitor.translate("/elsewhere", mappings: mappings) == nil)
    }

    @Test("Writing a file reports a path under the logical root", .timeLimit(.minutes(1)))
    func reportsLogicalPaths() async throws {
        // URL.temporaryDirectory 在 /var/folders（symlink），FSEvents 回的是 /private/var/folders
        let root = URL.temporaryDirectory.appending(path: "fsev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "sub"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logical = DirectoryTree.key(for: root)

        let (stream, continuation) = AsyncStream<[String]>.makeStream()
        let monitor = DirectoryChangeMonitor(roots: [logical], latency: 0.2) { continuation.yield($0) }
        try await Task.sleep(for: .milliseconds(500))
        try Data().write(to: root.appending(path: "sub/a.jpg"))

        var iterator = stream.makeAsyncIterator()
        let paths = await iterator.next() ?? []
        #expect(!paths.isEmpty)
        #expect(paths.allSatisfy { $0 == logical || $0.hasPrefix(logical + "/") })
        withExtendedLifetime(monitor) {}
    }
}
