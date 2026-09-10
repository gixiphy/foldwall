//  DesktopVideoEngine.swift
//  用桌面層級的 NSWindow 播影片。每台螢幕一個視窗。
//
//  做法參考 wallpaper-play（MIT）：borderless window 壓在桌面圖示層附近、
//  collectionBehavior 讓它跟著所有 Space、hitTest 回 nil 讓點擊穿透。
//  全部是公開 API——這是它相對於私有 WallpaperExtensionKit 的主要價值。
//
//  沒有拷貝：AVPlayer 直接吃來源 URL，SMB、雲端掛載點、遠端 http 串流都行。
//
//  **一支播完之後怎麼辦有兩種建法，決定在建 player 的當下**（見 VideoPlaybackMode）：
//  單片循環走 AVPlayerLooper（接回開頭是無縫的，自己 seek 會頓一下），
//  其餘模式不能用它——它會自己接回開頭，播畢通知永遠不會發出來。
//  那條路改成播完停在最後一格，回報上層，由上層決定下一支是哪一支：
//  挑哪支要看模式、要避開別台正在播的、還要看冷卻名單，那些都不是引擎的事。
//
//  **播不動要有人知道。** 桌布是無人看管的東西：來源掉線、串流網址失效、檔案壞掉，
//  預設行為就是停在那裡黑畫面，永遠不會自己恢復。所以這裡有一條看門狗，
//  由上層把壞掉那支冷卻、改播別的（見 PlaybackCooldown）。
//
//  **它只認明確的錯誤，不用「停太久」當判斷依據。** 試過那條路，會誤殺：
//  桌布視窗被其他視窗完全遮住時 macOS 判定 occluded 並讓 AVPlayer 停下來、
//  AVPlayerLooper 換片的空檔、系統節流——全都會讓 timeControlStatus 離開 .playing，
//  而畫面其實是好的。唯一沒有歧義的「還在等資料」是
//  `.waitingToPlayAtSpecifiedRate`，只有那個狀態卡太久才算數。

import AppKit
import AVFoundation
import FoldwallCore

extension VideoScaleMode {
    /// 對應的 videoGravity。呼叫端要先化簡：`random` 走 `resolved(seed:)`，
    /// 「填滿高度／寬度」走 `resolved(videoAspect:screenAspect:)`。
    /// 真的漏了就退回填滿（舊行為），不要拿 fatalError 換桌布黑掉。
    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fill, .random, .matchHeight, .matchWidth: .resizeAspectFill
        case .fit: .resizeAspect
        }
    }
}

/// 點擊穿透：桌布不該吃掉使用者的滑鼠事件。
private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class DesktopVideoWindow: NSWindow {

    let playerLayer = AVPlayerLayer()

    init(screen: NSScreen, layer: DesktopVideoLayer, gravity: AVLayerVideoGravity) {
        super.init(contentRect: screen.frame, styleMask: [.borderless],
                   backing: .buffered, defer: false)

        let key: CGWindowLevelKey = layer == .aboveIcons ? .desktopIconWindow : .desktopWindow
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(key)) + 1)

        // .canJoinAllSpaces：影片跟著每個 Space；靜態蒙太奇做不到這件事
        // （那需要私有 CGSSpace API），影片這條反而免費拿到。
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        canBecomeVisibleWithoutLogin = true
        ignoresMouseEvents = true
        hasShadow = false
        canHide = false
        isReleasedWhenClosed = false
        backgroundColor = .black
        isOpaque = true

        let content = PassThroughView(frame: screen.frame)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.frame = content.bounds
        playerLayer.videoGravity = gravity
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        content.layer?.addSublayer(playerLayer)
        contentView = content

        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DesktopVideoEngine {

    private struct Playing {
        var window: DesktopVideoWindow
        var player: AVQueuePlayer
        /// 單片循環才有，而且必須被持有，否則迴圈會停。
        /// 其他模式是 nil——AVPlayerLooper 會自己接回開頭，播完就不會有通知，
        /// 「接下一支」那條路等不到訊號。
        var looper: AVPlayerLooper?
        /// 播到結尾的觀察者。teardown 一定要拔掉，否則換片後舊 item 的通知還會進來。
        var endObserver: (any NSObjectProtocol)?
        var url: URL
        /// 這一支是第幾次播放。**每次 start／換片／播畢前進都 +1。**
        ///
        /// 為什麼不夠用 URL 比對：同一支被重播（池裡只剩它、或隨機又抽到它）時
        /// 前後兩輪的 URL 一樣，遲到的通知就分不出是哪一輪的。
        var session: Int
        /// 片源在哪。決定預讀多少，也是診斷「不定時停一下」的第一個線索。
        var location: VideoSourceLocation
        /// 已經備好、排在佇列裡的下一支。播完就直接接上，不必當場開檔。
        var preloaded: (url: URL, item: AVPlayerItem)?
        /// 視窗是照哪個圖層設定建的。視窗層級只在 init 設得了，改了就得重建視窗。
        var layer: DesktopVideoLayer
        /// 使用者要的縮放，`random` 已經抽定；可能還是「填滿高度／寬度」。
        var scale: VideoScaleMode
        /// 真的設進 layer 的那個（fill 或 fit）。存起來才知道要不要動 layer——
        /// 每輪都寫一次 videoGravity 不會壞，但寫了就看不出「改過」與「沒改」的差別。
        var applied: VideoScaleMode
        /// 影片的寬÷高，**已套用旋轉**。KVO 拿到第一格的畫面尺寸之前是 nil，
        /// 「填滿高度／寬度」在那之前只能先用 fill 頂著。
        var videoAspect: Double?
        /// 監看 `presentationSize` 的 KVO。teardown 要拔掉。
        /// 用 KVO 而不是另外開一次 asset 讀 naturalSize：那等於為了一個長寬比
        /// 再走一趟 SMB／雲端掛載點把檔頭讀一遍，而 player 本來就已經知道了。
        var aspectObserver: NSKeyValueObservation?
        /// 監看 `timeControlStatus`。停頓與恢復的時間點要靠它才量得準——
        /// 每 10 秒醒一次的看門狗只看得到「現在卡著」，看不到一次 800 毫秒的停頓。
        var stateObserver: NSKeyValueObservation?
        /// 監看 `AVPlayerLayer.isReadyForDisplay`：第一格真的出現在畫面上的時刻。
        var readyObserver: NSKeyValueObservation?
        /// 這支開始播的時間。
        var startedAt: Date
        /// 連續處於「想播但沒資料」的起點；不是那個狀態就是 nil。
        var waitingSince: Date?
        /// 已經播到結尾，停在最後一格等上層排下一支。
        var ended = false
        /// 這一支已經就地重建過幾次。**有上限**，否則壞掉的檔會一直重建。
        var rebuildAttempts = 0
        /// 視窗目前的框。只在真的改變時才寫回去——每輪 refresh 都設一次
        /// `setFrame(display: true)` 會逼一次重繪，而多數輪次什麼都沒變。
        var frame: CGRect
    }

    /// 「明明想播卻拿不到資料」允許持續多久。
    ///
    /// 給得很寬鬆是刻意的：雲端硬碟（Box／iCloud）上的影片要先整支下載下來，
    /// 走 SMB 的非 faststart MP4 要先讀完檔尾的 moov，都可能是好幾分鐘。
    /// 這條線只是為了讓「永遠等不到」的來源最終能被換掉，不是效能門檻。
    private static let waitingTimeout: TimeInterval = 300
    /// 看門狗多久看一次。
    private static let watchdogInterval: TimeInterval = 10
    /// 同一支就地重建幾次之後才認定它壞了。
    ///
    /// 給 1 次：掛載磁碟斷一下、串流的 CDN 抽一次風，重建一次就好了；
    /// 真的壞掉的檔重建幾次都一樣，多試只是讓桌布黑得更久。
    private static let maxRebuildAttempts = 1

    private var playing: [String: Playing] = [:]
    private var watchdog: Timer?
    /// 被政策暫停時看門狗要閉嘴，不然暫停會被當成卡住。
    private var isPolicyPaused = false
    /// 現在這批 player 是照哪個模式建的。跟 `apply` 傳進來的不一樣就得整批重建。
    private var activeMode: VideoPlaybackMode = .repeatAll
    /// 發過幾次播放 session。全域遞增，不重複使用。
    private var sessionCounter = 0

    /// 播放事件。兩條引擎記同一種格式（見 PlaybackEvent），診斷報告才拼得起來。
    private(set) var events = PlaybackEventLog()

    /// 這支播不動了。上層據此冷卻該 URL 並重新排片。
    var onPlaybackFailed: ((URL, String) -> Void)?

    /// 這支播完了（螢幕 UUID、剛播完的 URL）。上層據此更新狀態。
    /// 單片循環不會發這個——那條路由 AVPlayerLooper 無縫接回開頭。
    var onVideoEnded: ((String, URL) -> Void)?

    /// **這台螢幕接下來要播哪一支**（螢幕 UUID、正在播的那支）→ 下一支。
    ///
    /// 為什麼引擎要提前問：換片本來是「播完 → 通知上層 → 上層排片 → 開新檔」，
    /// 那一串全部發生在最後一格播完之後，中間的開檔時間就是看得見的停頓——
    /// 走 SMB 或串流時更明顯。改成一開始播就先問好、把下一支排進佇列，
    /// 接縫的成本就只剩 AVQueuePlayer 自己的切換。
    ///
    /// **挑哪一支仍然不是引擎的事**：要看播放模式、要避開別台正在播的、
    /// 還要看冷卻名單。回 nil 就是「沒有下一支」，播完停在最後一格。
    var nextVideoProvider: ((String, URL) -> URL?)?

    /// 目前有幾台螢幕在播。
    var activeCount: Int { playing.count }

    /// 螢幕 → 正在播的影片。排片時用來沿用，不要每輪重選。
    var playingURLs: [String: URL] { playing.mapValues(\.url) }

    /// 正在播的**加上已經預載排隊的**。
    ///
    /// 挑下一支時要避開這一整組，不能只避開正在播的：預載讓每台螢幕提前
    /// 佔住一支，只看 `playingURLs` 的話兩台會各自預載到同一支，等它們先後
    /// 接上去就變成兩台播一樣的——那看起來就是壞的。
    /// - Parameter excluding: 這台螢幕自己的不算。問「我接下來播什麼」時把自己
    ///   算進去的話，答案每問一次就換一個，預載會被反覆換掉。
    func reservedURLs(excluding uuid: String? = nil) -> Set<URL> {
        Set(playing.filter { $0.key != uuid }
            .values
            .flatMap { [$0.url] + ($0.preloaded.map { [$0.url] } ?? []) })
    }

    /// 讓畫面符合 `plan`：沒在計畫裡的關掉，換片的重建，沒變的留著。
    func apply(plan: [String: URL], layer: DesktopVideoLayer, screens: [DisplayTarget],
               mode: VideoPlaybackMode, scale: VideoScaleMode) {
        // 循環方式是**建 player 當下**決定的（走不走 AVPlayerLooper），改不動已經在跑的
        // 那個。所以模式一換就整批重建——這是使用者剛動過手的那一刻，重播一次不突兀。
        if mode != activeMode {
            activeMode = mode
            stopAll()
        }
        let byUUID = Dictionary(uniqueKeysWithValues: screens.map { ($0.uuid, $0) })

        for (uuid, current) in playing where plan[uuid] == nil || byUUID[uuid] == nil {
            teardown(uuid)
            _ = current
        }

        for (uuid, url) in plan {
            guard let target = byUUID[uuid], let screen = Self.screen(for: target) else {
                teardown(uuid)
                continue
            }
            // 同一支繼續播，不要每輪重啟
            if let current = playing[uuid], current.url == url {
                reframe(uuid, to: screen)
                // 縮放改得動已經在播的那個 layer（不像循環方式），所以只設 gravity，
                // 不重建 player：使用者在設定裡試各種縮放時畫面不該一直重播。
                // 螢幕的長寬比也可能剛換（改解析度、換螢幕），一併重算。
                applyScale(scale, to: uuid, url: url, screen: screen)
                // 除非它已經播完了：池裡只有這一支（或隨機又抽到同一支）時，
                // 上層排的下一支就是它自己。從頭再播一次，不要停在最後一格。
                if current.ended { replay(uuid) }
                continue
            }
            // 換片：視窗與 player 留著，只換片源。**重建視窗會閃一下黑的**，
            // 而換片現在是每支播完都會發生的事（不再只有睡醒那一次），
            // 每支之間閃一下黑的，那看起來就是壞的。
            //
            // 只有「播完接下一支」那條路這樣做。單片循環的 player 身上掛著
            // AVPlayerLooper，它的 disableLooping 有沒有立刻把佇列清乾淨沒有保證，
            // 在同一個 player 上接著建第二個 looper 是在賭。那條路換片是使用者
            // 按「下一片」的偶發動作，閃一下換整批重建的確定性，划得來。
            if let current = playing[uuid], current.layer == layer, mode.advancesAtEnd {
                switchVideo(uuid, to: url, screen: screen, mode: mode, scale: scale)
                continue
            }
            teardown(uuid)
            start(url: url, uuid: uuid, screen: screen, layer: layer, mode: mode, scale: scale)
        }
    }

    func stopAll() {
        for uuid in playing.keys { teardown(uuid) }
    }

    /// 降載／睡眠時暫停，但不拆視窗——重新開始時不必再解一次碼。
    func setPaused(_ paused: Bool) {
        let changed = isPolicyPaused != paused
        isPolicyPaused = paused
        // 暫停時看門狗本來就閉嘴（checkHealth 開頭就 return），那就連計時器一起停：
        // 螢幕睡一整晚，沒理由每 10 秒喚醒行程一次去做一個空檢查。
        if paused {
            watchdog?.invalidate()
            watchdog = nil
        } else if !playing.isEmpty {
            startWatchdogIfNeeded()
        }
        for uuid in playing.keys {
            if changed, let entry = playing[uuid] {
                record(.policyChanged, entry: entry, surface: uuid,
                       detail: paused ? "暫停" : "恢復")
            }
            if paused {
                playing[uuid]?.player.pause()
            } else {
                // 播完停在最後一格的那些不要 play()：它們在等上層排下一支，
                // 這裡叫 play 只會讓 rate 空轉，畫面一格也不會動。
                if playing[uuid]?.ended != true { playing[uuid]?.player.play() }
                // 恢復播放＝重新開始計時，不要把暫停那段算進去
                playing[uuid]?.waitingSince = nil
                playing[uuid]?.startedAt = .now
            }
        }
    }

    // MARK: - 診斷

    /// 可匯出的播放報告。**取不到的一律標成未知**，不要拿「播放進度正常」
    /// 當成沒有掉幀——那是兩件事。
    func diagnosticsReport() -> String {
        var lines: [String] = ["# 桌面視窗播放診斷", ""]
        if events.droppedCount > 0 {
            lines.append("（紀錄有上限，較早的 \(events.droppedCount) 則已被擠掉）")
            lines.append("")
        }
        for (uuid, entry) in playing.sorted(by: { $0.key < $1.key }) {
            let stalls = events.stallSummary(surface: uuid)
            lines.append("## 螢幕 \(uuid)")
            lines.append("- 影片：\(entry.url.lastPathComponent)")
            lines.append("- 來源位置：\(entry.location.displayName)")
            lines.append("- 預讀上限：\(Int(VideoBufferPolicy.forwardBufferSeconds(for: entry.location))) 秒")
            lines.append("- 播放 session：\(entry.session)")
            lines.append("- 已播：\(Int(Date.now.timeIntervalSince(entry.startedAt))) 秒")
            lines.append("- 停頓：\(stalls.count) 次，共 \(String(format: "%.1f", stalls.totalSeconds)) 秒"
                + (stalls.unmatched > 0 ? "（另有 \(stalls.unmatched) 次長度未知）" : ""))
            lines.append("- 下一支已預載：\(entry.preloaded?.url.lastPathComponent ?? "無")")
            lines.append("")
        }
        if playing.isEmpty { lines.append("目前沒有螢幕在播影片。"); lines.append("") }
        lines.append("## 事件")
        for event in events.all.suffix(120) {
            let stamp = event.at.formatted(date: .omitted, time: .standard)
            lines.append("- \(stamp) [\(event.surface)#\(event.session)] \(event.kind.rawValue)"
                + (event.detail.map { "：\($0)" } ?? ""))
        }
        return lines.joined(separator: "\n")
    }

    private func record(_ kind: PlaybackEvent.Kind, entry: Playing, surface: String,
                        detail: String? = nil) {
        events.record(PlaybackEvent(
            kind: kind, engine: VideoEngine.desktopWindow.rawValue, surface: surface,
            session: entry.session, sourceKey: entry.url.absoluteString,
            policy: isPolicyPaused ? "paused" : "full", detail: detail))
    }

    // MARK: - 看門狗

    private func startWatchdogIfNeeded() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(
            withTimeInterval: Self.watchdogInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.checkHealth() }
        }
    }

    private func stopWatchdogIfIdle() {
        guard playing.isEmpty else { return }
        watchdog?.invalidate()
        watchdog = nil
    }

    private func checkHealth() {
        guard !isPolicyPaused else { return }
        let now = Date.now

        for (uuid, entry) in playing {
            // 明確失敗：壞檔、網址 404、憑證錯誤都走這裡。這是唯一沒有歧義的訊號。
            if entry.player.currentItem?.status == .failed || entry.player.error != nil {
                let reason = entry.player.currentItem?.error?.localizedDescription
                    ?? entry.player.error?.localizedDescription ?? String(localized: "未知錯誤")
                handleFailure(uuid, entry: entry, reason: reason)
                continue
            }

            // **只有這個狀態算「在等資料」。** `.paused` 不算——被遮住、被節流、
            // 換片空檔都是 .paused，而畫面其實好好的。
            guard entry.player.timeControlStatus == .waitingToPlayAtSpecifiedRate else {
                playing[uuid]?.waitingSince = nil
                continue
            }

            let since = entry.waitingSince ?? now
            playing[uuid]?.waitingSince = since
            if now.timeIntervalSince(since) > Self.waitingTimeout {
                let seconds = Int(Self.waitingTimeout)
                // 等到這個地步不必再重建了——重建改變不了「來源給不出資料」。
                fail(uuid, entry: entry, reason: String(localized: "等資料超過 \(seconds) 秒"))
            }
        }
    }

    /// 分級恢復：先就地重建一次，還是不行才冷卻換片。
    ///
    /// 掛載磁碟斷一下、串流的 CDN 抽一次風，重建一次就好了；把這種暫時性的
    /// 失敗直接送進冷卻名單，等於因為一次網路打嗝就把那支片鎖十分鐘。
    private func handleFailure(_ uuid: String, entry: Playing, reason: String) {
        guard entry.rebuildAttempts < Self.maxRebuildAttempts else {
            fail(uuid, entry: entry, reason: reason)
            return
        }
        guard let screen = entry.window.screen ?? NSScreen.main else {
            fail(uuid, entry: entry, reason: reason)
            return
        }
        playing[uuid]?.rebuildAttempts = entry.rebuildAttempts + 1
        record(.recovered, entry: entry, surface: uuid, detail: "就地重建：\(reason)")
        Log.video.info(
            "桌面視窗就地重建：\(entry.url.lastPathComponent, privacy: .public)－\(reason, privacy: .public)")
        let attempts = entry.rebuildAttempts + 1
        switchVideo(uuid, to: entry.url, screen: screen, mode: activeMode, scale: entry.scale)
        playing[uuid]?.rebuildAttempts = attempts
    }

    private func fail(_ uuid: String, entry: Playing, reason: String) {
        Log.video.error(
            "桌面視窗播放失敗：\(entry.url.lastPathComponent, privacy: .public)－\(reason, privacy: .public)")
        record(.failed, entry: entry, surface: uuid, detail: reason)
        teardown(uuid)
        onPlaybackFailed?(entry.url, reason)
    }

    // MARK: - 私有

    private func makeItem(_ url: URL, location: VideoSourceLocation) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        // 桌布不需要搶時間，寧可等到能順順播再播。**預讀多少看片源在哪**：
        // 本機檔囤 10 秒是拿記憶體換不會用到的進度，而 NAS 或串流 10 秒
        // 擋不住一次網路抽風——那正是「不定時停一下」最可能的來源。
        item.preferredForwardBufferDuration = VideoBufferPolicy.forwardBufferSeconds(for: location)
        return item
    }

    private func start(url: URL, uuid: String, screen: NSScreen, layer: DesktopVideoLayer,
                       mode: VideoPlaybackMode, scale: VideoScaleMode) {
        sessionCounter += 1
        let session = sessionCounter
        let location = VideoBufferPolicy.location(for: url)
        let item = makeItem(url, location: location)
        let player = AVQueuePlayer()
        player.isMuted = true            // 桌布不該出聲
        player.automaticallyWaitsToMinimizeStalling = true

        let (looper, endObserver) = load(item: item, into: player, uuid: uuid, url: url,
                                         mode: mode, session: session)

        let wanted = Self.resolve(scale, uuid: uuid, url: url)
        // 第一格解出來之前不知道影片多寬多高，先用 fill 頂著（＝舊行為，不留黑邊），
        // KVO 一拿到畫面尺寸就改成該有的那個。改 gravity 不必重播。
        let applied = wanted.resolved(videoAspect: nil, screenAspect: Self.aspect(of: screen))
        let window = DesktopVideoWindow(screen: screen, layer: layer,
                                        gravity: applied.videoGravity)
        window.playerLayer.player = player
        window.orderFront(nil)
        player.play()

        playing[uuid] = Playing(window: window, player: player, looper: looper,
                                endObserver: endObserver, url: url, session: session,
                                location: location, preloaded: nil, layer: layer,
                                scale: wanted, applied: applied,
                                aspectObserver: observeAspect(item, uuid: uuid, session: session),
                                stateObserver: observeTimeControl(player, uuid: uuid, session: session),
                                readyObserver: observeReadyForDisplay(window, uuid: uuid, session: session),
                                startedAt: .now, frame: screen.frame)
        if let entry = playing[uuid] { record(.started, entry: entry, surface: uuid) }
        startWatchdogIfNeeded()
        preloadNext(uuid)
        Log.video.info(
            "桌面視窗開始播：\(url.lastPathComponent, privacy: .public)（\(mode.displayName, privacy: .public)、\(location.displayName, privacy: .public)）")
    }

    /// 換片，但留著視窗與 player。畫面上停在前一支的最後一格，直到新的第一格解出來——
    /// 比拆掉視窗重建（中間是黑的）好得多。
    ///
    /// **只給沒有 looper 的那條路用**（見 `apply` 裡的條件）。
    private func switchVideo(_ uuid: String, to url: URL, screen: NSScreen,
                             mode: VideoPlaybackMode, scale: VideoScaleMode) {
        guard let entry = playing[uuid] else { return }

        // 已經備好的就是它：直接接上，不必再開一次檔。
        if entry.preloaded?.url == url, entry.player.items().count > 1 {
            entry.player.advanceToNextItem()
            adoptPreloaded(uuid, screen: screen, scale: scale)
            return
        }

        // 舊 item 的播畢通知要先斷掉，否則它會進來把新的那支標成播完的。
        if let observer = entry.endObserver { NotificationCenter.default.removeObserver(observer) }

        sessionCounter += 1
        let session = sessionCounter
        let player = entry.player
        player.pause()
        player.removeAllItems()

        let location = VideoBufferPolicy.location(for: url)
        let item = makeItem(url, location: location)
        let (looper, endObserver) = load(item: item, into: player, uuid: uuid, url: url,
                                         mode: mode, session: session)

        reframe(uuid, to: screen)
        // 隨機縮放是「每支各抽一種」，換片就得重抽——這裡是新的那支。
        // 長寬比也跟著歸零：上一支的比例套在新的那支身上會框錯。
        let wanted = Self.resolve(scale, uuid: uuid, url: url)
        let applied = wanted.resolved(videoAspect: nil, screenAspect: Self.aspect(of: screen))
        entry.window.playerLayer.videoGravity = applied.videoGravity
        entry.aspectObserver?.invalidate()
        entry.stateObserver?.invalidate()
        entry.readyObserver?.invalidate()
        playing[uuid] = Playing(window: entry.window, player: player, looper: looper,
                                endObserver: endObserver, url: url, session: session,
                                location: location, preloaded: nil, layer: entry.layer,
                                scale: wanted, applied: applied,
                                aspectObserver: observeAspect(item, uuid: uuid, session: session),
                                stateObserver: observeTimeControl(player, uuid: uuid, session: session),
                                readyObserver: observeReadyForDisplay(entry.window, uuid: uuid, session: session),
                                startedAt: .now, frame: entry.frame)
        if let updated = playing[uuid] { record(.switched, entry: updated, surface: uuid) }
        if !isPolicyPaused { player.play() }
        preloadNext(uuid)
        Log.video.info("桌面視窗換片：\(url.lastPathComponent, privacy: .public)")
    }

    /// 把片源掛上 player，並按模式決定播完之後怎麼辦。
    ///
    /// 兩條路不能混：`AVPlayerLooper` 會自己無縫接回開頭，播畢通知永遠不會發出來，
    /// 「接下一支」那條就等不到訊號；反過來，單片循環自己 seek(.zero) 會頓一下。
    private func load(item: AVPlayerItem, into player: AVQueuePlayer, uuid: String,
                      url: URL, mode: VideoPlaybackMode, session: Int)
    -> (AVPlayerLooper?, (any NSObjectProtocol)?) {
        guard mode.advancesAtEnd else {
            player.actionAtItemEnd = .none   // AVPlayerLooper 要求
            return (AVPlayerLooper(player: player, templateItem: item), nil)
        }
        // 佇列裡沒有下一支之前先停在最後一格。`preloadNext` 排進下一支之後
        // 才改成 .advance——`.advance` 配空佇列會讓 currentItem 變成 nil，
        // 那時 AVPlayerLayer 什麼都不顯示，換片的空檔就是一片黑。
        player.actionAtItemEnd = .pause
        player.insert(item, after: nil)
        let observer = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.itemDidEnd(uuid, session: session) }
        }
        return (nil, observer)
    }

    /// 先問好下一支是哪一支，把它排進佇列。
    ///
    /// 這是「換片停頓」的解法：開檔、讀檔頭、解第一格本來全發生在最後一格
    /// 播完之後，走 SMB 或串流時那段就是看得見的黑或凍。提前排進 AVQueuePlayer
    /// 之後，它會自己預先準備，接縫只剩佇列切換。
    private func preloadNext(_ uuid: String) {
        guard let entry = playing[uuid], entry.looper == nil else { return }
        guard let provider = nextVideoProvider,
              let next = provider(uuid, entry.url), next != entry.preloaded?.url else { return }

        // 換過目標就把舊的那個從佇列裡拿掉，不要囤兩支。
        if let stale = entry.preloaded?.item { entry.player.remove(stale) }

        let location = VideoBufferPolicy.location(for: next)
        let item = makeItem(next, location: location)
        entry.player.insert(item, after: nil)
        // 佇列裡真的有東西了，播完才可以往前走。
        entry.player.actionAtItemEnd = .advance
        playing[uuid]?.preloaded = (url: next, item: item)
        Log.video.debug("預載下一支：\(next.lastPathComponent, privacy: .public)")
    }

    /// 播完了。
    ///
    /// 有預載的話 AVQueuePlayer 已經自己接上去了，這裡只是把帳更新過來、
    /// 再排下一支。沒有預載就停在最後一格，通知上層排片（舊行為）。
    ///
    /// 這裡**不自己挑下一支**：挑哪支要看播放模式、要避開別台螢幕正在播的、
    /// 還要看冷卻名單——那些都在上層，由 `nextVideoProvider` 回答。
    private func itemDidEnd(_ uuid: String, session: Int) {
        // 舊 session 的遲到通知：換片之後才送達的那種，不能拿來標記新的那支。
        guard let entry = playing[uuid], entry.session == session, !entry.ended else { return }
        let finished = entry.url

        guard let preloaded = entry.preloaded else {
            playing[uuid]?.ended = true
            record(.loopBoundary, entry: entry, surface: uuid, detail: "沒有下一支，停在最後一格")
            Log.video.info("播畢：\(finished.lastPathComponent, privacy: .public)")
            onVideoEnded?(uuid, finished)
            return
        }

        if let observer = entry.endObserver { NotificationCenter.default.removeObserver(observer) }
        sessionCounter += 1
        let newSession = sessionCounter
        let newObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: preloaded.item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.itemDidEnd(uuid, session: newSession) }
        }
        entry.aspectObserver?.invalidate()
        entry.readyObserver?.invalidate()

        playing[uuid]?.url = preloaded.url
        playing[uuid]?.session = newSession
        playing[uuid]?.location = VideoBufferPolicy.location(for: preloaded.url)
        playing[uuid]?.preloaded = nil
        playing[uuid]?.endObserver = newObserver
        playing[uuid]?.startedAt = .now
        playing[uuid]?.waitingSince = nil
        playing[uuid]?.rebuildAttempts = 0
        playing[uuid]?.videoAspect = nil
        playing[uuid]?.aspectObserver = observeAspect(preloaded.item, uuid: uuid, session: newSession)
        playing[uuid]?.readyObserver = observeReadyForDisplay(entry.window, uuid: uuid,
                                                              session: newSession)
        // 佇列又空了：在排進新的一支之前，播完要停在最後一格而不是變黑。
        entry.player.actionAtItemEnd = .pause
        // 新的那支要重抽縮放（`random` 是每支各抽一種），長寬比也歸零。
        if let screen = entry.window.screen ?? NSScreen.main {
            let wanted = Self.resolve(entry.scale, uuid: uuid, url: preloaded.url)
            let applied = wanted.resolved(videoAspect: nil, screenAspect: Self.aspect(of: screen))
            playing[uuid]?.scale = wanted
            playing[uuid]?.applied = applied
            entry.window.playerLayer.videoGravity = applied.videoGravity
        }

        if let updated = playing[uuid] {
            record(.switched, entry: updated, surface: uuid, detail: "預載接上，無停頓")
        }
        Log.video.info(
            "播畢，接上預載：\(finished.lastPathComponent, privacy: .public) → \(preloaded.url.lastPathComponent, privacy: .public)")
        onVideoEnded?(uuid, finished)
        preloadNext(uuid)
    }

    /// 使用者按「下一片」而下一支剛好就是預載好的那支：直接接上。
    private func adoptPreloaded(_ uuid: String, screen: NSScreen, scale: VideoScaleMode) {
        guard let entry = playing[uuid], let preloaded = entry.preloaded else { return }
        itemDidEnd(uuid, session: entry.session)
        _ = preloaded
        reframe(uuid, to: screen)
        applyScale(scale, to: uuid, url: playing[uuid]?.url ?? entry.url, screen: screen)
        if !isPolicyPaused { entry.player.play() }
    }

    /// 從頭再播一次同一支：上層排的「下一支」就是它自己（池裡只剩這支，
    /// 或隨機又抽到它）。不重建 player，省一次解碼器初始化。
    private func replay(_ uuid: String) {
        guard let entry = playing[uuid] else { return }
        playing[uuid]?.ended = false
        playing[uuid]?.startedAt = .now
        playing[uuid]?.waitingSince = nil
        entry.player.seek(to: .zero)
        if !isPolicyPaused { entry.player.play() }
        preloadNext(uuid)
    }

    /// 視窗的框只在真的變了才寫。
    ///
    /// `setFrame(display: true)` 會逼一次重繪，而 `apply` 每輪都會走到這裡——
    /// 多數輪次螢幕根本沒動。每輪都設一次不但白花力氣，也讓「螢幕真的換了」
    /// 這件事在 log 與除錯時看不出來。
    private func reframe(_ uuid: String, to screen: NSScreen) {
        guard let entry = playing[uuid] else { return }
        guard entry.frame != screen.frame else { return }
        entry.window.setFrame(screen.frame, display: true)
        playing[uuid]?.frame = screen.frame
        Log.video.info("桌面視窗改框：\(uuid, privacy: .public)")
    }

    /// 把縮放套到正在播的那台。已經是這個縮放就不動——寫一次 videoGravity 不貴，
    /// 但每輪 refresh 都碰 layer 會讓「真的改過」在 log 與除錯時看不出來。
    private func applyScale(_ scale: VideoScaleMode, to uuid: String, url: URL,
                            screen: NSScreen) {
        guard let entry = playing[uuid] else { return }
        let wanted = Self.resolve(scale, uuid: uuid, url: url)
        playing[uuid]?.scale = wanted
        let applied = wanted.resolved(videoAspect: entry.videoAspect,
                                      screenAspect: Self.aspect(of: screen))
        guard applied != entry.applied else { return }
        entry.window.playerLayer.videoGravity = applied.videoGravity
        playing[uuid]?.applied = applied
        Log.video.info(
            "影片縮放改為 \(wanted.displayName, privacy: .public)（\(applied.rawValue, privacy: .public)）")
    }

    /// `random` 在這裡抽定：seed 是「螢幕 ＋ 影片」，所以同一支在同一台螢幕上
    /// 每次算出來都一樣，重新排片不會讓播到一半的影片突然換一種縮放。
    /// **「填滿高度／寬度」不在這裡化簡**——那要等長寬比，見 `noteAspect`。
    private static func resolve(_ scale: VideoScaleMode, uuid: String, url: URL)
    -> VideoScaleMode {
        scale.resolved(seed: VideoScaleMode.seed(displayUUID: uuid,
                                                 video: url.absoluteString))
    }

    private static func aspect(of screen: NSScreen) -> Double {
        let size = screen.frame.size
        guard size.height > 0 else { return 1 }
        return Double(size.width / size.height)
    }

    // MARK: - 觀察

    /// 監看 player 算出來的畫面尺寸。
    ///
    /// `presentationSize` 是**已經套過旋轉**的顯示尺寸（直拍手機影片的 naturalSize
    /// 是橫的，自己讀那個會把長寬比弄反），而且 player 本來就要算它——
    /// 比為了一個長寬比再開一次 asset 讀檔頭便宜得多。
    /// 第一格解出來之前它是 `.zero`，所以這裡只認正的尺寸。
    private func observeAspect(_ item: AVPlayerItem, uuid: String, session: Int)
    -> NSKeyValueObservation {
        item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] _, change in
            guard let size = change.newValue, size.width > 0, size.height > 0 else { return }
            let aspect = Double(size.width / size.height)
            Task { @MainActor [weak self] in
                self?.noteAspect(aspect, uuid: uuid, session: session)
            }
        }
    }

    /// 停頓與恢復的時間點。
    ///
    /// **不能只靠看門狗**：它每 10 秒醒一次，看得到「現在卡著」，看不到一次
    /// 800 毫秒的停頓——而使用者回報的「抖一下」多半就是那個量級。
    /// KVO 在狀態轉換的當下就到，量出來的長度才有意義。
    private func observeTimeControl(_ player: AVQueuePlayer, uuid: String, session: Int)
    -> NSKeyValueObservation {
        player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            let status = observed.timeControlStatus
            let reason = observed.reasonForWaitingToPlay?.rawValue
            Task { @MainActor [weak self] in
                self?.noteTimeControl(status, reason: reason, uuid: uuid, session: session)
            }
        }
    }

    private func noteTimeControl(_ status: AVPlayer.TimeControlStatus, reason: String?,
                                 uuid: String, session: Int) {
        guard let entry = playing[uuid], entry.session == session else { return }
        switch status {
        case .waitingToPlayAtSpecifiedRate:
            // 只有「想播但沒資料」算停頓。`.paused` 不算——被遮住、被節流、
            // 換片空檔都是 .paused，而畫面其實好好的。
            guard entry.waitingSince == nil else { return }
            playing[uuid]?.waitingSince = .now
            record(.stalled, entry: entry, surface: uuid, detail: reason ?? "原因未知")
        case .playing:
            if let since = entry.waitingSince {
                let seconds = Date.now.timeIntervalSince(since)
                playing[uuid]?.waitingSince = nil
                record(.resumed, entry: entry, surface: uuid,
                       detail: String(format: "停頓 %.2f 秒", seconds))
            }
        case .paused:
            break
        @unknown default:
            break
        }
    }

    /// 第一格真的出現在畫面上的時刻。`isReadyForDisplay` 是唯一講這件事的訊號——
    /// player 的狀態只說得出「資料夠了」，說不出「已經畫出來了」。
    private func observeReadyForDisplay(_ window: DesktopVideoWindow, uuid: String, session: Int)
    -> NSKeyValueObservation {
        window.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, change in
            guard change.newValue == true else { return }
            Task { @MainActor [weak self] in
                guard let self, let entry = playing[uuid], entry.session == session else { return }
                let seconds = Date.now.timeIntervalSince(entry.startedAt)
                record(.firstFrame, entry: entry, surface: uuid,
                       detail: String(format: "出畫 %.2f 秒", seconds))
            }
        }
    }

    /// 知道影片多寬多高了 → 「填滿高度／寬度」這時才算得出要 fill 還是 fit。
    private func noteAspect(_ aspect: Double, uuid: String, session: Int) {
        // 遲到的通知：換片之後才送達的那種，不能拿來框新的那支。
        guard let entry = playing[uuid], entry.session == session else { return }
        playing[uuid]?.videoAspect = aspect
        guard entry.scale.needsVideoAspect,
              let screen = entry.window.screen ?? NSScreen.main else { return }
        let applied = entry.scale.resolved(videoAspect: aspect,
                                           screenAspect: Self.aspect(of: screen))
        guard applied != entry.applied else { return }
        entry.window.playerLayer.videoGravity = applied.videoGravity
        playing[uuid]?.applied = applied
        Log.video.info(
            "影片長寬比 \(aspect, format: .fixed(precision: 2), privacy: .public)：\(entry.scale.displayName, privacy: .public) → \(applied.rawValue, privacy: .public)")
    }

    private func teardown(_ uuid: String) {
        guard let entry = playing.removeValue(forKey: uuid) else { return }
        if let observer = entry.endObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        entry.aspectObserver?.invalidate()
        entry.stateObserver?.invalidate()
        entry.readyObserver?.invalidate()
        entry.looper?.disableLooping()
        entry.player.pause()
        entry.player.removeAllItems()
        entry.window.playerLayer.player = nil
        entry.window.orderOut(nil)
        entry.window.close()
        events.record(PlaybackEvent(
            kind: .released, engine: VideoEngine.desktopWindow.rawValue, surface: uuid,
            session: entry.session, sourceKey: entry.url.absoluteString))
        stopWatchdogIfIdle()
    }

    private static func screen(for target: DisplayTarget) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDirectDisplayID(number.uint32Value) == target.id
        }
    }
}
