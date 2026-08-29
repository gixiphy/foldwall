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
        /// 這支開始播的時間。
        var startedAt: Date
        /// 連續處於「想播但沒資料」的起點；不是那個狀態就是 nil。
        var waitingSince: Date?
        /// 已經播到結尾，停在最後一格等上層排下一支。
        var ended = false
    }

    /// 「明明想播卻拿不到資料」允許持續多久。
    ///
    /// 給得很寬鬆是刻意的：雲端硬碟（Box／iCloud）上的影片要先整支下載下來，
    /// 走 SMB 的非 faststart MP4 要先讀完檔尾的 moov，都可能是好幾分鐘。
    /// 這條線只是為了讓「永遠等不到」的來源最終能被換掉，不是效能門檻。
    private static let waitingTimeout: TimeInterval = 300
    /// 看門狗多久看一次。
    private static let watchdogInterval: TimeInterval = 10

    private var playing: [String: Playing] = [:]
    private var watchdog: Timer?
    /// 被政策暫停時看門狗要閉嘴，不然暫停會被當成卡住。
    private var isPolicyPaused = false
    /// 現在這批 player 是照哪個模式建的。跟 `apply` 傳進來的不一樣就得整批重建。
    private var activeMode: VideoPlaybackMode = .repeatAll

    /// 這支播不動了。上層據此冷卻該 URL 並重新排片。
    var onPlaybackFailed: ((URL, String) -> Void)?

    /// 這支播完了（螢幕 UUID、剛播完的 URL）。上層據此依播放模式排下一支。
    /// 單片循環不會發這個——那條路由 AVPlayerLooper 無縫接回開頭。
    var onVideoEnded: ((String, URL) -> Void)?

    /// 目前有幾台螢幕在播。
    var activeCount: Int { playing.count }

    /// 螢幕 → 正在播的影片。排片時用來沿用，不要每輪重選。
    var playingURLs: [String: URL] { playing.mapValues(\.url) }

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
                current.window.setFrame(screen.frame, display: true)
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
                fail(uuid, entry: entry, reason: reason)
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
                fail(uuid, entry: entry, reason: String(localized: "等資料超過 \(seconds) 秒"))
            }
        }
    }

    private func fail(_ uuid: String, entry: Playing, reason: String) {
        Log.video.error(
            "桌面視窗播放失敗：\(entry.url.lastPathComponent, privacy: .public)－\(reason, privacy: .public)")
        teardown(uuid)
        onPlaybackFailed?(entry.url, reason)
    }

    // MARK: - 私有

    private func start(url: URL, uuid: String, screen: NSScreen, layer: DesktopVideoLayer,
                       mode: VideoPlaybackMode, scale: VideoScaleMode) {
        let item = AVPlayerItem(url: url)
        // 桌布不需要搶時間，寧可等到能順順播再播。緩衝也封頂：來源可能是
        // SMB 上一支幾 GB 的檔，無上限預讀等於拿記憶體換不會有人看的進度。
        item.preferredForwardBufferDuration = 10
        let player = AVQueuePlayer()
        player.isMuted = true            // 桌布不該出聲
        player.automaticallyWaitsToMinimizeStalling = true

        let (looper, endObserver) = load(item: item, into: player, uuid: uuid, url: url, mode: mode)

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
                                endObserver: endObserver, url: url, layer: layer,
                                scale: wanted, applied: applied,
                                aspectObserver: observeAspect(item, uuid: uuid, url: url),
                                startedAt: .now)
        startWatchdogIfNeeded()
        Log.video.info(
            "桌面視窗開始播：\(url.lastPathComponent, privacy: .public)（\(mode.displayName, privacy: .public)）")
    }

    /// 換片，但留著視窗與 player。畫面上停在前一支的最後一格，直到新的第一格解出來——
    /// 比拆掉視窗重建（中間是黑的）好得多。
    ///
    /// **只給沒有 looper 的那條路用**（見 `apply` 裡的條件）。
    private func switchVideo(_ uuid: String, to url: URL, screen: NSScreen,
                             mode: VideoPlaybackMode, scale: VideoScaleMode) {
        guard let entry = playing[uuid] else { return }
        // 舊 item 的播畢通知要先斷掉，否則它會進來把新的那支標成播完的。
        if let observer = entry.endObserver { NotificationCenter.default.removeObserver(observer) }

        let player = entry.player
        player.pause()
        player.removeAllItems()

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 10
        let (looper, endObserver) = load(item: item, into: player, uuid: uuid, url: url, mode: mode)

        entry.window.setFrame(screen.frame, display: true)
        // 隨機縮放是「每支各抽一種」，換片就得重抽——這裡是新的那支。
        // 長寬比也跟著歸零：上一支的比例套在新的那支身上會框錯。
        let wanted = Self.resolve(scale, uuid: uuid, url: url)
        let applied = wanted.resolved(videoAspect: nil, screenAspect: Self.aspect(of: screen))
        entry.window.playerLayer.videoGravity = applied.videoGravity
        entry.aspectObserver?.invalidate()
        playing[uuid] = Playing(window: entry.window, player: player, looper: looper,
                                endObserver: endObserver, url: url, layer: entry.layer,
                                scale: wanted, applied: applied,
                                aspectObserver: observeAspect(item, uuid: uuid, url: url),
                                startedAt: .now)
        if !isPolicyPaused { player.play() }
        Log.video.info("桌面視窗換片：\(url.lastPathComponent, privacy: .public)")
    }

    /// 把片源掛上 player，並按模式決定播完之後怎麼辦。
    ///
    /// 兩條路不能混：`AVPlayerLooper` 會自己無縫接回開頭，播畢通知永遠不會發出來，
    /// 「接下一支」那條就等不到訊號；反過來，單片循環自己 seek(.zero) 會頓一下。
    private func load(item: AVPlayerItem, into player: AVQueuePlayer, uuid: String,
                      url: URL, mode: VideoPlaybackMode)
    -> (AVPlayerLooper?, (any NSObjectProtocol)?) {
        guard mode.advancesAtEnd else {
            player.actionAtItemEnd = .none   // AVPlayerLooper 要求
            return (AVPlayerLooper(player: player, templateItem: item), nil)
        }
        // 播完停在最後一格，等上層排下一支。
        player.actionAtItemEnd = .pause
        player.insert(item, after: nil)
        let observer = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.itemDidEnd(uuid, url: url) }
        }
        return (nil, observer)
    }

    /// 播完了。標記起來、通知上層排下一支。
    ///
    /// 這裡**不自己挑下一支**：挑哪支要看播放模式、要避開別台螢幕正在播的、
    /// 還要看冷卻名單——那些都在上層。引擎只負責回報「這支放完了」。
    private func itemDidEnd(_ uuid: String, url: URL) {
        // 舊 item 的遲到通知：換片之後才送達的那種，不能拿來標記新的那支。
        guard let entry = playing[uuid], entry.url == url, !entry.ended else { return }
        playing[uuid]?.ended = true
        Log.video.info("播畢：\(url.lastPathComponent, privacy: .public)")
        onVideoEnded?(uuid, url)
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

    /// 監看 player 算出來的畫面尺寸。
    ///
    /// `presentationSize` 是**已經套過旋轉**的顯示尺寸（直拍手機影片的 naturalSize
    /// 是橫的，自己讀那個會把長寬比弄反），而且 player 本來就要算它——
    /// 比為了一個長寬比再開一次 asset 讀檔頭便宜得多。
    /// 第一格解出來之前它是 `.zero`，所以這裡只認正的尺寸。
    private func observeAspect(_ item: AVPlayerItem, uuid: String, url: URL)
    -> NSKeyValueObservation {
        item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] _, change in
            guard let size = change.newValue, size.width > 0, size.height > 0 else { return }
            let aspect = Double(size.width / size.height)
            Task { @MainActor [weak self] in
                self?.noteAspect(aspect, uuid: uuid, url: url)
            }
        }
    }

    /// 知道影片多寬多高了 → 「填滿高度／寬度」這時才算得出要 fill 還是 fit。
    private func noteAspect(_ aspect: Double, uuid: String, url: URL) {
        // 遲到的通知：換片之後才送達的那種，不能拿來框新的那支。
        guard let entry = playing[uuid], entry.url == url else { return }
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
        entry.looper?.disableLooping()
        entry.player.pause()
        entry.player.removeAllItems()
        entry.window.playerLayer.player = nil
        entry.window.orderOut(nil)
        entry.window.close()
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
