import XCTest
@testable import FoldwallCore

final class DisplayHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testRollingWindowExpiresEachDisplayIndependently() throws {
        let history = DisplayHistory()
        let policy = DisplayRepeatPolicy(hours: 1, maxDisplays: 2)
        history.record(["a"], now: now)
        XCTAssertFalse(history.excludedKeys(policy: policy, now: now).contains("a"))
        history.record(["a"], now: now.addingTimeInterval(60))
        XCTAssertTrue(history.excludedKeys(policy: policy, now: now.addingTimeInterval(3599)).contains("a"))
        XCTAssertFalse(history.excludedKeys(policy: policy, now: now.addingTimeInterval(3600)).contains("a"))
    }

    func testDisabledLimitAllowsPreviouslyShownMedia() {
        let history = DisplayHistory()
        history.record(["a"], now: now)
        XCTAssertTrue(history.excludedKeys(policy: DisplayRepeatPolicy(), now: now).contains("a"))
        XCTAssertTrue(history.excludedKeys(policy: DisplayRepeatPolicy(isEnabled: false), now: now).isEmpty)
    }

    func testHistorySurvivesReopeningAndMergesWriters() throws {
        let dir = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "history.json")
        let first = DisplayHistory(fileURL: file)
        let second = DisplayHistory(fileURL: file)
        first.record(["a"], now: now)
        second.record(["b"], now: now)
        let reopened = DisplayHistory(fileURL: file)
        XCTAssertEqual(reopened.excludedKeys(policy: DisplayRepeatPolicy(), now: now), ["a", "b"])
    }

    func testOneCompositionCountsEachSourceOnce() {
        let history = DisplayHistory()
        history.record(["a", "a"], now: now)
        XCTAssertTrue(history.excludedKeys(policy: DisplayRepeatPolicy(maxDisplays: 2), now: now).isEmpty)
    }

    func testLargerWindowCanUseEarlierHistory() {
        let history = DisplayHistory()
        history.record(["a"], now: now.addingTimeInterval(-7200))
        XCTAssertTrue(history.excludedKeys(policy: DisplayRepeatPolicy(hours: 1), now: now).isEmpty)
        XCTAssertEqual(history.excludedKeys(policy: DisplayRepeatPolicy(hours: 24), now: now), ["a"])
    }

    func testDecodedSettingsClampInvalidLimits() throws {
        let data = Data(#"{"hours":-1,"maxDisplays":0}"#.utf8)
        let policy = try JSONDecoder().decode(DisplayRepeatPolicy.self, from: data)
        let history = DisplayHistory()
        history.record(["a"], now: now)
        XCTAssertEqual(history.excludedKeys(policy: policy, now: now.addingTimeInterval(3599)), ["a"])
        XCTAssertTrue(history.excludedKeys(policy: policy, now: now.addingTimeInterval(3600)).isEmpty)
    }

    func testConcurrentStoresDoNotLoseSuccessfulDisplays() throws {
        let dir = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "history.json")
        let date = now
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            DisplayHistory(fileURL: file).record(["source-\(index)"], now: date)
        }
        let blocked = DisplayHistory(fileURL: file).excludedKeys(policy: DisplayRepeatPolicy(), now: now)
        XCTAssertEqual(blocked.count, 20)
        XCTAssertTrue(blocked.contains("source-0"))
        XCTAssertTrue(blocked.contains("source-19"))
    }

    func testBlockedSourcesDoNotConsumeImageAttemptBudget() {
        let paths = (0..<100).map { "/photos/\($0).png" }
        var rotation = SourceRotation(pool: SourcePool(groups: [.init(id: "photos", paths: paths)]),
                                      seed: 1, excluding: Set(paths.dropLast()))
        XCTAssertEqual(rotation.next()?.path, "/photos/99.png")
        XCTAssertNil(rotation.next())
    }
}
