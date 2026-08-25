//  App.swift
//  選單列 app：沒有 WindowGroup，啟動不跳空視窗、不彈 NSOpenPanel。
//  SwiftUI 的 Settings 場景只在使用者主動打開時出現（收 API key／伺服器網址用）。

import SwiftUI

@main
struct FoldwallApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var settings: AppSettings
    @State private var coordinator: WallpaperCoordinator

    init() {
        let settings = AppSettings()
        let coordinator = WallpaperCoordinator(settings: settings)
        _settings = State(initialValue: settings)
        _coordinator = State(initialValue: coordinator)

        // 啟動工作**不能**掛在 MenuBarExtra 內容的 .task 上：
        // menu 樣式的內容只有在使用者點開選單時才會建立，沒點就完全不會跑，
        // app 會安靜地什麼都不做。改由 AppDelegate 在啟動完成時觸發。
        AppDelegate.onLaunch = {
            coordinator.start()
            // extension 在系統設定按「加入影片」時會開 foldwall://add-video
            URLCommandHandler.shared.addFolders = {
                Task { await coordinator.addFolders() }
            }
        }
    }

    var body: some Scene {
        MenuBarExtra("Foldwall", systemImage: "photo.on.rectangle.angled") {
            MenuBarView(coordinator: coordinator, settings: settings)
        }

        SwiftUI.Settings {
            SettingsView(
                coordinator: coordinator,
                settings: settings,
                onChange: { coordinator.sourcesDidChange() },
                onVideoToggle: { coordinator.videoWallpaperEnabledDidChange() },
                onRulesChange: { coordinator.sourceRulesDidChange() }
            )
        }
    }
}
