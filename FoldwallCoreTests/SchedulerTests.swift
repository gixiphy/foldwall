import XCTest
@testable import FoldwallCore

final class SchedulerTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func makeScheduler(minutes: Int = 5) -> Scheduler {
        Scheduler(intervalMinutes: minutes, now: start)
    }

    private func later(_ minutes: Double) -> Date {
        start.addingTimeInterval(minutes * 60)
    }

    // MARK: - 基本排程

    func testTickBeforeDueDoesNothing() {
        var s = makeScheduler()
        XCTAssertEqual(s.handle(.tick(now: later(1))), .none)
    }

    func testTickAtDueRefreshesAndReschedules() {
        var s = makeScheduler()
        XCTAssertEqual(s.handle(.tick(now: later(5))), .refresh)
        XCTAssertEqual(s.nextDue, later(10), "跑完要排下一輪")
        XCTAssertEqual(s.handle(.tick(now: later(6))), .none)
    }

    // MARK: - 暫停語意

    func testPausedTickDoesNothing() {
        var s = makeScheduler()
        _ = s.handle(.pause)
        XCTAssertEqual(s.handle(.tick(now: later(99))), .none, "暫停中排程不得換桌布")
    }

    func testNextWhilePausedIsSingleShotAndStaysPaused() {
        var s = makeScheduler()
        _ = s.handle(.pause)
        XCTAssertEqual(s.handle(.userNext(now: later(1))), .refresh, "暫停中按下一張仍應換一張")
        XCTAssertTrue(s.isPaused, "單發之後仍維持暫停")
        XCTAssertEqual(s.handle(.tick(now: later(99))), .none)
    }

    func testResumeRefreshesImmediately() {
        var s = makeScheduler()
        _ = s.handle(.pause)
        XCTAssertEqual(s.handle(.resume(now: later(3))), .refresh, "恢復要立即刷新一輪")
        XCTAssertFalse(s.isPaused)
        XCTAssertEqual(s.nextDue, later(8), "再回排程")
    }

    func testUserNextResetsCountdown() {
        var s = makeScheduler()
        XCTAssertEqual(s.handle(.userNext(now: later(2))), .refresh)
        XCTAssertEqual(s.nextDue, later(7), "手動換張後重新計時")
    }

    // MARK: - 睡醒 catch-up

    func testWakeBeforeDueDoesNotRefresh() {
        var s = makeScheduler(minutes: 1440)
        XCTAssertEqual(s.handle(.wake(now: later(60))), .none,
                       "選每天的人不該每次睡醒就被換桌布")
    }

    func testWakeAfterDueCatchesUp() {
        var s = makeScheduler(minutes: 5)
        XCTAssertEqual(s.handle(.wake(now: later(42))), .refresh, "睡過頭要補一輪")
        XCTAssertEqual(s.nextDue, later(47))
    }

    func testWakeWhilePausedDoesNothing() {
        var s = makeScheduler()
        _ = s.handle(.pause)
        XCTAssertEqual(s.handle(.wake(now: later(99))), .none)
    }

    // MARK: - 熱插拔與間隔

    func testScreensChangedRefreshesWithoutResettingCountdown() {
        var s = makeScheduler()
        XCTAssertEqual(s.handle(.screensChanged(now: later(2))), .refresh, "新螢幕要立刻有桌布")
        XCTAssertEqual(s.nextDue, later(5), "熱插拔不重設排程")
    }

    func testScreensChangedWhilePausedDoesNothing() {
        var s = makeScheduler()
        _ = s.handle(.pause)
        XCTAssertEqual(s.handle(.screensChanged(now: later(2))), .none)
    }

    func testIntervalChangeReschedulesFromNow() {
        var s = makeScheduler(minutes: 5)
        XCTAssertEqual(s.handle(.intervalChanged(minutes: 60, now: later(1))), .none)
        XCTAssertEqual(s.nextDue, later(61))
        XCTAssertEqual(s.handle(.tick(now: later(30))), .none)
        XCTAssertEqual(s.handle(.tick(now: later(61))), .refresh)
    }

    func testIntervalOptionsAreTheFixedFive() {
        XCTAssertEqual(Scheduler.intervalOptions, [5, 15, 30, 60, 1440])
    }
}

extension SchedulerTests {

    /// 選單與設定視窗共用同一份標籤，兩邊不會講不一樣的話。
    func testIntervalLabelsAreHumanReadable() {
        XCTAssertEqual(Scheduler.intervalLabel(5), "5 分鐘")
        XCTAssertEqual(Scheduler.intervalLabel(60), "1 小時")
        XCTAssertEqual(Scheduler.intervalLabel(1440), "每天")
    }

    func testEveryIntervalOptionHasALabel() {
        for minutes in Scheduler.intervalOptions {
            XCTAssertFalse(Scheduler.intervalLabel(minutes).isEmpty)
        }
    }

    func testEveryEffectHasADisplayName() {
        for effect in PostProcess.allCases {
            XCTAssertFalse(effect.displayName.isEmpty, "\(effect) 沒有可顯示的名稱")
        }
        XCTAssertEqual(PostProcess.grayscale.displayName, "灰階")
    }
}
