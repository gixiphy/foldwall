import XCTest
@testable import FoldwallCore

final class VideoSyncPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testFirstSyncAlwaysRuns() {
        XCTAssertTrue(VideoSyncPolicy.shouldSync(lastSync: nil, now: now, force: false))
    }

    func testWithinIntervalIsSkipped() {
        let recent = now.addingTimeInterval(-5 * 60)
        XCTAssertFalse(VideoSyncPolicy.shouldSync(lastSync: recent, now: now, force: false),
                       "桌布 5 分鐘換一次，影片不該跟著重跑")
    }

    func testAfterIntervalRuns() {
        let old = now.addingTimeInterval(-VideoSyncPolicy.minimumInterval - 1)
        XCTAssertTrue(VideoSyncPolicy.shouldSync(lastSync: old, now: now, force: false))
    }

    func testExactlyAtIntervalRuns() {
        let boundary = now.addingTimeInterval(-VideoSyncPolicy.minimumInterval)
        XCTAssertTrue(VideoSyncPolicy.shouldSync(lastSync: boundary, now: now, force: false))
    }

    /// 移除資料夾要立刻把該來源的影片清掉——規格要求，不能等 30 分鐘。
    func testForceBypassesThrottle() {
        let recent = now.addingTimeInterval(-1)
        XCTAssertTrue(VideoSyncPolicy.shouldSync(lastSync: recent, now: now, force: true))
    }

    func testMinimumIntervalIsThirtyMinutes() {
        XCTAssertEqual(VideoSyncPolicy.minimumInterval, 30 * 60)
    }
}
