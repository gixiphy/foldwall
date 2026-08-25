//  AppSettings.swift
//  UserDefaults key 由 HANDOFF 設定 schema 鎖定，不要改。

import Foundation
import Observation
import ServiceManagement
import FoldwallCore

@MainActor
@Observable
final class AppSettings {

    enum Key {
        static let intervalMinutes = "intervalMinutes"
        static let effect = "effect"
        static let videoScreens = "videoScreens"
        static let launchAtLogin = "launchAtLogin"
        static let remoteSources = "remoteSources"
        static let photoAlbums = "photoAlbums"
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

    /// 免 OAuth 的網路來源。API key 不在這裡，在 Keychain（以 config.id 為帳號）。
    var remoteSources: [RemoteSourceConfig] {
        didSet {
            guard let data = try? JSONEncoder().encode(remoteSources) else { return }
            defaults.set(data, forKey: Key.remoteSources)
        }
    }

    /// 選中的「照片」相簿 localIdentifier。
    var photoAlbums: Set<String> {
        didSet { defaults.set(Array(photoAlbums), forKey: Key.photoAlbums) }
    }

    /// Keychain 帳號名：每個來源設定各自一把 key。
    static func keychainAccount(for config: RemoteSourceConfig) -> String {
        "remote-\(config.kind.rawValue)-\(config.id.uuidString)"
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

        self.remoteSources = (defaults.data(forKey: Key.remoteSources)
            .flatMap { try? JSONDecoder().decode([RemoteSourceConfig].self, from: $0) }) ?? []
        self.photoAlbums = Set(defaults.stringArray(forKey: Key.photoAlbums) ?? [])
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
