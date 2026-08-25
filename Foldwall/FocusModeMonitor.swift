//  FocusModeMonitor.swift
//  讀 ~/Library/DoNotDisturb/DB/ 判斷目前的專注模式。
//
//  為什麼用輪詢而不是 file watcher：那些檔案是**原子替換**寫入的（寫新檔再 rename），
//  DispatchSource 綁在舊 inode 上，第一次變更後就再也收不到通知。
//  檔案只有幾 KB，跟著既有的 15 秒心跳讀一次，成本可以忽略。

import Foundation
import FoldwallCore

@MainActor
final class FocusModeMonitor {

    private static var databaseURL: URL {
        URL.homeDirectory.appending(path: "Library/DoNotDisturb/DB")
    }

    private(set) var activeModeID: String?
    private(set) var availableModes: [FocusMode] = []

    /// 模式清單不常變，不必每 15 秒重讀。
    private var modesLoadedAt: Date?
    private static let modesReloadInterval: TimeInterval = 10 * 60

    /// - Returns: 啟用中的模式是否**改變了**。變了才需要重跑一輪。
    @discardableResult
    func refresh() -> Bool {
        reloadModesIfNeeded()

        let data = try? Data(contentsOf: Self.databaseURL.appending(path: "Assertions.json"))
        let latest = data.flatMap { FocusModeParser.activeModeID(assertions: $0) }
        guard latest != activeModeID else { return false }

        activeModeID = latest
        Log.app.info("專注模式：\(latest ?? "（無）", privacy: .public)")
        return true
    }

    /// 目前模式的顯示名稱，找不到就退回識別碼。
    var activeModeName: String? {
        guard let activeModeID else { return nil }
        return availableModes.first { $0.id == activeModeID }?.name ?? activeModeID
    }

    private func reloadModesIfNeeded() {
        let stale = modesLoadedAt.map { Date.now.timeIntervalSince($0) > Self.modesReloadInterval } ?? true
        guard stale || availableModes.isEmpty else { return }

        let url = Self.databaseURL.appending(path: "ModeConfigurations.json")
        if let data = try? Data(contentsOf: url) {
            let parsed = FocusModeParser.modes(configurations: data)
            if !parsed.isEmpty { availableModes = parsed }
        }
        modesLoadedAt = .now
    }
}
