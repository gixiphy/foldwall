//  AVPlayerSurface.swift
//  AVFoundation 那條路。**行為跟抽出來之前一樣**——這是每個人今天在用的核心，
//  抽成 surface 只是為了讓 mpv 能並排放進去，不是為了改它。
//
//  **一支播完之後怎麼辦有兩種建法，決定在 load 的當下**（見 VideoPlaybackMode）：
//  單片循環走 AVPlayerLooper（接回開頭是無縫的，自己 seek 會頓一下），
//  其餘模式不能用它——它會自己接回開頭，播畢通知永遠不會發出來。
//  那條路改成播完停在最後一格，回報上層，由上層決定下一支是哪一支。
//
//  「想播但沒資料」只認 `.waitingToPlayAtSpecifiedRate`。`.paused` 不算——
//  桌布視窗被完全遮住時 macOS 讓 AVPlayer 停下來、換片的空檔、系統節流，
//  全都會讓 timeControlStatus 離開 .playing，而畫面其實是好的。

import AVFoundation
import AppKit
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

@MainActor
final class AVPlayerSurface: DesktopPlaybackSurface {

    let core: DesktopPlaybackCore = .avPlayer
    let uuid: String
    weak var delegate: (any DesktopPlaybackSurfaceDelegate)?
    var view: NSView { container }

    private let container: PassThroughView
    /// 放 playerLayer 的那層，疊在環境光上面。不設底色：「符合螢幕大小」留下的
    /// 黑邊是透明的，底下的環境光（沒開就是 container 的黑底）才露得出來。
    private let videoView: PassThroughView
    private let playerLayer = AVPlayerLayer()
    private let glow: AmbientGlowController
    /// 環境光取幀用。**一個 output 只能掛在一個 item 上**，所以每個 item 各一個；
    /// 掛在哪個 item 用 ObjectIdentifier 記，拆的時候才找得到。
    private var videoOutputs: [ObjectIdentifier: (item: AVPlayerItem, output: AVPlayerItemVideoOutput)] = [:]
    private let player = AVQueuePlayer()
    /// 單片循環才有，而且必須被持有，否則迴圈會停。
    private var looper: AVPlayerLooper?
    /// 正在播的 item；`preloaded` 排在它後面。
    private var current: AVPlayerItem?
    private var preloaded: (url: URL, item: AVPlayerItem)?
    /// 播到結尾的觀察者。換片一定要拔掉，否則舊 item 的通知還會進來。
    private var endObserver: (any NSObjectProtocol)?
    private var aspectObserver: NSKeyValueObservation?
    private var stateObserver: NSKeyValueObservation?
    private var readyObserver: NSKeyValueObservation?
    /// 等 item 準備好才做的 seek。**準備好之前的 seek 會被吞掉**（實測：換核心時
    /// 傳進來的起點被忽略，從頭播），所以掛在 status 上等 readyToPlay。
    private var startObserver: NSKeyValueObservation?
    /// 觀察者是哪一代掛的。換片後舊那代送來的一律不理。
    private var generation = 0

    init(uuid: String, frame: NSRect) {
        self.uuid = uuid
        container = PassThroughView(frame: frame)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        glow = AmbientGlowController(frame: container.bounds)
        container.addSubview(glow.view)
        videoView = PassThroughView(frame: container.bounds)
        videoView.autoresizingMask = [.width, .height]
        videoView.wantsLayer = true
        playerLayer.frame = videoView.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        videoView.layer?.addSublayer(playerLayer)
        container.addSubview(videoView)
        player.isMuted = true            // 桌布不該出聲
        player.automaticallyWaitsToMinimizeStalling = true
        playerLayer.player = player

        glow.sampler = { [weak self] in self?.sampleFrame() }
        glow.onActiveChanged = { [weak self] active in
            if !active { self?.detachVideoOutputs() }
        }
        container.onResize = { [weak self] _ in self?.glow.boundsDidChange() }
    }

    var canSwitchWhileLooping: Bool { false }

    // MARK: - 載入

    private func makeItem(_ url: URL, location: VideoSourceLocation) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        // 桌布不需要搶時間，寧可等到能順順播再播。**預讀多少看片源在哪**：
        // 本機檔囤 10 秒是拿記憶體換不會用到的進度，而 NAS 或串流 10 秒
        // 擋不住一次網路抽風——那正是「不定時停一下」最可能的來源。
        item.preferredForwardBufferDuration = VideoBufferPolicy.forwardBufferSeconds(for: location)
        return item
    }

    func load(_ url: URL, location: VideoSourceLocation, loop: Bool, startAt seconds: Double?) {
        detachObservers()
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
        preloaded = nil
        detachVideoOutputs()
        glow.videoDidChange()

        let item = makeItem(url, location: location)
        current = item
        generation += 1
        let generation = generation

        if loop {
            player.actionAtItemEnd = .none   // AVPlayerLooper 要求
            looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            // 佇列裡沒有下一支之前先停在最後一格。`preload` 排進下一支之後才改成
            // .advance——`.advance` 配空佇列會讓 currentItem 變成 nil，那時
            // AVPlayerLayer 什麼都不顯示，換片的空檔就是一片黑。
            player.actionAtItemEnd = .pause
            player.insert(item, after: nil)
            endObserver = observeEnd(of: item, generation: generation)
        }
        attachObservers(item: item, generation: generation)
        if let seconds, seconds.isFinite, seconds > 0 {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            startObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
                guard observed.status == .readyToPlay else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    startObserver?.invalidate()
                    startObserver = nil
                    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }
    }

    @discardableResult
    func preload(_ url: URL, location: VideoSourceLocation) -> Bool {
        guard looper == nil else { return false }
        if preloaded?.url == url { return true }
        // 換過目標就把舊的那個從佇列裡拿掉，不要囤兩支。
        if let stale = preloaded?.item { player.remove(stale) }
        let item = makeItem(url, location: location)
        player.insert(item, after: nil)
        // 佇列裡真的有東西了，播完才可以往前走。
        player.actionAtItemEnd = .advance
        preloaded = (url, item)
        return true
    }

    func cancelPreload() {
        guard let stale = preloaded?.item else { return }
        player.remove(stale)
        preloaded = nil
        player.actionAtItemEnd = .pause
    }

    var hasPreloaded: Bool { preloaded != nil && player.items().count > 1 }

    func advanceToPreloaded() {
        guard hasPreloaded else { return }
        player.advanceToNextItem()
    }

    func adoptPreloaded() {
        guard let next = preloaded else { return }
        detachObservers()
        current = next.item
        preloaded = nil
        generation += 1
        let generation = generation
        endObserver = observeEnd(of: next.item, generation: generation)
        attachObservers(item: next.item, generation: generation)
        // 佇列又空了：在排進新的一支之前，播完要停在最後一格而不是變黑。
        player.actionAtItemEnd = .pause
        pruneVideoOutputs()
        glow.videoDidChange()
    }

    func replay() {
        let generation = generation
        player.seek(to: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation,
                      self.playerLayer.isReadyForDisplay else { return }
                self.delegate?.surfaceDidShowFirstFrame(self.uuid)
            }
        }
    }

    /// 走不走 AVPlayerLooper 是建的時候決定的；`disableLooping` 有沒有立刻把佇列
    /// 清乾淨沒有保證，在同一個 player 上接著建第二個 looper 是在賭。整批重建。
    func setLoop(_ loop: Bool) -> Bool { false }

    func play() {
        player.play()
        glow.setPlaying(true)
    }

    func pause() {
        player.pause()
        glow.setPlaying(false)
    }

    func setScale(_ applied: VideoScaleMode) {
        playerLayer.videoGravity = applied.videoGravity
        glow.setScale(applied)
    }

    func setAmbientGlow(_ settings: AmbientGlowSettings) {
        glow.update(settings: settings)
    }

    var currentSeconds: Double? {
        let seconds = player.currentTime().seconds
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    /// 明確失敗：壞檔、網址 404、憑證錯誤都走這裡。這是唯一沒有歧義的訊號。
    var explicitFailure: String? {
        guard player.currentItem?.status == .failed || player.error != nil else { return nil }
        return player.currentItem?.error?.localizedDescription
            ?? player.error?.localizedDescription ?? String(localized: "未知錯誤")
    }

    /// **只有這個狀態算「在等資料」。** `.paused` 不算——被遮住、被節流、
    /// 換片空檔都是 .paused，而畫面其實好好的。
    var isWaitingForData: Bool { player.timeControlStatus == .waitingToPlayAtSpecifiedRate }

    func diagnosticLines() -> [String] {
        var lines = ["- " + String(localized: "核心：AVPlayer")]
        if let reason = player.reasonForWaitingToPlay?.rawValue {
            lines.append("- " + String(localized: "等待原因：\(reason)"))
        }
        lines.append(glow.diagnosticLine())
        return lines
    }

    func teardown() {
        detachObservers()
        generation += 1
        looper?.disableLooping()
        looper = nil
        player.pause()
        glow.teardown()
        detachVideoOutputs()
        player.removeAllItems()
        playerLayer.player = nil
        current = nil
        preloaded = nil
        delegate = nil
    }

    // MARK: - 環境光取幀

    /// 正在顯示的那個 item 的最新一格，縮成小圖。output 第一次用到才掛：
    /// 單片循環的 item 是 AVPlayerLooper 複製出來的，預載的那支換上來之前也用不到，
    /// 等它真的變成 currentItem 再掛最省事，也不會漏掉任何一種接法。
    private func sampleFrame() -> AmbientFrame? {
        guard let item = player.currentItem else { return nil }
        let output = videoOutput(for: item)
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        return AmbientFrame(pixels: base, width: CVPixelBufferGetWidth(buffer),
                            height: CVPixelBufferGetHeight(buffer),
                            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), order: .bgra)
    }

    private func videoOutput(for item: AVPlayerItem) -> AVPlayerItemVideoOutput {
        if let existing = videoOutputs[ObjectIdentifier(item)] { return existing.output }
        // 請 AVFoundation 直接縮成 64×64 BGRA 交出來。比例變形沒關係，環境光只看正規化座標。
        //
        // 試過要解碼器原生的 4:2:0 自己取樣：省掉 copyPixelBuffer 當下的轉色縮圖，
        // 但 output 會另外囤一池原尺寸緩衝，每台螢幕多 35 MB，總 CPU 沒有明顯比較低。
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64,
        ])
        item.add(output)
        // 已經不在佇列裡的順手拆掉，不要讓舊 item 被字典握著。
        pruneVideoOutputs()
        videoOutputs[ObjectIdentifier(item)] = (item, output)
        return output
    }

    /// 拆掉已經不在 player 佇列裡的 item 身上的 output。
    private func pruneVideoOutputs() {
        let live = Set(player.items().map(ObjectIdentifier.init))
        for (key, entry) in videoOutputs where !live.contains(key) {
            entry.item.remove(entry.output)
            videoOutputs.removeValue(forKey: key)
        }
    }

    private func detachVideoOutputs() {
        for entry in videoOutputs.values { entry.item.remove(entry.output) }
        videoOutputs.removeAll()
    }

    // MARK: - 觀察

    private func observeEnd(of item: AVPlayerItem, generation: Int) -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                delegate?.surfaceDidReachEnd(uuid)
            }
        }
    }

    private func attachObservers(item: AVPlayerItem, generation: Int) {
        // `presentationSize` 是**已經套過旋轉**的顯示尺寸（直拍手機影片的 naturalSize
        // 是橫的，自己讀那個會把長寬比弄反），而且 player 本來就要算它——
        // 比為了一個長寬比再開一次 asset 讀檔頭便宜得多。第一格解出來之前是 .zero。
        //
        // **看 player 正在播的那個 item，不是傳進來的這個**：單片循環時 AVPlayerLooper
        // 播的是它從樣板複製出來的 item，樣板本身從不進佇列，它的 presentationSize
        // 永遠是 .zero——掛在樣板上的話，單片循環永遠不知道影片長寬比。
        aspectObserver = player.observe(\.currentItem?.presentationSize,
                                        options: [.initial, .new]) { [weak self] _, change in
            guard let size = change.newValue ?? nil, size.width > 0, size.height > 0 else { return }
            let aspect = Double(size.width / size.height)
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                glow.setVideoAspect(aspect)
                delegate?.surface(uuid, didLearnAspect: aspect)
            }
        }
        // 停頓與恢復的時間點。**不能只靠看門狗**：它每 10 秒醒一次，看得到「現在卡著」，
        // 看不到一次 800 毫秒的停頓——而使用者回報的「抖一下」多半就是那個量級。
        stateObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            let status = observed.timeControlStatus
            let reason = observed.reasonForWaitingToPlay?.rawValue
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                switch status {
                case .waitingToPlayAtSpecifiedRate: delegate?.surface(uuid, didStall: reason)
                case .playing: delegate?.surfaceDidResume(uuid)
                case .paused: break
                @unknown default: break
                }
            }
        }
        // 第一格真的出現在畫面上的時刻。`isReadyForDisplay` 是唯一講這件事的訊號——
        // player 的狀態只說得出「資料夠了」，說不出「已經畫出來了」。
        readyObserver = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, change in
            guard change.newValue == true else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                delegate?.surfaceDidShowFirstFrame(uuid)
            }
        }
    }

    private func detachObservers() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        aspectObserver?.invalidate()
        aspectObserver = nil
        stateObserver?.invalidate()
        stateObserver = nil
        readyObserver?.invalidate()
        readyObserver = nil
        startObserver?.invalidate()
        startObserver = nil
    }
}
