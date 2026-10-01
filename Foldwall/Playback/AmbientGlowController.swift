//  AmbientGlowController.swift
//  一台螢幕的影片環境光：決定什麼時候要算、多久算一次、算完放到哪。
//
//  兩個播放核心共用這一份；各核心只負責兩件事：
//  - `sampler`：給一張目前畫面的縮圖（拿不到、或跟上次一樣就回 nil）。
//  - `onActiveChanged`：環境光開始／停止需要取樣，核心據此掛上或拆掉取幀資源。
//  mpv 那條還要 `onVideoFrameChanged`：它的 OpenGL view 不透明，黑邊是它自己畫的，
//  要把 view 縮成只佔影片那一塊，後面的環境光才露得出來。
//
//  規則（見 AmbientGlow.swift 的設計）：
//  - 只在真的有留白時才算：設定開著、縮放實際是 fit、長寬比跟螢幕不一樣。
//  - 最多每秒 12 次；原片照自己的幀率走。暫停就不取（畫面不會變）。
//  - 被完全遮住時不算。
//  - 「跟隨影片色彩」關掉、或系統開了「減少動態效果」：每支影片取一次色就固定。
//  - 換片後保留舊的光，等新片第一張有效縮圖再換；等太久就收掉，回到黑邊。

import AppKit
import FoldwallCore
import QuartzCore

@MainActor
final class AmbientGlowController {

    /// 放在影片底下、鋪滿整台螢幕的那層。
    let view: PassThroughView

    /// 給一張目前畫面的縮圖。
    var sampler: (() -> AmbientFrame?)?
    /// 開始／停止需要取樣。
    var onActiveChanged: ((Bool) -> Void)?
    /// 影片在 view 座標裡佔的那塊；nil＝沒有留白（或環境光關著），影片鋪滿。
    var onVideoFrameChanged: ((CGRect?) -> Void)?

    private let glowLayer = CALayer()
    private var settings: AmbientGlowSettings = .default
    private var applied: VideoScaleMode = .fill
    private var videoAspect: Double?
    private var isPlaying = false
    /// 這支影片還沒取到第一張。暫停中也要取這一張，否則畫面停著時永遠沒光。
    private var needsFrame = true
    /// 已取過色、不再跟著變（跟隨關掉或減少動態效果）。
    private var frozen = false
    private var videoChangedAt = Date.now
    private var lastFrame: AmbientFrame?
    private var timer: Timer?
    private var reduceMotionObserver: (any NSObjectProtocol)?
    private(set) var isActive = false
    private var lastVideoFrame: CGRect?
    /// 渲染了幾次。診斷用。
    private(set) var renderCount = 0

    /// **只給量測工具用**（tools/engine-harness）：桌布被其他視窗蓋住時照樣取樣，
    /// 並把每次算好的光交出來存檔。正式 app 不設。
    static var harnessIgnoresOcclusion = false
    static var harnessOnRender: ((CGImage) -> Void)?

    /// 每秒最多更新幾次。
    static let maxUpdatesPerSecond: Double = 12
    /// 跟上一張的平均色差小於這個就當作沒變。
    private static let unchangedThreshold: Float = 0.002
    /// 換片後等新片第一張縮圖的上限；超過就收掉舊的光，不要把上一支的顏色留在新片旁邊。
    private static let staleGlowTimeout: TimeInterval = 2

    init(frame: NSRect) {
        view = PassThroughView(frame: frame)
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        glowLayer.frame = view.bounds
        glowLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        glowLayer.contentsGravity = .resize
        // 長邊只有 64 像素的畫布放大到整台螢幕：雙線性放大的平滑正是光暈要的。
        glowLayer.magnificationFilter = .linear
        glowLayer.minificationFilter = .linear
        glowLayer.backgroundColor = NSColor.black.cgColor
        // 每次換圖淡入一點，12 fps 的更新看起來才是連續的光，不是一格一格跳。
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 1.5 / Self.maxUpdatesPerSecond
        glowLayer.actions = ["contents": fade, "bounds": NSNull(), "position": NSNull()]
        view.layer?.addSublayer(glowLayer)
        view.isHidden = true

        reduceMotionObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 關掉「減少動態效果」：從現在起跟著畫面走；打開：停在現在這張。
                self.frozen = !self.followsLive && self.lastFrame != nil
                self.updateTimer()
            }
        }
    }

    // MARK: - 輸入

    func update(settings: AmbientGlowSettings) {
        guard settings != self.settings else { return }
        let followChanged = settings.followsVideo != self.settings.followsVideo
        self.settings = settings
        if followChanged { frozen = !followsLive && lastFrame != nil }
        reevaluate()
        // 拖滑桿時要立刻看到：拿最後一張縮圖重算，不等下一格（暫停或已固定時也是）。
        if isActive, let lastFrame { render(lastFrame) }
    }

    /// 只會是 fill 或 fit。
    func setScale(_ applied: VideoScaleMode) {
        guard applied != self.applied else { return }
        self.applied = applied
        reevaluate()
        if isActive, let lastFrame { render(lastFrame) }
    }

    func setVideoAspect(_ aspect: Double) {
        guard aspect != videoAspect else { return }
        videoAspect = aspect
        reevaluate()
        if isActive, let lastFrame { render(lastFrame) }
    }

    /// 換了一支。長寬比**不清**：新片多半跟舊的一樣，清掉的話每次換片光都會閃一下；
    /// 不一樣的話新的長寬比一兩格內就會來。
    func videoDidChange() {
        needsFrame = true
        frozen = false
        videoChangedAt = .now
        updateTimer()
    }

    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        updateTimer()
    }

    func boundsDidChange() {
        reevaluate()
        if isActive, let lastFrame { render(lastFrame) }
    }

    func teardown() {
        timer?.invalidate()
        timer = nil
        if let reduceMotionObserver { NotificationCenter.default.removeObserver(reduceMotionObserver) }
        reduceMotionObserver = nil
        if isActive { onActiveChanged?(false) }
        isActive = false
        sampler = nil
        onActiveChanged = nil
        onVideoFrameChanged = nil
    }

    func diagnosticLine() -> String {
        guard settings.isEnabled else { return "- " + String(localized: "環境光：關") }
        if !isActive { return "- " + String(localized: "環境光：開，目前沒有留白") }
        let mode = followsLive ? String(localized: "跟隨畫面") : String(localized: "固定配色")
        return "- " + String(localized: "環境光：作用中（\(mode)，已更新 \(renderCount) 次）")
    }

    // MARK: - 私有

    private var followsLive: Bool {
        settings.followsVideo && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var screenAspect: Double {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return 16.0 / 9 }
        return Double(size.width / size.height)
    }

    /// 影片佔的那塊（正規化、原點在左上）。沒有留白就是 nil。
    private var normalizedVideoRect: CGRect? {
        guard settings.isEnabled, applied == .fit, let videoAspect else { return nil }
        return AmbientGlowLayout.videoRect(videoAspect: videoAspect, screenAspect: screenAspect)
    }

    private func reevaluate() {
        let rect = normalizedVideoRect
        let active = rect != nil
        if active != isActive {
            isActive = active
            view.isHidden = !active
            if !active {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                glowLayer.contents = nil
                CATransaction.commit()
            }
            onActiveChanged?(active)
        }
        let bounds = view.bounds
        let frame = rect.map { rect in
            // view 不是 flipped：y 從下往上算。
            CGRect(x: (rect.minX * bounds.width).rounded(),
                   y: ((1 - rect.maxY) * bounds.height).rounded(),
                   width: (rect.width * bounds.width).rounded(),
                   height: (rect.height * bounds.height).rounded())
        }
        if frame != lastVideoFrame {
            lastVideoFrame = frame
            onVideoFrameChanged?(frame)
        }
        updateTimer()
    }

    private func updateTimer() {
        let wanted = isActive && !frozen && (isPlaying || needsFrame)
        if wanted, timer == nil {
            let timer = Timer(timeInterval: 1 / Self.maxUpdatesPerSecond, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !wanted, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    private func tick() {
        guard isActive else { return }
        // 被完全遮住（全螢幕 app 蓋著、切到別的全螢幕 Space）：沒人看得到，不算。
        guard let window = view.window,
              window.occlusionState.contains(.visible) || Self.harnessIgnoresOcclusion else { return }
        guard let frame = sampler?() else {
            if needsFrame, Date.now.timeIntervalSince(videoChangedAt) > Self.staleGlowTimeout,
               glowLayer.contents != nil {
                glowLayer.contents = nil
            }
            return
        }
        // 畫面幾乎沒變（靜態鏡頭、慢慢推的空景）：不重算、不換圖。
        // 門檻約是平均每個色版差半階，肉眼看不出來。
        if !needsFrame, let lastFrame, frame.meanDifference(from: lastFrame) < Self.unchangedThreshold {
            return
        }
        lastFrame = frame
        render(frame)
        needsFrame = false
        if !followsLive { frozen = true }
        updateTimer()
    }

    private func render(_ frame: AmbientFrame) {
        guard let rect = normalizedVideoRect else { return }
        let aspect = screenAspect
        let canvas = AmbientGlowLayout.canvasSize(screenAspect: aspect)
        let rgba = AmbientGlowRenderer.render(frame: frame, videoRect: rect, canvas: canvas,
                                              screenAspect: aspect, settings: settings)
        guard let image = Self.makeImage(rgba, width: canvas.width, height: canvas.height) else { return }
        glowLayer.contents = image
        renderCount += 1
        Self.harnessOnRender?(image)
    }

    private static func makeImage(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}
