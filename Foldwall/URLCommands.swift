//  URLCommands.swift
//  接住 extension 在系統設定裡發出的 foldwall:// 指令。
//
//  fork 自 Phosphene 的 extension 會在桌布清單放「加入影片／管理影片庫」的磚，
//  按下去是用 NSWorkspace 開 URL scheme。上游用 phosphene://，我們改成 foldwall://
//  並在這裡處理——沒註冊也沒處理的話，系統會跳「未設定應用程式來打開 URL」。
//
//  行為與 Phosphene 不同：Foldwall 的影片來自來源資料夾，沒有獨立的影片庫視窗，
//  所以「加入影片」＝開資料夾選擇器。

import AppKit

@MainActor
final class URLCommandHandler {
    static let shared = URLCommandHandler()

    /// 由 App 在啟動時接上。
    var addFolders: (() -> Void)?

    func handle(_ url: URL) {
        guard url.scheme == "foldwall" else { return }
        // foldwall://add-video 的 host 是 "add-video"
        let command = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        Log.app.info("收到 URL 指令：\(command, privacy: .public)")

        switch command {
        case "add-video":
            NSApp.activate(ignoringOtherApps: true)
            addFolders?()
        case "library":
            openSettings()
        default:
            openSettings()
        }
    }

    /// 選單列 app 沒有主視窗，只能靠 AppKit 的動作打開 Settings 場景。
    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // macOS 14+ 是 showSettingsWindow:，更早是 showPreferencesWindow:
        for name in ["showSettingsWindow:", "showPreferencesWindow:"] {
            if NSApp.sendAction(Selector((name)), to: nil, from: nil) { return }
        }
        // 兩個都不通就退而求其次：直接開影片庫資料夾
        NSWorkspace.shared.open(VideoLibrary.documentsURL)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 由 FoldwallApp.init 設定。啟動工作放這裡而不是 MenuBarExtra 的 .task——
    /// 後者要等使用者點開選單才會執行。
    @MainActor static var onLaunch: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Self.onLaunch?()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            urls.forEach { URLCommandHandler.shared.handle($0) }
        }
    }
}
