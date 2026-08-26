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
        /// 這一輪的池涵蓋幾個不同來源。蒙太奇是輪流從各來源抽的，
        /// 這個數字就是「一張圖最多能有幾種來源」。
        var sourceGroupCount = 0
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
    /// 照片圖庫裡有內容的相簿。設定視窗要用它列勾選項，所以放在這裡而不是各自去抓。
    private(set) var albums: [PhotoAlbum] = []

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let bookmarks: BookmarkStore
    @ObservationIgnored private let pipeline: StillPipeline
    @ObservationIgnored private var folderIndex: FolderIndex!
    @ObservationIgnored private let videoLibrary = VideoLibrary()
    @ObservationIgnored private let remotePool = RemoteSourcePool()
    @ObservationIgnored private let remoteVideoPool = RemoteVideoPool()
    @ObservationIgnored private let photosPool = PhotosPool()
    @ObservationIgnored private let focus = FocusModeMonitor()
    @ObservationIgnored private let aggregate = AggregateFolder()
    @ObservationIgnored private let desktopVideo = DesktopVideoEngine()
    @ObservationIgnored private let playlists = PlaylistService()
    var playlistService: PlaylistService { playlists }
    @ObservationIgnored private var aggregateTask: Task<Void, Never>?
    @ObservationIgnored private var albumsTask: Task<Void, Never>?
    @ObservationIgnored let backup = SettingsBackup()
    /// 播不動的影片先冷卻，不要每輪重新選中同一支。
    @ObservationIgnored private var playbackCooldown = PlaybackCooldown()

    @ObservationIgnored private var scheduler: Scheduler
    @ObservationIgnored private var heartbeat: Timer?
    @ObservationIgnored private var screenDebounce: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var refreshDebounce: Task<Void, Never>?
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
            preparer: Materializer(cacheDirectory: paths.smbCache),
            // 網路來源的授權要求標註作者；本機與相簿沒有出處要標，查不到就是 nil
            credits: CombinedCreditLookup([
                CreditStore(directory: paths.remoteCache),
                CreditStore(directory: paths.remoteVideoCache),
            ])
        )
        // 背景掃描落地時立刻補一輪，不必乾等到下一個間隔。
        // store：上次的索引落地在磁碟上，冷啟動直接接手，不必重掃一次全量才有圖。
        self.folderIndex = FolderIndex(
            store: FolderIndexStore(paths: paths),
            onScanCompleted: { [weak self] in
                Task { @MainActor in self?.refreshSoon("資料夾索引掃完") }
            }
        )
    }

    // MARK: - 生命週期

    func start() {
        observeSystem()
        // 桌面視窗播不動就冷卻那支、立刻改播別的。桌布沒人看著，
        // 少了這條就是停在黑畫面直到有人發現。
        desktopVideo.onPlaybackFailed = { [weak self] url, reason in
            guard let self else { return }
            self.playbackCooldown.recordFailure(url, now: .now)
            self.status.sourceError = "影片播放失敗：\(url.lastPathComponent)－\(reason)"
            self.refreshNow("影片播放失敗")
        }
        // 三個池補到貨就補一輪合成：它們不再擋著 refresh，抓完得有人來收。
        let refill: () -> Void = { [weak self] in self?.refreshSoon("網路／相簿補貨落地") }
        remotePool.onRefilled = refill
        photosPool.onRefilled = refill
        remoteVideoPool.onRefilled = refill
        // 片單解析回來、或按需下載落地 → 池變了，補一輪
        playlists.onChanged = { [weak self] in self?.refreshSoon("片單內容更新") }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // 專注模式沒有公開的變更通知，跟著心跳輪詢（檔案只有幾 KB）
                if self.focus.refresh() { self.refreshNow("專注模式改變") }
                self.syncSettingsTick()
                self.dispatch(.tick(now: .now))
            }
        }
        Task.detached(priority: .utility) { Self.migrateLegacyDownloads() }
        reloadAlbums()
        refreshNow("啟動")   // performRefresh 自己會先解析資料夾

        // 開關關著＝container 應該是空的。這裡順手把上次跑到一半留下的孤兒清掉，
        // 否則沒人會呼叫 sync，那些目錄會永遠佔著磁碟（實測留過 17GB）。
        // 桌面視窗引擎不需要 container 裡的拷貝；關著開關也不需要。
        // 兩種情況都清掉，否則舊版留下的幾百 MB 會一直佔著磁碟。
        if !settings.videoWallpaperEnabled || !settings.videoEngine.needsDeployment {
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
                await self.reloadFolders()
                await self.folderIndex.invalidate(roots: self.folders)
                // 移除資料夾要立刻把該來源的影片清掉，不等 30 分鐘節流
                self.forceVideoSync = true
                self.refreshNow("來源資料夾變動")
            }
        }
    }

    /// 螢幕睡著 → 趁沒人用，把下一批影片拷好。節流仍在（最少 30 分鐘），
    /// 否則螢保停停開開一小時就重拷十輪，走 SMB 會很痛。
    private func screenDidSleep() {
        desktopVideo.setPaused(true)   // 沒人看的時候不必解碼
        guard settings.videoWallpaperEnabled else { return }
        rotateVideosOnNextRefresh = true
        refreshNow("螢幕睡著")
    }

    /// 螢幕亮起 → 只重跑靜態。
    /// **不在這時候拷影片**：那是使用者剛回到電腦前的那一刻，470MB 的 SMB 拷貝
    /// 會直接卡在他臉上。唯一例外是手上一支都沒有——那時不拷就什麼都播不了。
    private func screenDidWake() {
        desktopVideo.setPaused(false)
        if settings.videoEngine.needsDeployment,
           settings.videoWallpaperEnabled, videoLibrary.deployedCount == 0 {
            rotateVideosOnNextRefresh = true
        }
        refreshNow("螢幕喚醒")
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
        refreshNow("改後製")
    }

    /// nil＝自動（依螢幕長邊）。改了立刻重抽，不然要等到下一輪才看得出差別。
    func setPieceCount(_ count: Int?) {
        settings.montagePieceCount = count
        refreshNow("改抽取張數")
    }

    /// 改了立刻重抽：這是看得見的改動，等下一輪才生效會以為沒作用。
    func setShowCredits(_ show: Bool) {
        settings.showCredits = show
        refreshNow("改標註顯示")
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
            refreshNow("取消此螢用影片")   // 取消後立刻補一張蒙太奇回去
        } else {
            settings.videoScreens.insert(display.uuid)
        }
    }

    func isVideoScreen(_ display: DisplayTarget) -> Bool {
        settings.videoScreens.contains(display.uuid)
    }

    var displays: [DisplayTarget] { ScreenBridge.currentDisplays() }

    /// 設定視窗改了來源就立刻重跑一輪。
    ///
    /// 順便把播放失敗的冷卻紀錄清掉：使用者剛動過手，這時候還壓著上次的失敗不放，
    /// 會讓「我明明改好了」看起來沒反應。
    func sourcesDidChange() {
        playbackCooldown = PlaybackCooldown()
        refreshNow("來源清單改變")
    }

    // MARK: - 排程

    private func dispatch(_ event: Scheduler.Event) {
        let action = scheduler.handle(event)
        status.isPaused = scheduler.isPaused
        status.nextDue = scheduler.isPaused ? nil : scheduler.nextDue
        if action == .refresh { refreshNow("排程到期") }
    }

    /// **要 await。** 書籤解析會對每個根做可讀性檢查（SMB＝一次網路往返），
    /// 所以實際工作在背景執行緒上做，主執行緒在這段期間是放開的。
    ///
    /// 但呼叫端不能改成「射後不理」：`folders` 還是空的就往下走，
    /// FolderIndex 會收到 `roots: []`，把整份索引當成「完整的空」清掉——
    /// 連帶把 extension container 裡的影片一起刪了。
    private func reloadFolders() async {
        folders = await bookmarks.resolvedFoldersInBackground()
        status.sourceCount = folders.count
        status.offlineCount = bookmarks.offlineCount
    }

    /// 背景事件專用的合併版本。
    ///
    /// 補貨落地與索引掃完常常在幾十秒內接連發生——三個池（網路圖／網路影片／相簿）
    /// 各補各的，每個補完都叫一輪合成，等於把「從 SMB 拷 10 張原圖 ＋ 寫一張桌布」
    /// 的成本乘上來源數量。實測啟動後 85 秒內合成 4 次就是這樣來的。
    ///
    /// 使用者動作**不走這裡**：按「下一張」要立刻有反應。
    private func refreshSoon(_ reason: StaticString) {
        guard refreshDebounce == nil else { return }   // 這批已經有人排隊了
        refreshDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.refreshCoalesceWindow))
            guard let self else { return }
            self.refreshDebounce = nil
            self.refreshNow(reason)
        }
    }

    /// 背景事件合併的時間窗。取 20 秒是因為三個池補貨的間隔實測在這個量級。
    private static let refreshCoalesceWindow: TimeInterval = 20

    /// - Parameter reason: 是誰要求的。這條管線有二十幾個觸發點，出問題時
    ///   「為什麼又跑了一輪」是第一個要回答的問題，光看合成 log 看不出來。
    private func refreshNow(_ reason: StaticString = "未標示") {
        // 上一輪還在跑就別疊上去，但要記著補一次——背景索引剛好在這時落地的話，
        // 直接丟掉這次請求會讓新掃到的圖等到下一個間隔（間隔設「每天」就是等一天）。
        guard refreshTask == nil else {
            refreshPending = true
            Log.pipeline.info("refresh 排隊（\(reason, privacy: .public)）——上一輪還在跑")
            return
        }
        Log.pipeline.info("refresh 開始（\(reason, privacy: .public)）")
        refreshTask = Task { @MainActor in
            defer {
                refreshTask = nil
                if refreshPending {
                    refreshPending = false
                    refreshNow("補跑排隊的那次")
                }
            }
            await performRefresh()
        }
    }

    private func performRefresh() async {
        await reloadFolders()

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
        // 逐資料夾的用途勾選：只餵給有標記「蒙太奇」的
        let montageRoots = effects.contains(.disableFolders) ? [] : SourceUsageMap.allowedRoots(
            folders, usage: settings.folderUsage, needing: .montage)

        // 照片相簿與網路來源各自有節流，不會每輪都去打 API
        let fromPhotos = effects.contains(.disablePhotos)
            ? [] : photosPool.images(albums: settings.photoAlbums)
        let fromRemote = effects.contains(.disableRemote)
            ? [] : remotePool.images(configs: settings.remoteSources)

        // **依來源分組**送進管線，不攤平。攤平的話張數多的來源會吃掉整張圖：
        // 實測資料夾 693,210 張對網路 538 張，隨機抽 10 張抽到網路的機率是 0.16%。
        //
        // 一定走背景執行緒，而且**分組與過濾合成一趟**：groupByRoot 會丟掉不屬於
        // 任何指定根目錄的檔案，所以不需要先 SourceUsageMap.filter 再 group。
        // 之前是主執行緒上先走一趟 68 萬筆（實測 4.4 秒）再走第二趟——
        // 兩個資料夾用途不同時 filter 的捷徑會失效，App 就每輪卡 4.4 秒。
        let images = index.images
        var groups: [SourcePool.Group] = await Task.detached(priority: .userInitiated) {
            SourcePool.groupByRoot(images, roots: montageRoots)
        }.value
        // 相簿與網路各自的快取是同一個目錄，分不出是哪個相簿／哪個站，各算一組。
        if !fromPhotos.isEmpty { groups.append(.init(id: "照片相簿", urls: fromPhotos)) }
        if !fromRemote.isEmpty { groups.append(.init(id: "網路", urls: fromRemote)) }
        let pool = SourcePool(groups: groups)

        status.photosCount = fromPhotos.count
        status.remoteCount = fromRemote.count
        status.sourceError = remotePool.lastError
        status.poolCount = pool.count
        status.sourceGroupCount = pool.groups.count

        var forVideo = index
        // 影片清單小得多（實測 4,658 對 68 萬），但同一條路徑上保持一致：
        // 也不在主執行緒上走。
        let allVideos = index.videos
        let videoRoots = folders
        let usage = settings.folderUsage
        forVideo.videos = await Task.detached(priority: .userInitiated) {
            SourceUsageMap.filter(allVideos, roots: videoRoots, usage: usage, needing: .video)
        }.value
        status.videoCount = forVideo.videos.count

        if settings.videoEngine.needsDeployment {
            if !effects.contains(.pauseVideo) { syncVideosInBackground(forVideo) }
        } else {
            // 桌面視窗：**不拷貝**，AVPlayer 直接吃來源 URL
            await applyDesktopVideo(candidates: forVideo, effects: effects)
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
            && (settings.videoEngine.needsDeployment
                ? videoLibrary.deployedCount > 0
                : desktopVideo.activeCount > 0)
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
                effect: settings.effect, tier: tier, cycleNonce: cycleNonce,
                pieceCountOverride: settings.montagePieceCount,
                showCredits: settings.showCredits
            )
            status.poolWasEmpty = outcome.poolWasEmpty
            // os.Logger 的字串是 OSLogMessage 字面量，不能用 + 串
            Log.pipeline.info("已更新 \(outcome.written.count) 螢，跳過 \(outcome.skipped.count) 螢，池 \(pool.count) 張／\(pool.groups.count) 個來源")
            syncAggregateFolder()
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

        // 網址下載的影片現在就存在 remoteVideoPool 的快取目錄裡，
        // 由 runVideoRotation 那邊的 remote 一起帶進來，不必也不能在這裡再列一次。
        runVideoRotation(folderVideos: index.videos)
    }

    /// 選片與下載都在**這條背景線**上：網路影片一支幾十 MB，
    /// 放進 performRefresh 就等於又把靜態管線擋住了。
    private func runVideoRotation(folderVideos: [URL]) {
        videoSyncID += 1
        let generation = videoSyncID
        videoSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let remote = self.remoteVideoPool.videos(configs: self.settings.remoteSources)
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
            self.refreshNow("影片同步完成")
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
            refreshNow("影片開關打開")
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
            self.refreshNow("影片同步完成")
        }
    }

    /// 桌面視窗引擎：算出哪台螢幕播哪一支，然後讓畫面符合它。
    private func applyDesktopVideo(candidates index: FolderIndex.Snapshot, effects: RuleEffect) async {
        guard settings.videoWallpaperEnabled, !effects.contains(.pauseVideo) else {
            desktopVideo.stopAll()
            return
        }

        let displays = ScreenBridge.currentDisplays()
        let marked = displays.filter { settings.videoScreens.contains($0.uuid) }
        guard !marked.isEmpty else {
            desktopVideo.stopAll()
            return
        }

        // 網路影片一併納入：AVPlayer 播得動本機檔，也播得動已下載的快取
        let remote = remoteVideoPool.videos(configs: settings.remoteSources)
        // 片單：解析清單不下載，**抽到哪支才抓哪支**。這裡只放已經在磁碟上的；
        // 抽不到就代表還沒抓過，下面會挑一支去抓，抓好下一輪自然會被選中。
        playlists.refreshIfNeeded(settings.playlistSources)
        // remote 已經涵蓋網址下載的那些（同一個快取目錄），不要再加一次。
        // playlists 的檔案也在那個目錄裡，所以用 Set 去重。
        var seen = Set<URL>()
        let candidates = (index.videos + remote
                          + playlists.candidates(for: settings.playlistSources))
            .filter { seen.insert($0).inserted }
        // 播不動的先擱著。全部都在冷卻中時 filter 會原樣放行——
        // 一支會壞的影片好過空池換來的黑畫面。
        let pool = playbackCooldown.filter(candidates, now: .now)
        guard !pool.isEmpty else {
            desktopVideo.stopAll()
            return
        }

        // 影片**不跟著蒙太奇換**。只有螢幕重新亮起（或使用者動作）才換一批；
        // 其餘時候正在播的那支只要還在池裡就繼續播。
        // 少了這道，池一有風吹草動（下載落地、快取淘汰、重掃）影片就被換掉重播。
        let screens = marked.map(\.uuid)
        let plan: [String: URL]
        if rotateVideosOnNextRefresh {
            rotateVideosOnNextRefresh = false
            settings.videoRotationCursor &+= 1
            plan = VideoPlaybackPlan.assign(
                screens: screens, videos: pool, cycle: settings.videoRotationCursor)
        } else {
            plan = VideoPlaybackPlan.keeping(
                current: desktopVideo.playingURLs, screens: screens,
                videos: pool, cycle: settings.videoRotationCursor)
        }
        desktopVideo.apply(plan: plan, layer: settings.desktopVideoLayer, screens: displays)
        desktopVideo.setPaused(currentTier() == .paused)

        // 池裡的片單影片不夠讓每台螢幕各播一支 → 補抓一支。
        // 這就是「抽到要顯示才下載」：需求量由螢幕數決定，不是把整個片單抓下來。
        requestPlaylistDownloadIfNeeded(wanted: screens.count)
    }

    /// 片單有東西可播了嗎；不夠就抓一支。
    ///
    /// **一次只抓一支**（PlaylistService 自己也有同時下載上限）：桌布不急，
    /// 而片單可能有幾百支、幾十 GB。抓好的那支下一輪就會被選中，
    /// 不夠再抓下一支——磁碟用量跟「真的播過幾支」成正比。
    private func requestPlaylistDownloadIfNeeded(wanted: Int) {
        let sources = settings.playlistSources.filter(\.isEnabled)
        guard !sources.isEmpty else { return }
        guard playlists.candidates(for: sources).count < max(1, wanted) else { return }
        guard let next = playlists.pending(for: sources).first else { return }
        playlists.requestDownload(next)
    }

    /// 把 0.5.1 以前存在 `~/Movies/Foldwall` 的下載影片搬進影片快取。
    ///
    /// 只搬不刪：同名就加序號。搬完把空目錄收掉，免得使用者在 Finder 裡
    /// 看到一個永遠不會再更新的資料夾。
    nonisolated private static func migrateLegacyDownloads() {
        let fm = FileManager.default
        let old = AppPaths.standard().legacyDownloadedVideos
        let new = AppPaths.standard().remoteVideoCache
        guard let entries = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)
        else { return }

        let videos = entries.filter {
            MediaIndexer.videoExtensions.contains($0.pathExtension.lowercased())
        }
        guard !videos.isEmpty else {
            try? fm.removeItem(at: old)   // 空的就收掉
            return
        }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)

        var moved = 0
        for video in videos {
            var destination = new.appending(path: video.lastPathComponent)
            var suffix = 1
            while fm.fileExists(atPath: destination.path(percentEncoded: false)) {
                let stem = video.deletingPathExtension().lastPathComponent
                destination = new.appending(path: "\(stem)-\(suffix).\(video.pathExtension)")
                suffix += 1
            }
            if (try? fm.moveItem(at: video, to: destination)) != nil { moved += 1 }
        }
        if moved > 0 {
            Log.video.notice("已把 \(moved, privacy: .public) 支下載影片搬進影片快取")
        }
        // 只有真的全搬完才收掉目錄——removeItem 對非空目錄會失敗，剛好當保險
        try? fm.removeItem(at: old)
    }

    /// 切換引擎：把另一條路留下的東西收乾淨，不要兩套同時在畫面上。
    func videoEngineDidChange() {
        desktopVideo.stopAll()
        if settings.videoEngine.needsDeployment {
            forceVideoSync = true
            rotateVideosOnNextRefresh = true
        } else {
            // 換到桌面視窗就不需要 container 裡那幾份拷貝了
            runVideoSync(videos: [])
        }
        refreshNow("改影片引擎")
    }

    /// 把三個快取的圖彙整成一個實體資料夾，讓系統的螢幕保護程式指得到。
    /// 全程在背景：要走三個目錄、建連結、清斷鏈，不能擋著主執行緒。
    private func syncAggregateFolder() {
        guard aggregateTask == nil else { return }
        let paths = AppPaths.standard()
        let aggregate = self.aggregate
        aggregateTask = Task { @MainActor [weak self] in
            defer { self?.aggregateTask = nil }
            let outcome = await Task.detached(priority: .utility) {
                try? aggregate.sync(sources: paths.aggregateSources, into: paths.aggregateFolder)
            }.value
            guard let outcome, outcome.linked > 0 || outcome.pruned > 0 else { return }
            Log.sources.info("彙整資料夾：新增 \(outcome.linked, privacy: .public) 個連結，清掉 \(outcome.pruned, privacy: .public) 個")
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
            // 連結指向的原檔沒了 → 立刻收掉，否則硬連結會讓那些 inode 一直活著，
            // 磁碟空間根本沒釋放。
            syncAggregateFolder()
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
            self.refreshNow("影片快取清空")   // 影片沒了 → 那些螢幕改由蒙太奇接管
        }
    }

    /// 改了資料夾用途就立刻重跑：勾掉影片時要讓那些影片從 container 消失。
    func folderUsageDidChange() {
        forceVideoSync = true
        rotateVideosOnNextRefresh = true
        refreshNow("改資料夾用途")
    }

    /// 相簿清單要授權後才拿得到；設定視窗按了「請求授權」之後會回頭叫這個。
    ///
    /// **在背景列舉。** 這份清單只有設定視窗的勾選欄要用，卻要走遍整個照片圖庫
    /// （實測十萬張的圖庫是好幾秒）。放在啟動路徑上同步跑，那幾秒選單列是點不開的。
    func reloadAlbums() {
        guard PhotosAlbumSource.authorizationStatus == .authorized
                || PhotosAlbumSource.authorizationStatus == .limited else {
            albums = []
            return
        }
        guard albumsTask == nil else { return }   // 上一輪還在列就別疊上去
        albumsTask = Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .utility) {
                PhotosAlbumSource.albums()
            }.value
            guard let self else { return }
            self.albums = found
            self.albumsTask = nil
        }
    }

    // MARK: - 設定備份／iCloud 同步

    /// 目前設定的可搬移快照。
    ///
    /// `folders` 存路徑而不是 bookmark、相簿連名稱一起存——理由見 SettingsSnapshot。
    func settingsSnapshot() -> SettingsSnapshot {
        let albumsByID = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0.title) })
        return SettingsSnapshot(
            savedAt: .now,
            deviceName: Host.current().localizedName ?? "未命名 Mac",
            folders: folders.map(Self.plainPath),
            folderUsage: settings.folderUsage,
            // 相簿清單是背景列舉的，還沒回來時查不到名稱——那就只帶 id，
            // 至少同機還原是對的。
            albums: settings.photoAlbums.sorted().map {
                SettingsSnapshot.Album(id: $0, title: albumsByID[$0] ?? "")
            },
            remoteSources: settings.remoteSources,
            playlistSources: settings.playlistSources,
            sourceRules: settings.sourceRules,
            intervalMinutes: settings.intervalMinutes,
            effect: settings.effect.rawValue,
            montagePieceCount: settings.montagePieceCount,
            videoWallpaperEnabled: settings.videoWallpaperEnabled,
            videoEngine: settings.videoEngine,
            desktopVideoLayer: settings.desktopVideoLayer,
            videoScreens: Array(settings.videoScreens).sorted(),
            launchAtLogin: settings.launchAtLogin
        )
    }

    /// 目錄 URL 的 `path(percentEncoded:)` 會帶結尾斜線，兩邊表示法不一致就會
    /// 判成不同的資料夾（FolderIndex 踩過同一個坑）。統一剝掉。
    private static func plainPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    @discardableResult
    func backupSettingsToICloud() -> Bool {
        backup.export(settingsSnapshot())
    }

    @discardableResult
    func restoreSettingsFromICloud() -> Bool {
        guard let snapshot = backup.load() else { return false }
        apply(snapshot)
        backup.didApply(settingsSnapshot())
        return true
    }

    /// 套用一份快照。順序有講究：先把資料夾接回來（那要重建 bookmark），
    /// 再套其他設定，最後才一次性重掃——中間每改一個欄位就重掃是浪費。
    private func apply(_ snapshot: SettingsSnapshot) {
        let existing = Set(folders.map(Self.plainPath))
        bookmarks.addFolders(paths: snapshot.folders.filter { !existing.contains($0) })

        settings.folderUsage = snapshot.folderUsage
        settings.remoteSources = snapshot.remoteSources
        settings.playlistSources = snapshot.playlistSources
        settings.sourceRules = snapshot.sourceRules
        settings.intervalMinutes = snapshot.intervalMinutes
        settings.effect = PostProcess(rawValue: snapshot.effect) ?? settings.effect
        settings.montagePieceCount = snapshot.montagePieceCount
        settings.videoEngine = snapshot.videoEngine
        settings.desktopVideoLayer = snapshot.desktopVideoLayer
        settings.videoScreens = Set(snapshot.videoScreens)
        settings.launchAtLogin = snapshot.launchAtLogin
        settings.photoAlbums = Self.matchAlbums(snapshot.albums, against: albums)

        // 這個開關會動到 extension container（幾十 GB 的拷貝），走它自己那條路。
        if settings.videoWallpaperEnabled != snapshot.videoWallpaperEnabled {
            settings.videoWallpaperEnabled = snapshot.videoWallpaperEnabled
            videoWallpaperEnabledDidChange()
        }

        scheduler = Scheduler(intervalMinutes: settings.intervalMinutes, now: .now)
        forceVideoSync = true
        Task { @MainActor in
            await self.reloadFolders()
            await self.folderIndex.invalidate(roots: self.folders)
            self.refreshNow("匯入設定")
        }
    }

    /// id 優先（同機還原），比不到再比名稱（跨機——localIdentifier 每台不同）。
    /// 兩邊都比不到就丟掉：那台機器根本沒有這個相簿。
    static func matchAlbums(
        _ wanted: [SettingsSnapshot.Album], against available: [PhotoAlbum]
    ) -> Set<String> {
        let ids = Set(available.map(\.id))
        var byTitle: [String: String] = [:]
        for album in available where byTitle[album.title] == nil {
            byTitle[album.title] = album.id
        }

        var result: Set<String> = []
        for album in wanted {
            if ids.contains(album.id) {
                result.insert(album.id)
            } else if !album.title.isEmpty, let matched = byTitle[album.title] {
                result.insert(matched)
            }
        }
        return result
    }

    /// 心跳上的一拍。**遠端優先**：同一拍裡兩邊都變了就以遠端為準，
    /// 套用完本機快照就等於遠端那份，也就不會再寫回去。
    private func syncSettingsTick() {
        guard settings.iCloudSyncEnabled, backup.isAvailable else { return }

        let snapshot = settingsSnapshot()
        if backup.hasNewerRemote() {
            // 每次啟動的第一拍一定會走到這裡（還沒有比較基準）。內容一樣就只是
            // 記下基準，不要真的套用——套用會連帶重跑一輪合成，而什麼都沒變。
            if let remote = backup.peekRemote(), remote.hasSameContent(as: snapshot) {
                backup.didApply(snapshot, quietly: true)
                return
            }
            _ = restoreSettingsFromICloud()
            return
        }
        if backup.hasLocalChanges(comparedTo: snapshot) {
            backup.export(snapshot)
        }
    }

    /// 使用者剛把自動同步打開：立刻推一份上去當基準，
    /// 不然要等到下一次設定變動才會有東西。
    func iCloudSyncDidChange() {
        guard settings.iCloudSyncEnabled else { return }
        backupSettingsToICloud()
    }

    /// 設定視窗改了規則就立刻重評一次。
    func sourceRulesDidChange() {
        forceVideoSync = true
        refreshNow("改狀態規則")
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
