//  MenuBarView.swift
//  選單列內容。沒有多螢模式開關（「此螢幕改用影片」是影片佔用標記，不是模式）。

import SwiftUI
import FoldwallCore

struct MenuBarView: View {

    @Bindable var coordinator: WallpaperCoordinator
    @Bindable var settings: Settings

    var body: some View {
        Group {
            statusLine

            if coordinator.status.hasNoSources {
                Button("尚未加入資料夾…") { Task { await coordinator.addFolders() } }
            }

            Divider()

            Button("下一張") { coordinator.next() }
                .keyboardShortcut("n")
            Button(coordinator.status.isPaused ? "繼續" : "暫停") { coordinator.togglePause() }

            intervalMenu
            effectMenu

            Divider()

            displayMenu
            sourcesMenu

            if coordinator.status.offlineCount > 0 {
                Button("來源離線／無權限（\(coordinator.status.offlineCount)）…") {
                    openPrivacySettings()
                }
            }

            Divider()

            Toggle("登入時啟動", isOn: $settings.launchAtLogin)
            Button("在 Finder 顯示快取") { revealCache() }
            Button("系統設定 → 桌布…") { openWallpaperSettings() }

            Divider()

            Button("結束 Foldwall") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    // MARK: - 狀態

    private var statusLine: some View {
        Text(statusText)
            .font(.caption)
    }

    private var statusText: String {
        let status = coordinator.status
        if status.hasNoSources { return "尚未加入資料夾" }
        if status.offlineCount > 0 && status.sourceCount == 0 {
            return "來源離線 \(status.offlineCount) 個"
        }
        if status.poolWasEmpty || status.poolCount == 0 {
            return "來源無可用影像"
        }

        let base = "來源 \(status.sourceCount)・池 \(status.poolCount)"
        if status.isPaused { return base + "・已暫停" }
        guard let due = status.nextDue else { return base }
        return base + "・下次 " + due.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - 子選單

    private var intervalMenu: some View {
        Menu("間隔") {
            ForEach(Scheduler.intervalOptions, id: \.self) { minutes in
                Button {
                    coordinator.setInterval(minutes)
                } label: {
                    Label(Self.intervalLabel(minutes),
                          systemImage: settings.intervalMinutes == minutes ? "checkmark" : "")
                }
            }
        }
    }

    private static func intervalLabel(_ minutes: Int) -> String {
        switch minutes {
        case 1440: return "每天"
        case 60: return "1 小時"
        default: return "\(minutes) 分鐘"
        }
    }

    private var effectMenu: some View {
        Menu("後製") {
            ForEach(PostProcess.allCases, id: \.self) { effect in
                Button {
                    coordinator.setEffect(effect)
                } label: {
                    Label(Self.effectLabel(effect),
                          systemImage: settings.effect == effect ? "checkmark" : "")
                }
            }
        }
    }

    private static func effectLabel(_ effect: PostProcess) -> String {
        switch effect {
        case .none: return "無"
        case .grayscale: return "灰階"
        case .sepia: return "棕褐"
        case .desaturate: return "去飽和"
        case .random: return "隨機"
        }
    }

    /// 每螢一項：勾起來代表那台改播影片，靜態管線跳過。
    private var displayMenu: some View {
        Menu("此螢幕改用影片") {
            ForEach(Array(coordinator.displays.enumerated()), id: \.element.uuid) { index, display in
                Button {
                    coordinator.toggleVideo(for: display)
                } label: {
                    Label("螢幕 \(index + 1)（\(Int(display.canvas.width))×\(Int(display.canvas.height))）",
                          systemImage: coordinator.isVideoScreen(display) ? "checkmark" : "")
                }
            }
            Divider()
            Text("影片需在「系統設定 → 桌布」選片，再回來勾這裡")
                .font(.caption)
        }
    }

    private var sourcesMenu: some View {
        Menu("來源資料夾") {
            if coordinator.folders.isEmpty {
                Text("（沒有可讀的來源）")
            }
            ForEach(coordinator.folders, id: \.self) { folder in
                Menu(folder.lastPathComponent) {
                    Button("在 Finder 顯示") { coordinator.revealInFinder(folder) }
                    Button("移除此來源") { coordinator.removeFolder(folder) }
                }
            }
            Divider()
            Button("加入資料夾…") { Task { await coordinator.addFolders() } }
        }
    }

    // MARK: - 系統入口

    private func revealCache() {
        let dir = AppPaths.standard().wallpapers
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    private func openWallpaperSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
