//  App.swift
//  選單列 app：沒有 WindowGroup，啟動不跳空視窗、不彈 NSOpenPanel。
//  SwiftUI 的 Settings 場景只在使用者主動打開時出現（收 API key／伺服器網址用）。

import SwiftUI
import FoldwallCore

@main
struct FoldwallApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var settings: AppSettings
    @State private var coordinator: WallpaperCoordinator
    @State private var translator: UITranslator

    init() {
        let settings = AppSettings()

        // 使用者自翻的介面語言要在**任何 View 建立前**裝上：SwiftUI 已渲染的 Text
        // 不會因 Bundle 改變而重繪，晚一步就只有半套。裝不上（檔被刪了）就退回內建。
        let translationStore = UITranslationStore(directory: AppPaths.standard().uiTranslations)
        if let language = settings.uiTranslationLanguage {
            if translationStore.installOverride(language: language, bundles: UITranslator.sourceBundles) {
                UITranslator.runningSelection = .translated(language)
            } else {
                Log.app.error("介面翻譯 \(language, privacy: .public) 裝不上（翻譯檔不在？），退回內建語言")
            }
        } else if let builtin = settings.builtinLanguage {
            // AppleLanguages 已經在選定當下寫進 App domain，這裡只是記下這個行程跑的是哪個，
            // 讓設定頁判斷得出「選了別的、要重啟」。
            UITranslator.runningSelection = .builtin(builtin)
        }
        let translator = UITranslator(
            store: translationStore, settings: settings,
            registry: CLIEngineRegistry(settings: settings))

        let coordinator = WallpaperCoordinator(settings: settings)
        _settings = State(initialValue: settings)
        _coordinator = State(initialValue: coordinator)
        _translator = State(initialValue: translator)

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
                translator: translator,
                onChange: { coordinator.sourcesDidChange() },
                onVideoToggle: { coordinator.videoWallpaperEnabledDidChange() },
                onRulesChange: { coordinator.sourceRulesDidChange() }
            )
        }
    }
}
