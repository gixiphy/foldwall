import XCTest
@testable import FoldwallCore

final class PlaybackCooldownTests: XCTestCase {

    private let a = URL(string: "https://a.example/1.m3u8")!
    private let b = URL(string: "https://a.example/2.m3u8")!
    private let local = URL(filePath: "/Volumes/Archive/c.mp4")

    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testFailedSourceIsFilteredOut() {
        var cooldown = PlaybackCooldown()
        cooldown.recordFailure(a, now: now)
        XCTAssertEqual(cooldown.filter([a, b, local], now: now), [b, local])
    }

    func testCooldownExpires() {
        var cooldown = PlaybackCooldown()
        cooldown.recordFailure(a, now: now)
        let later = now.addingTimeInterval(PlaybackCooldown.duration + 1)
        XCTAssertFalse(cooldown.isCoolingDown(a, now: later))
        XCTAssertEqual(cooldown.filter([a, b], now: later), [a, b])
    }

    /// 全部都壞掉時寧可播一支會壞的，也不要空池換來的黑畫面。
    func testAllCoolingDownFallsBackToEverything() {
        var cooldown = PlaybackCooldown()
        cooldown.recordFailure(a, now: now)
        cooldown.recordFailure(b, now: now)
        XCTAssertEqual(cooldown.filter([a, b], now: now), [a, b])
    }

    func testClearRemovesTheMark() {
        var cooldown = PlaybackCooldown()
        cooldown.recordFailure(a, now: now)
        cooldown.clear(a)
        XCTAssertFalse(cooldown.isCoolingDown(a, now: now))
    }

    func testEmptyInputStaysEmpty() {
        XCTAssertTrue(PlaybackCooldown().filter([], now: now).isEmpty)
    }
}
