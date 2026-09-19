import XCTest
@testable import FoldwallCore

final class VideoPrefetcherTests: XCTestCase {

    private static let sample = URL(filePath: "/cloud/a.mp4")
    private static let otherFile = URL(filePath: "/cloud/mine.mp4")

    private final class Script: @unchecked Sendable {
        var triggers = 0
        var fallbacks = 0
        var evictions: [String] = []
        var throwOnTrigger = false
        var failedEvictions: Set<String> = []
        var triggeredFiles: Set<String> = []
        var readyAfterTrigger = true
        var location: VideoSourceLocation = .cloudDataless

        func probe(_ url: URL) -> VideoSourceLocation {
            if readyAfterTrigger, triggeredFiles.contains(url.path) { return .cloudMaterialized }
            return location
        }

        func trigger(_ url: URL) throws {
            triggers += 1
            triggeredFiles.insert(url.path)
            if throwOnTrigger {
                throw NSError(domain: "test", code: 1)
            }
        }
    }

    private func make(_ script: Script, ledger: URL? = nil,
                      poll: Duration = .milliseconds(5)) -> VideoPrefetcher {
        VideoPrefetcher(
            ledgerURL: ledger,
            probe: { script.probe($0) },
            trigger: { try script.trigger($0) },
            fallback: { _ in script.fallbacks += 1 },
            evict: {
                script.evictions.append($0.path)
                if script.failedEvictions.contains($0.path) {
                    throw NSError(domain: "test.eviction", code: 1)
                }
            },
            pollInterval: poll)
    }

    func testConcurrentFetchesShareOneTrigger() async {
        let script = Script()
        let prefetcher = make(script)
        async let first = prefetcher.fetch(Self.sample)
        async let second = prefetcher.fetch(Self.sample)
        let results = await (first, second)
        XCTAssertTrue(results.0)
        XCTAssertTrue(results.1)
        XCTAssertEqual(script.triggers, 1, "同一支不該抓兩次")
        let marked = await prefetcher.isFetchedByUs(Self.sample)
        XCTAssertTrue(marked)
    }

    func testAlreadyMaterializedIsNotChargedToUs() async {
        let script = Script()
        script.location = .cloudMaterialized
        script.readyAfterTrigger = false
        let prefetcher = make(script)
        let ok = await prefetcher.fetch(Self.sample)
        XCTAssertTrue(ok)
        XCTAssertEqual(script.triggers, 0, "已經在本機就不必再觸發")
        let marked = await prefetcher.isFetchedByUs(Self.sample)
        XCTAssertFalse(marked, "不是我們抓的，釋放時不能動")
    }

    func testTriggerFailureFallsBackToARead() async {
        let script = Script()
        script.throwOnTrigger = true
        let prefetcher = make(script)
        let ok = await prefetcher.fetch(Self.sample)
        XCTAssertTrue(ok)
        XCTAssertEqual(script.fallbacks, 1)
        let marked = await prefetcher.isFetchedByUs(Self.sample)
        XCTAssertTrue(marked)
    }

    func testCancelDoesNotMarkTheLedger() async {
        let script = Script()
        script.readyAfterTrigger = false
        script.location = .cloudDataless
        let prefetcher = make(script, poll: .milliseconds(50))
        let task = Task { await prefetcher.fetch(Self.sample) }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let ok = await task.value
        XCTAssertFalse(ok)
        let marked = await prefetcher.isFetchedByUs(Self.sample)
        XCTAssertFalse(marked)
    }

    func testReleaseIgnoresFilesWeDidNotFetch() async {
        let script = Script()
        let prefetcher = make(script)
        _ = await prefetcher.fetch(Self.otherFile)
        let outsider = await prefetcher.release(Self.sample)
        XCTAssertFalse(outsider)
        XCTAssertTrue(script.evictions.isEmpty, "帳外的檔連 evict 都不該呼叫")

        let own = await prefetcher.release(Self.otherFile)
        XCTAssertTrue(own)
        XCTAssertEqual(script.evictions, [Self.otherFile.path])

        let again = await prefetcher.release(Self.otherFile)
        XCTAssertFalse(again, "放掉一次就從帳上消失")
    }

    func testFailedReleaseKeepsOwnershipAcrossRestartForRetry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "foldwall-prefetch-\(UUID().uuidString)")
        let ledger = directory.appending(path: "video-prefetched.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = Script()
        script.failedEvictions = [Self.sample.path]
        let prefetcher = make(script, ledger: ledger)
        _ = await prefetcher.fetch(Self.sample)

        let released = await prefetcher.release(Self.sample)
        XCTAssertFalse(released, "釋放失敗不能回報成功")
        let retained = await prefetcher.isFetchedByUs(Self.sample)
        XCTAssertTrue(retained)

        let restarted = make(Script(), ledger: ledger)
        let retried = await restarted.release(Self.sample)
        XCTAssertTrue(retried, "失敗的檔重開後仍能重試")
        let remaining = await restarted.isFetchedByUs(Self.sample)
        XCTAssertFalse(remaining)
    }

    func testReleaseAllRetainsFailedAndProtectedFiles() async {
        let script = Script()
        let prefetcher = make(script)
        _ = await prefetcher.fetch(Self.sample)
        _ = await prefetcher.fetch(Self.otherFile)
        script.failedEvictions = [Self.sample.path]

        await prefetcher.releaseAll(keeping: [Self.otherFile])
        let failedRetained = await prefetcher.isFetchedByUs(Self.sample)
        let protectedRetained = await prefetcher.isFetchedByUs(Self.otherFile)
        XCTAssertTrue(failedRetained)
        XCTAssertTrue(protectedRetained)
        XCTAssertEqual(script.evictions, [Self.sample.path])

        script.failedEvictions = []
        await prefetcher.releaseAll(keeping: [Self.otherFile])
        let released = await prefetcher.isFetchedByUs(Self.sample)
        XCTAssertFalse(released)
        XCTAssertEqual(script.evictions, [Self.sample.path, Self.sample.path])
    }

    func testLedgerSurvivesANewPrefetcher() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "foldwall-prefetch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger = directory.appending(path: "video-prefetched.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = Script()
        let first = make(script, ledger: ledger)
        _ = await first.fetch(Self.sample)
        let second = make(Script(), ledger: ledger)
        let marked = await second.isFetchedByUs(Self.sample)
        XCTAssertTrue(marked, "重開 app 之後釋放設定仍只動自己抓的")
    }
}
