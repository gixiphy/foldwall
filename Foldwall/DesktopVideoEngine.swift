//  DesktopVideoEngine.swift
//  用桌面層級的 NSWindow 播影片。每台螢幕一個視窗。
//
//  做法參考 wallpaper-play（MIT）：borderless window 壓在桌面圖示層附近、
//  collectionBehavior 讓它跟著所有 Space、hitTest 回 nil 讓點擊穿透。
//  全部是公開 API——這是它相對於私有 WallpaperExtensionKit 的主要價值。
//
//  沒有拷貝：AVPlayer 直接吃來源 URL，SMB、雲端掛載點、甚至遠端 http 都行。

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
    }

    private var playing: [String: Playing] = [:]

    /// 目前有幾台螢幕在播。
    var activeCount: Int { playing.count }

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
        for entry in playing.values {
            if paused { entry.player.pause() } else { entry.player.play() }
        }
    }

    // MARK: - 私有

    private func start(url: URL, uuid: String, screen: NSScreen, layer: DesktopVideoLayer) {
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true            // 桌布不該出聲
        player.actionAtItemEnd = .none
        let looper = AVPlayerLooper(player: player, templateItem: item)

        let window = DesktopVideoWindow(screen: screen, layer: layer)
        window.playerLayer.player = player
        window.orderFront(nil)
        player.play()

        playing[uuid] = Playing(window: window, player: player, looper: looper, url: url)
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
    }

    private static func screen(for target: DisplayTarget) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDirectDisplayID(number.uint32Value) == target.id
        }
    }
}
