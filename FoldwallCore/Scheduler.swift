//  Scheduler.swift
//  純狀態機：事件進、動作出。不擁有 Timer、不讀系統時鐘，所以時間相關行為全部可測。
//  app 層負責把 Timer 與系統通知翻譯成 Event（含熱插拔的 debounce）。

import Foundation

public struct Scheduler: Sendable {

    /// 選單的固定選項（分鐘）。沒有自訂輸入框。
    public static let intervalOptions = [5, 15, 30, 60, 1440]

    /// 選單與設定視窗共用同一份標籤，兩邊不會講不一樣的話。
    public static func intervalLabel(_ minutes: Int) -> String {
        switch minutes {
        case 1440: "每天"
        case 60: "1 小時"
        default: "\(minutes) 分鐘"
        }
    }
    public static let defaultIntervalMinutes = 5

    public enum Event: Sendable {
        /// Timer 心跳。
        case tick(now: Date)
        /// 使用者按「下一張」。
        case userNext(now: Date)
        case pause
        case resume(now: Date)
        /// 系統睡醒：只在已過排程時間時補一輪（catch-up），否則「每天」會被每次睡醒打斷。
        case wake(now: Date)
        /// 螢幕數量／排列改變（app 層已 debounce）。
        case screensChanged(now: Date)
        case intervalChanged(minutes: Int, now: Date)
    }

    public enum Action: Sendable, Equatable {
        case refresh
        case none
    }

    public private(set) var intervalMinutes: Int
    public private(set) var isPaused = false
    public private(set) var nextDue: Date

    public init(intervalMinutes: Int = Scheduler.defaultIntervalMinutes, now: Date) {
        self.intervalMinutes = intervalMinutes
        self.nextDue = now.addingTimeInterval(TimeInterval(intervalMinutes) * 60)
    }

    @discardableResult
    public mutating func handle(_ event: Event) -> Action {
        switch event {
        case .tick(let now):
            guard !isPaused, now >= nextDue else { return .none }
            reschedule(from: now)
            return .refresh

        case .userNext(let now):
            // 暫停中也能單發換一張，但不解除暫停
            if !isPaused { reschedule(from: now) }
            return .refresh

        case .pause:
            isPaused = true
            return .none

        case .resume(let now):
            isPaused = false
            reschedule(from: now)
            return .refresh   // 恢復立即刷新一輪，再回排程

        case .wake(let now):
            guard !isPaused, now >= nextDue else { return .none }
            reschedule(from: now)
            return .refresh

        case .screensChanged(let now):
            _ = now
            // 新螢幕要立刻有桌布，但不重設倒數：插拔不該影響輪播節奏
            return isPaused ? .none : .refresh

        case .intervalChanged(let minutes, let now):
            intervalMinutes = minutes
            reschedule(from: now)
            return .none
        }
    }

    private mutating func reschedule(from now: Date) {
        nextDue = now.addingTimeInterval(TimeInterval(intervalMinutes) * 60)
    }
}
