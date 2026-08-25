//  App.swift
//  選單列 app：沒有 WindowGroup，啟動不跳空視窗、不彈 NSOpenPanel。
//  AppSettings 場景只在使用者主動打開時出現（收 API key／伺服器網址用）。

import SwiftUI

@main
struct FoldwallApp: App {

    @State private var settings: AppSettings
    @State private var coordinator: WallpaperCoordinator

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _coordinator = State(initialValue: WallpaperCoordinator(settings: settings))
    }

    var body: some Scene {
        MenuBarExtra("Foldwall", systemImage: "photo.on.rectangle.angled") {
            MenuBarView(coordinator: coordinator, settings: settings)
                .task { coordinator.start() }
        }

        // SwiftUI 的 Settings 場景；我們的設定模型叫 AppSettings，避免遮蔽
        SwiftUI.Settings {
            SettingsView(settings: settings) {
                coordinator.sourcesDidChange()
            }
        }
    }
}
