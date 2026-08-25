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
        var videoCount = 0
        var remoteCount = 0
        var photosCount = 0
        var sourceError: String?
        var nextDue: Date?
        /// 背景還在走資料夾。池數會邊掃邊長，UI 據此說明。
        var isIndexing = false
        /// 被 VideoBudget 上限擋下的影片支數。
        var videosOverBudget = 0
        /// 網路影片來源（Pexels 影片）目前快取到幾支。
        var remoteVideoCount = 0
        /// 目前生效中的狀態規則效果，以及觸發它的原因（給選單顯示）。
        var activeEffects = RuleEffect()
        var activeRuleReason: String?
        /// 影片是否真的備妥（開關開著、規則沒暫停、container 裡有東西）。
        /// 沒備妥時靜態管線會接管那些螢幕，不留無人管的畫面。
        var videoReady = false

        /// 三種來源都沒有才算「還沒設定」。
        var hasNoSources: Bool {
            sourceCount == 0 && offlineCount == 0 && remoteCount == 0 && photosCount == 0
        }
    }

    private(set) var status = Status()
    private(set) var folders: [URL] = []

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let bookmarks: BookmarkStore
    @ObservationIgnored private let pipeline: StillPipeline
    @ObservationIgnored private var folderIndex: FolderIndex!
    @ObservationIgnored private let videoLibrary = VideoLibrary()
    @ObservationIgnored private let remotePool = RemoteSourcePool()
    @ObservationIgnored private let remoteVideoPool = RemoteVideoPool()
    @ObservationIgnored private let photosPool = PhotosPool()
    @ObservationIgnored private let focus = FocusModeMonitor()

    @ObservationIgnored private var scheduler: Scheduler
    @ObservationIgnored private var heartbeat: Timer?
    @ObservationIgnored private var screenDebounce: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var videoSyncTask: Task<Void, Never>?
    /// 世代編號：被取代的舊同步工作結束時，不准去動已經換人的把手。
    @ObservationIgnored private var videoSyncID = 0
    @ObservationIgnored private var lastVideoSync: Date?
    /// 使用者動作（改來源、切開關）要跳過節流，立刻同步一次。
    @ObservationIgnored private var forceVideoSync = false
    /// 螢幕剛亮起，這輪 refresh 要順便換一批影片。
    @ObservationIgnored private var rotateVideosOnNextRefresh = false
    @ObservationIgnored private var cycleNonce = UInt64(Date().timeIntervalSince1970)

    init(settings: AppSettings, bookmarks: BookmarkStore = BookmarkStore()) {
        self.settings = settings
        self.bookmarks = bookmarks
        self.scheduler = Scheduler(intervalMinutes: settings.intervalMinutes, now: .now)
        let paths = AppPaths.standard()
        self.pipeline = StillPipeline(
            desktop: WorkspaceDesktopSetting(),
            paths: paths,
            preparer: Materializer(cacheDirectory: paths.smbCache)
        )
        // 背景掃描落地時立刻補一輪，不必乾等到下一個間隔
        self.folderIndex = FolderIndex(onScanCompleted: { [weak self] in
            Task { @MainActor in self?.refreshNow() }
        })
    }

    // MARK: - 生命週期

    func start() {
        observeSystem()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // 專注模式沒有公開的變更通知，跟著心跳輪詢（檔案只有幾 KB）
                if self.focus.refresh() { self.refreshNow() }
                self.dispatch(.tick(now: .now))
            }
        }
        reloadFolders()
        refreshNow()

        // 開關關著＝container 應該是空的。這裡順手把上次跑到一半留下的孤兒清掉，
        // 否則沒人會呼叫 sync，那些目錄會永遠佔著磁碟（實測留過 17GB）。
        if !settings.videoWallpaperEnabled {
            runVideoSync(videos: [])
        } else {
            // 啟動也算一次「螢幕亮起」：否則 container 會一直停在上次那批，
            // 換版或改設定後也不會收斂到新的上限。
            rotateVideosOnNextRefresh = true
        }
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

        // 影片在**螢幕睡著時**預先換好下一批，亮起時只負責顯示。
        // 拷貝走 SMB 一次可能是好幾百 MB（實測 470MB），放在「使用者剛回到電腦前」
        // 那一刻做就是明顯卡頓；改在沒人用的時候做，看到的結果一樣是「回來就換了一批」。
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.screenDidSleep() }
            }
        }
        for name in ["com.apple.screensaver.didstart", "com.apple.screenIsLocked"] {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.screenDidSleep() }
            }
        }
        // 亮起只重跑靜態；影片除非手上一支都沒有，否則不在這時候拷。
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.screenDidWake() }
            }
        }
        for name in ["com.apple.screensaver.didstop", "com.apple.screenIsUnlocked"] {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.screenDidWake() }
            }
        }

        center.addObserver(forName: BookmarkStore.didChangeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reloadFolders()
                await self.folderIndex.invalidate(roots: self.folders)
                // 移除資料夾要立刻把該來源的影片清掉，不等 30 分鐘節流
                self.forceVideoSync = true
                self.refreshNow()
            }
        }
    }

    /// 螢幕睡著 → 趁沒人用，把下一批影片拷好。節流仍在（最少 30 分鐘），
    /// 否則螢保停停開開一小時就重拷十輪，走 SMB 會很痛。
    private func screenDidSleep() {
        guard settings.videoWallpaperEnabled else { return }
        rotateVideosOnNextRefresh = true
        refreshNow()
    }

    /// 螢幕亮起 → 只重跑靜態。
    /// **不在這時候拷影片**：那是使用者剛回到電腦前的那一刻，470MB 的 SMB 拷貝
    /// 會直接卡在他臉上。唯一例外是手上一支都沒有——那時不拷就什麼都播不了。
    private func screenDidWake() {
        if settings.videoWallpaperEnabled, videoLibrary.deployedCount == 0 {
            rotateVideosOnNextRefresh = true
        }
        refreshNow()
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

    /// 設定視窗改了來源就立刻重跑一輪。
    func sourcesDidChange() { refreshNow() }

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
        // 上一輪還在跑就別疊上去，但要記著補一次——背景索引剛好在這時落地的話，
        // 直接丟掉這次請求會讓新掃到的圖等到下一個間隔（間隔設「每天」就是等一天）。
        guard refreshTask == nil else {
            refreshPending = true
            return
        }
        refreshTask = Task { @MainActor in
            defer {
                refreshTask = nil
                if refreshPending {
                    refreshPending = false
                    refreshNow()
                }
            }
            await performRefresh()
        }
    }

    private func performRefresh() async {
        reloadFolders()

        focus.refresh()
        let context = RuleContext(onBattery: Self.isOnBattery, activeFocusModeID: focus.activeModeID)
        let effects = SourceRuleEngine.effects(rules: settings.sourceRules, context: context)
        status.activeEffects = effects
        status.activeRuleReason = Self.reason(for: context, effects: effects, focusName: focus.activeModeName)

        guard !effects.contains(.pauseRotation) else {
            Log.pipeline.info("狀態規則要求暫停輪換，保留現桌布")
            return
        }

        // **不等掃描**：拿當下快取到的清單就走，背景掃完會自己回呼補一輪。
        let index = await folderIndex.current(roots: folders)
        status.isIndexing = index.isScanning
        var pool = effects.contains(.disableFolders) ? [] : index.images

        // 照片相簿與網路來源各自有節流，不會每輪都去打 API
        let fromPhotos = effects.contains(.disablePhotos)
            ? [] : await photosPool.images(albums: settings.photoAlbums)
        let fromRemote = effects.contains(.disableRemote)
            ? [] : await remotePool.images(configs: settings.remoteSources)
        pool.append(contentsOf: fromPhotos)
        pool.append(contentsOf: fromRemote)

        status.photosCount = fromPhotos.count
        status.remoteCount = fromRemote.count
        status.sourceError = remotePool.lastError
        status.poolCount = pool.count

        status.videoCount = index.videos.count
        if !effects.contains(.pauseVideo) {
            syncVideosInBackground(index)
        }

        let displays = ScreenBridge.currentDisplays()
        // 只有在**影片真的備妥**時才跳過那些螢幕。
        //
        // 少了 deployedCount 這個條件會出現「無人管的螢幕」：關掉影片總開關後
        // container 被清空，但 videoScreens 標記還在，靜態管線照樣跳過那台螢幕——
        // 沒有影片可播、也沒有蒙太奇蓋上去。再開啟時兩者就疊在一起。
        // 判斷條件跟畫面上實際有什麼綁在一起，就沒有中間狀態。
        let videoReady = settings.videoWallpaperEnabled
            && !effects.contains(.pauseVideo)
            && videoLibrary.deployedCount > 0
        let skipIDs = videoReady
            ? Set(displays.filter { settings.videoScreens.contains($0.uuid) }.map(\.id))
            : Set<CGDirectDisplayID>()
        status.videoReady = videoReady
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

    /// 影片同步**絕不能**放在合成路徑上：一支影片走 SMB 要拷好幾分鐘，
    /// await 它就等於把靜態桌布也一起卡死（0.2.4 踩過這個）。
    ///
    /// 另外兩道閘：
    /// - 總開關關著就一支都不碰。使用者只要靜態蒙太奇時，沒有理由拷任何東西。
    /// - 清單不完整時不同步，否則會把還在來源裡的影片當成「已移除」清掉。
    private func syncVideosInBackground(_ index: FolderIndex.Snapshot) {
        guard settings.videoWallpaperEnabled else { return }
        guard index.isComplete else { return }
        // 上一輪還在拷就別疊上去。**不取消它**——走 SMB 拷一支要好幾分鐘，
        // 每 5 分鐘一輪 refresh 若都打斷重來，就永遠拷不完。
        guard videoSyncTask == nil else { return }

        // 影片**不跟著桌布輪換**：只有螢幕重新亮起（或使用者動作）才換一批。
        let force = forceVideoSync
        guard force || rotateVideosOnNextRefresh else { return }
        // 節流仍在：螢保一小時停十次也不該拷十輪。
        guard VideoSyncPolicy.shouldSync(lastSync: lastVideoSync, now: .now, force: force) else {
            rotateVideosOnNextRefresh = false
            return
        }
        forceVideoSync = false
        rotateVideosOnNextRefresh = false
        lastVideoSync = .now

        runVideoRotation(folderVideos: index.videos)
    }

    /// 選片與下載都在**這條背景線**上：網路影片一支幾十 MB，
    /// 放進 performRefresh 就等於又把靜態管線擋住了。
    private func runVideoRotation(folderVideos: [URL]) {
        videoSyncID += 1
        let generation = videoSyncID
        videoSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let remote = await self.remoteVideoPool.videos(configs: self.settings.remoteSources)
            self.status.remoteVideoCount = remote.count
            if let error = self.remoteVideoPool.lastError { self.status.sourceError = error }
            guard self.videoSyncID == generation else { return }

            // 兩邊分開輪：資料夾可能有幾千支、網路只有幾支，混在一起排序的話
            // 網路那幾支要繞完全庫才輪得到＝永遠不會播。
            let remoteSlots = VideoBudget.remoteSlots(
                remoteCount: remote.count, folderCount: folderVideos.count
            )
            let remoteRotation = VideoBudget.rotate(
                remote, cursor: self.settings.videoRemoteCursor,
                count: remoteSlots, size: Self.fileSize
            )
            let folderRotation = VideoBudget.rotate(
                folderVideos, cursor: self.settings.videoRotationCursor,
                count: VideoBudget.rotationCount - remoteRotation.selected.count,
                totalBytes: VideoBudget.rotationBytes - remoteRotation.usedBytes,
                size: Self.fileSize
            )

            self.settings.videoRemoteCursor = remoteRotation.nextCursor
            self.settings.videoRotationCursor = folderRotation.nextCursor

            let selected = remoteRotation.selected + folderRotation.selected
            let total = folderVideos.count + remote.count
            self.status.videosOverBudget = max(0, total - selected.count)
            Log.video.info("這輪帶 \(selected.count, privacy: .public) 支（資料夾 \(folderRotation.selected.count, privacy: .public)／\(folderVideos.count, privacy: .public)、網路 \(remoteRotation.selected.count, privacy: .public)／\(remote.count, privacy: .public)），游標 \(folderRotation.nextCursor, privacy: .public)・\(remoteRotation.nextCursor, privacy: .public)")

            await self.videoLibrary.sync(videos: selected)
            guard self.videoSyncID == generation else { return }
            self.videoSyncTask = nil
            // container 內容變了 → 重評哪些螢幕該由蒙太奇接管
            self.refreshNow()
        }
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize
        else { return nil }
        return Int64(size)
    }

    /// 總開關關掉時把 container 清空，別讓幾十 GB 留在磁碟上。
    func videoWallpaperEnabledDidChange() {
        guard !settings.videoWallpaperEnabled else {
            forceVideoSync = true   // 剛打開就別讓使用者等 30 分鐘
            refreshNow()
            return
        }
        lastVideoSync = nil
        let inFlight = videoSyncTask
        inFlight?.cancel()
        runVideoSync(videos: [], after: inFlight)
    }

    private func runVideoSync(videos: [URL], after previous: Task<Void, Never>? = nil) {
        videoSyncID += 1
        let generation = videoSyncID
        videoSyncTask = Task { @MainActor [weak self] in
            await previous?.value   // 等前一輪收手，別兩邊同時動 container
            guard let self else { return }
            await self.videoLibrary.sync(videos: videos)
            guard self.videoSyncID == generation else { return }   // 已被新的取代
            if videos.isEmpty { self.status.videosOverBudget = 0 }
            self.videoSyncTask = nil
            // 清空 container 之後，那些螢幕要立刻由蒙太奇接管，不能留白
            self.refreshNow()
        }
    }

    /// 選單要說得出「為什麼現在停著」。
    private static func reason(
        for context: RuleContext, effects: RuleEffect, focusName: String?
    ) -> String? {
        guard !effects.isEmpty else { return nil }
        var causes: [String] = []
        if context.onBattery { causes.append("電池") }
        if let focusName { causes.append("專注：\(focusName)") }
        return causes.isEmpty ? nil : causes.joined(separator: "・")
    }

    /// 清除某個快取目錄。
    ///
    /// 兩個目錄不能直接砍：
    /// - **合成輸出**砍掉等於把目前掛在桌面上的檔案刪了，畫面會停在舊圖或變空，
    ///   所以刪完立刻重合成一張。
    /// - **影片 container** 要連帳本一起清，否則下次同步會把它們當成孤兒——
    ///   雖然啟動時的 sweepOrphans 會收拾，但沒必要製造那個中間狀態。
    /// **清完不會立刻重新下載。** 使用者按「清除」的意思是「現在把它清空」，
    /// 若馬上補貨，數字幾秒後就跳回去，看起來像沒清掉——而且會突然打一輪 API
    /// 與 SMB 拷貝。等下一個排程輪次自然補回來就好，桌面上現有的桌布不受影響。
    func clearCache(_ location: CacheLocation) throws {
        guard location.id == "videos" else {
            try location.clearContents()
            return
        }
        // container 要連帳本一起清，否則下次同步會把它們當成孤兒。
        // 下載快取則等 sync 收手後再清，免得兩邊同時動同一批檔案。
        let previous = videoSyncTask
        previous?.cancel()
        videoSyncID += 1
        let generation = videoSyncID
        videoSyncTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.videoSyncID == generation else { return }
            await self.videoLibrary.sync(videos: [])
            try? location.clearContents()
            self.status.videosOverBudget = 0
            self.videoSyncTask = nil
            self.refreshNow()   // 影片沒了 → 那些螢幕改由蒙太奇接管
        }
    }

    /// 設定視窗改了規則就立刻重評一次。
    func sourceRulesDidChange() {
        forceVideoSync = true
        refreshNow()
    }

    var focusModes: [FocusMode] { focus.availableModes }
    var activeFocusModeName: String? { focus.activeModeName }

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
