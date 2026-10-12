import Foundation
import Testing
@testable import FoldwallCore

/// 實機量測，平常不跑。xcodebuild 只會把 TEST_RUNNER_ 開頭的環境變數傳進測試：
///
///     TEST_RUNNER_FOLDWALL_BENCH_ROOT=/Volumes/photo/相簿 \
///     TEST_RUNNER_FOLDWALL_BENCH_OUT=$HOME/Desktop/foldwall-bench.txt \
///     xcodebuild … test -only-testing:FoldwallCoreTests/ScanBenchmark
///
/// 結果寫檔而不是 print：xcsift 會把測試的 stdout 濾掉。
@Suite("ScanBenchmark",
       .enabled(if: ProcessInfo.processInfo.environment["FOLDWALL_BENCH_ROOT"] != nil))
struct ScanBenchmark {

    @Test func compareScanners() async throws {
        let environment = ProcessInfo.processInfo.environment
        let root = try #require(environment["FOLDWALL_BENCH_ROOT"])
        let output = environment["FOLDWALL_BENCH_OUT"] ?? "/tmp/foldwall-bench.txt"
        let clock = ContinuousClock()
        var lines: [String] = ["root: \(root)", "date: \(Date.now)"]

        // 1. 現行做法的基準
        var start = clock.now
        var count = 0
        if let walker = FileManager.default.enumerator(
            at: URL(filePath: root), includingPropertiesForKeys: [],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            while walker.nextObject() != nil { count += 1 }
        }
        lines.append("enumerator: \(count) entries, \(clock.now - start)")

        // 2. 新掃描器，不同並行寬度的全量
        var tree = DirectoryTree()
        for width in [1, 4, 8, 16, 32] {
            start = clock.now
            let scan = await TreeScanner(width: width).scan(
                previous: DirectoryTree(), roots: [root], scope: nil, relistAll: true)
            let flat = scan.tree.flattened()
            lines.append("""
                full width=\(width): \(scan.listedDirectories) dirs, \
                \(flat.images.count) images, \(flat.videos.count) videos, \(clock.now - start)
                """)
            tree = scan.tree
        }

        // 3. 沒有變動時的增量檢查（日常 15 分鐘那一輪的成本）
        for width in [8, 16, 32] {
            start = clock.now
            let scan = await TreeScanner(width: width).scan(
                previous: tree, roots: [root], scope: nil, relistAll: false)
            lines.append("""
                incremental width=\(width): checked \(scan.checkedDirectories), \
                listed \(scan.listedDirectories), \(clock.now - start)
                """)
        }

        try lines.joined(separator: "\n").appending("\n")
            .write(toFile: output, atomically: true, encoding: .utf8)
    }
}
