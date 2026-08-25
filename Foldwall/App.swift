//  App.swift
//  選單列 app：沒有 WindowGroup，啟動不跳空視窗、不彈 NSOpenPanel。

import SwiftUI

@main
struct FoldwallApp: App {

    @State private var settings: Settings
    @State private var coordinator: WallpaperCoordinator

    init() {
        let settings = Settings()
        _settings = State(initialValue: settings)
        _coordinator = State(initialValue: WallpaperCoordinator(settings: settings))
    }

    var body: some Scene {
        MenuBarExtra("Foldwall", systemImage: "photo.on.rectangle.angled") {
            MenuBarView(coordinator: coordinator, settings: settings)
                .task { coordinator.start() }
        }
    }
}
