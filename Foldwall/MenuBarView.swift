//  MenuBarView.swift
//  選單列內容。沒有多螢模式開關（「此螢幕改用影片」是影片佔用標記，不是模式）。

import SwiftUI
import FoldwallCore

struct MenuBarView: View {

    @Bindable var coordinator: WallpaperCoordinator
    @Bindable var settings: AppSettings

    var body: some View {
        Group {
            statusLine

            if coordinator.status.hasNoSources {
                Button("加入資料夾…") { Task { await coordinator.addFolders() } }
                SettingsLink { Text("…或在設定裡加照片相簿／網路來源") }
            }

            Divider()

            Button("下一張") { coordinator.next() }
                .keyboardShortcut("n")
            Button(coordinator.status.isPaused ? "繼續" : "暫停") { coordinator.togglePause() }

            intervalMenu
            effectMenu

            Divider()

            displayMenu
            SettingsLink { Text("設定（來源・影片・規則）…") }
                .keyboardShortcut(",")

            if let reason = coordinator.status.activeRuleReason {
                Text("狀態規則生效中：\(reason)")
                    .font(.caption)
            }

            if let error = coordinator.status.sourceError {
                Text("網路來源異常：\(error)")
                    .font(.caption)
            }

            if coordinator.status.offlineCount > 0 {
                Button("來源離線／無權限（\(coordinator.status.offlineCount)）…") {
                    openPrivacySettings()
                }
            }

            Divider()

            Toggle("登入時啟動", isOn: $settings.launchAtLogin)
            Button("在 Finder 顯示快取") { revealCache() }

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
        if status.hasNoSources { return "尚未加入任何來源" }
        if status.offlineCount > 0 && status.sourceCount == 0 {
            return "來源離線 \(status.offlineCount) 個"
        }
        if status.activeEffects.contains(.pauseRotation) {
            return "已依狀態規則暫停" + (status.activeRuleReason.map { "（\($0)）" } ?? "")
        }
        if status.poolWasEmpty || status.poolCount == 0 {
            // 掃描還在跑就別誤報「沒圖」——大型資料夾要幾分鐘才走得完
            return status.isIndexing ? "正在掃描資料夾…" : "來源無可用影像"
        }

        var parts = ["池 \(status.poolCount)"]
        if status.sourceCount > 0 { parts.insert("資料夾 \(status.sourceCount)", at: 0) }
        if status.photosCount > 0 { parts.append("相簿 \(status.photosCount)") }
        if status.remoteCount > 0 { parts.append("網路 \(status.remoteCount)") }
        var base = parts.joined(separator: "・")
        if status.isIndexing { base += "・掃描中" }
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
            // 入口就放在說明旁邊——它只在這條流程裡用得到，擺在主選單底部
            // 離使用它的情境太遠。
            Button("打開 系統設定 → 桌布…") { openWallpaperSettings() }
            if !coordinator.status.videoReady && !settings.videoScreens.isEmpty {
                Text("影片尚未備妥，這些螢幕暫由蒙太奇接管")
                    .font(.caption)
            }
        }
    }

    // MARK: - 系統入口

    private func revealCache() {
        let dir = AppPaths.standard().wallpapers
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    private func openWallpaperSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-AppSettings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
