//  WallpaperCoordinator.swift
//  把書籤、索引、排程、電源、管線接起來。Timer 與系統通知在這裡翻譯成 Scheduler.Event。

import AppKit
import Foundation
import IOKit.ps
import Observation
import FoldwallCore

@MainActor
@Observable
final class WallpaperCoordinator {

    struct Status: Equatable {
        var sourceCount = 0
        var poolCount = 0
        var offlineCount = 0
        var isPaused = false
        var poolWasEmpty = false
        var nextDue: Date?

        var hasNoSources: Bool { sourceCount == 0 && offlineCount == 0 }
    }

    private(set) var status = Status()
    private(set) var folders: [URL] = []

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let bookmarks: BookmarkStore
    @ObservationIgnored private let pipeline: StillPipeline
    @ObservationIgnored private let indexer = MediaIndexer()

    @ObservationIgnored private var scheduler: Scheduler
    @ObservationIgnored private var heartbeat: Timer?
    @ObservationIgnored private var screenDebounce: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var cycleNonce = UInt64(Date().timeIntervalSince1970)

    init(settings: Settings, bookmarks: BookmarkStore = BookmarkStore()) {
        self.settings = settings
        self.bookmarks = bookmarks
        self.scheduler = Scheduler(intervalMinutes: settings.intervalMinutes, now: .now)
        let paths = AppPaths.standard()
        self.pipeline = StillPipeline(
            desktop: WorkspaceDesktopSetting(),
            paths: paths,
            preparer: Materializer(cacheDirectory: paths.smbCache)
        )
    }

    // MARK: - 生命週期

    func start() {
        observeSystem()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.dispatch(.tick(now: .now)) }
        }
        reloadFolders()
        refreshNow()
    }

    private func observeSystem() {
        let center = NotificationCenter.default

        // 一次插拔會連發多次通知：debounce 後只跑一輪
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screensChangedDebounced() }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dispatch(.wake(now: .now)) }
        }

        center.addObserver(forName: BookmarkStore.didChangeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.reloadFolders()
                self?.refreshNow()
            }
        }
    }

    private func screensChangedDebounced() {
        screenDebounce?.cancel()
        screenDebounce = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            dispatch(.screensChanged(now: .now))
        }
    }

    // MARK: - 使用者動作

    func next() { dispatch(.userNext(now: .now)) }

    func togglePause() {
        dispatch(status.isPaused ? .resume(now: .now) : .pause)
    }

    func setInterval(_ minutes: Int) {
        settings.intervalMinutes = minutes
        dispatch(.intervalChanged(minutes: minutes, now: .now))
    }

    func setEffect(_ effect: PostProcess) {
        settings.effect = effect
        refreshNow()
    }

    func addFolders() async {
        do {
            _ = try await bookmarks.addFolders()
        } catch {
            Log.sources.error("加入資料夾失敗：\(error.localizedDescription, privacy: .public)")
        }
    }

    func removeFolder(_ url: URL) {
        do {
            try bookmarks.removeFolder(url)
        } catch {
            Log.sources.error("移除資料夾失敗：\(error.localizedDescription, privacy: .public)")
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 「此螢幕改用影片」：勾了就不對該螢寫靜態桌布。
    func toggleVideo(for display: DisplayTarget) {
        if settings.videoScreens.contains(display.uuid) {
            settings.videoScreens.remove(display.uuid)
            refreshNow()   // 取消後立刻補一張蒙太奇回去
        } else {
            settings.videoScreens.insert(display.uuid)
        }
    }

    func isVideoScreen(_ display: DisplayTarget) -> Bool {
        settings.videoScreens.contains(display.uuid)
    }

    var displays: [DisplayTarget] { ScreenBridge.currentDisplays() }

    // MARK: - 排程

    private func dispatch(_ event: Scheduler.Event) {
        let action = scheduler.handle(event)
        status.isPaused = scheduler.isPaused
        status.nextDue = scheduler.isPaused ? nil : scheduler.nextDue
        if action == .refresh { refreshNow() }
    }

    private func reloadFolders() {
        folders = bookmarks.resolvedFolders()
        status.sourceCount = folders.count
        status.offlineCount = bookmarks.offlineCount
    }

    private func refreshNow() {
        guard refreshTask == nil else { return }   // 上一輪還在跑就別疊上去
        refreshTask = Task { @MainActor in
            defer { refreshTask = nil }
            await performRefresh()
        }
    }

    private func performRefresh() async {
        reloadFolders()

        let items = await indexer.scan(roots: folders)
        let pool = items.filter { $0.kind == .image }.map(\.url)
        status.poolCount = pool.count

        let displays = ScreenBridge.currentDisplays()
        let skipIDs = Set(displays.filter { settings.videoScreens.contains($0.uuid) }.map(\.id))
        let tier = currentTier()

        guard tier != .paused else {
            Log.pipeline.info("電源分級 paused，跳過這輪")
            return
        }

        cycleNonce &+= 1
        do {
            let outcome = try await pipeline.refresh(
                displays: displays, skipIDs: skipIDs, pool: pool,
                effect: settings.effect, tier: tier, cycleNonce: cycleNonce
            )
            status.poolWasEmpty = outcome.poolWasEmpty
            Log.pipeline.info("已更新 \(outcome.written.count) 螢，跳過 \(outcome.skipped.count) 螢，池 \(pool.count) 張")
        } catch {
            // 失敗保留現桌布，不黑屏
            Log.pipeline.error("合成失敗：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func currentTier() -> PowerTier {
        PowerPolicy.tier(
            thermal: ProcessInfo.processInfo.thermalState,
            onBattery: Self.isOnBattery,
            // v1 沒有乾淨的公開偵測；影片端由 extension 自管
            occluded: false,
            gameMode: false
        )
    }

    private static var isOnBattery: Bool {
        IOPSGetTimeRemainingEstimate() != kIOPSTimeRemainingUnlimited
    }
}
