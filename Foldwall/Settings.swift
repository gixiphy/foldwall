//  Settings.swift
//  UserDefaults key 由 HANDOFF 設定 schema 鎖定，不要改。

import Foundation
import Observation
import ServiceManagement
import FoldwallCore

@MainActor
@Observable
final class Settings {

    enum Key {
        static let intervalMinutes = "intervalMinutes"
        static let effect = "effect"
        static let videoScreens = "videoScreens"
        static let launchAtLogin = "launchAtLogin"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var intervalMinutes: Int {
        didSet { defaults.set(intervalMinutes, forKey: Key.intervalMinutes) }
    }

    var effect: PostProcess {
        didSet { defaults.set(effect.rawValue, forKey: Key.effect) }
    }

    /// 使用者標記「這台改用影片」的螢幕，存 display UUID。
    /// **不能存 CGDirectDisplayID**：重開機／熱插拔會變，會記錯螢幕。
    var videoScreens: Set<String> {
        didSet { defaults.set(Array(videoScreens), forKey: Key.videoScreens) }
    }

    var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedInterval = defaults.integer(forKey: Key.intervalMinutes)
        self.intervalMinutes = Scheduler.intervalOptions.contains(storedInterval)
            ? storedInterval
            : Scheduler.defaultIntervalMinutes

        self.effect = (defaults.string(forKey: Key.effect).flatMap(PostProcess.init(rawValue:))) ?? .none
        self.videoScreens = Set(defaults.stringArray(forKey: Key.videoScreens) ?? [])
        // 以系統實際狀態為準，不信 defaults：使用者可能在系統設定裡關掉
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin() {
        defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("登入時啟動設定失敗：\(error.localizedDescription, privacy: .public)")
        }
    }
}
