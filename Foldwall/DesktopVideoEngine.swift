//  DesktopVideoEngine.swift
//  用桌面層級的 NSWindow 播影片。每台螢幕一個視窗。
//
//  做法參考 wallpaper-play（MIT）：borderless window 壓在桌面圖示層附近、
//  collectionBehavior 讓它跟著所有 Space、hitTest 回 nil 讓點擊穿透。
//  全部是公開 API——這是它相對於私有 WallpaperExtensionKit 的主要價值。
//
//  沒有拷貝：AVPlayer 直接吃來源 URL，SMB、雲端掛載點、遠端 http 串流都行。
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

/// 點擊穿透：桌布不該吃掉使用者的滑鼠事件。
private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class DesktopVideoWindow: NSWindow {

    let playerLayer = AVPlayerLayer()

    init(screen: NSScreen, layer: DesktopVideoLayer) {
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
        playerLayer.videoGravity = .resizeAspectFill   // 超寬屏不要黑邊
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
        /// 必須被持有，否則迴圈會停。
        var looper: AVPlayerLooper
        var url: URL
        /// 這支開始播的時間。
        var startedAt: Date
        /// 連續處於「想播但沒資料」的起點；不是那個狀態就是 nil。
        var waitingSince: Date?
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

    /// 這支播不動了。上層據此冷卻該 URL 並重新排片。
    var onPlaybackFailed: ((URL, String) -> Void)?

    /// 目前有幾台螢幕在播。
    var activeCount: Int { playing.count }

    /// 螢幕 → 正在播的影片。排片時用來沿用，不要每輪重選。
    var playingURLs: [String: URL] { playing.mapValues(\.url) }

    /// 讓畫面符合 `plan`：沒在計畫裡的關掉，換片的重建，沒變的留著。
    func apply(plan: [String: URL], layer: DesktopVideoLayer, screens: [DisplayTarget]) {
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
                continue
            }
            teardown(uuid)
            start(url: url, uuid: uuid, screen: screen, layer: layer)
        }
    }

    func stopAll() {
        for uuid in playing.keys { teardown(uuid) }
    }

    /// 降載／睡眠時暫停，但不拆視窗——重新開始時不必再解一次碼。
    func setPaused(_ paused: Bool) {
        isPolicyPaused = paused
        for uuid in playing.keys {
            if paused {
                playing[uuid]?.player.pause()
            } else {
                playing[uuid]?.player.play()
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
                    ?? entry.player.error?.localizedDescription ?? "未知錯誤"
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
                fail(uuid, entry: entry, reason: "等資料超過 \(Int(Self.waitingTimeout)) 秒")
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

    private func start(url: URL, uuid: String, screen: NSScreen, layer: DesktopVideoLayer) {
        let item = AVPlayerItem(url: url)
        // 桌布不需要搶時間，寧可等到能順順播再播。緩衝也封頂：來源可能是
        // SMB 上一支幾 GB 的檔，無上限預讀等於拿記憶體換不會有人看的進度。
        item.preferredForwardBufferDuration = 10
        let player = AVQueuePlayer()
        player.isMuted = true            // 桌布不該出聲
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = true
        let looper = AVPlayerLooper(player: player, templateItem: item)

        let window = DesktopVideoWindow(screen: screen, layer: layer)
        window.playerLayer.player = player
        window.orderFront(nil)
        player.play()

        playing[uuid] = Playing(window: window, player: player, looper: looper,
                                url: url, startedAt: .now)
        startWatchdogIfNeeded()
        Log.video.info("桌面視窗開始播：\(url.lastPathComponent, privacy: .public)")
    }

    private func teardown(_ uuid: String) {
        guard let entry = playing.removeValue(forKey: uuid) else { return }
        entry.looper.disableLooping()
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
