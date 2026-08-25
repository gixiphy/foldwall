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
        static let videoWallpaperEnabled = "videoWallpaperEnabled"
        static let videoRotationCursor = "videoRotationCursor"
        static let videoRemoteCursor = "videoRemoteCursor"
        static let launchAtLogin = "launchAtLogin"
        static let remoteSources = "remoteSources"
        static let photoAlbums = "photoAlbums"
        static let sourceRules = "sourceRules"
        static let folderUsage = "folderUsage"
        static let videoEngine = "videoEngine"
        static let desktopVideoLayer = "desktopVideoLayer"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var intervalMinutes: Int {
        didSet { defaults.set(intervalMinutes, forKey: Key.intervalMinutes) }
    }

    var effect: PostProcess {
        didSet { defaults.set(effect.rawValue, forKey: Key.effect) }
    }

    /// 每個來源資料夾要餵給哪條管線（蒙太奇／影片）。
    /// 鍵是資料夾路徑；沒設定過的一律 `.both`，與加入資料夾當下的直覺一致。
    var folderUsage: [String: SourceUsage] {
        didSet {
            guard let data = try? JSONEncoder().encode(folderUsage) else { return }
            defaults.set(data, forKey: Key.folderUsage)
        }
    }

    func usage(for folder: URL) -> SourceUsage {
        folderUsage[folder.standardizedFileURL.path] ?? .both
    }

    func setUsage(_ usage: SourceUsage, for folder: URL) {
        folderUsage[folder.standardizedFileURL.path] = usage
    }

    /// 依系統狀態調整來源的規則（電池／專注模式）。預設空＝行為與以前完全相同。
    var sourceRules: [SourceRule] {
        didSet {
            guard let data = try? JSONEncoder().encode(sourceRules) else { return }
            defaults.set(data, forKey: Key.sourceRules)
        }
    }

    /// 影片桌布總開關，**預設關**。
    ///
    /// 關著就一支影片都不拷。開了才把來源資料夾裡的影片送進 extension container——
    /// 那是實體拷貝（沙盒 extension 讀不到 app 的 bookmark），一座 NAS 可以是幾百 GB。
    /// 預設開的話，只想要靜態蒙太奇的人會平白被塞爆磁碟。
    var videoWallpaperEnabled: Bool {
        didSet { defaults.set(videoWallpaperEnabled, forKey: Key.videoWallpaperEnabled) }
    }

    /// 影片桌布用哪條管線。預設桌面視窗：零拷貝、公開 API。
    /// 要鎖屏才切到系統 extension。
    var videoEngine: VideoEngine {
        didSet { defaults.set(videoEngine.rawValue, forKey: Key.videoEngine) }
    }

    /// 桌面視窗壓在圖示上面還是下面。
    var desktopVideoLayer: DesktopVideoLayer {
        didSet { defaults.set(desktopVideoLayer.rawValue, forKey: Key.desktopVideoLayer) }
    }

    /// 影片輪替走到哪了。存起來才能跨重啟繼續輪，不會每次都從頭那幾支開始。
    var videoRotationCursor: Int {
        didSet { defaults.set(videoRotationCursor, forKey: Key.videoRotationCursor) }
    }

    /// 網路影片各自一個游標：兩邊數量差很多（實測 4596 對 6），
    /// 共用游標會讓網路那幾支永遠輪不到。
    var videoRemoteCursor: Int {
        didSet { defaults.set(videoRemoteCursor, forKey: Key.videoRemoteCursor) }
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
        self.videoWallpaperEnabled = defaults.bool(forKey: Key.videoWallpaperEnabled)   // 缺 key = false
        self.videoEngine = (defaults.string(forKey: Key.videoEngine)
            .flatMap(VideoEngine.init(rawValue:))) ?? .desktopWindow
        self.desktopVideoLayer = (defaults.string(forKey: Key.desktopVideoLayer)
            .flatMap(DesktopVideoLayer.init(rawValue:))) ?? .belowIcons
        self.videoRotationCursor = defaults.integer(forKey: Key.videoRotationCursor)   // 缺 key = 0
        self.videoRemoteCursor = defaults.integer(forKey: Key.videoRemoteCursor)
        // 以系統實際狀態為準，不信 defaults：使用者可能在系統設定裡關掉
        self.launchAtLogin = SMAppService.mainApp.status == .enabled

        self.remoteSources = (defaults.data(forKey: Key.remoteSources)
            .flatMap { try? JSONDecoder().decode([RemoteSourceConfig].self, from: $0) }) ?? []
        self.photoAlbums = Set(defaults.stringArray(forKey: Key.photoAlbums) ?? [])
        self.sourceRules = (defaults.data(forKey: Key.sourceRules)
            .flatMap { try? JSONDecoder().decode([SourceRule].self, from: $0) }) ?? []
        self.folderUsage = (defaults.data(forKey: Key.folderUsage)
            .flatMap { try? JSONDecoder().decode([String: SourceUsage].self, from: $0) }) ?? [:]
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
