//  MPVSurface.swift
//  libmpv 那條路。C 指標與 OpenGL 都在 MPVBridge 裡，這裡只有 Swift 物件與事件。
//
//  一台螢幕一個 mpv core 加一個 render context：不同刷新率各自同步，不共用計時器。
//  「哪一支播完了」用 mpv 的 playlist entry id 對，不是 URL——同一支被重播時
//  前後兩輪的 URL 一樣，遲到的事件就分不出是哪一輪的。
//
//  播完之後怎麼辦，跟 AVPlayer 那條路對齊：
//  - 佇列裡有下一支：mpv 自己接上（END_FILE eof → START_FILE），這裡回報
//    `surfaceDidReachEnd`，引擎叫 `adoptPreloaded` 換帳。
//  - 沒有下一支：`keep-open=yes` 讓它停在最後一格（`eof-reached` 變 true、pause 變 yes），
//    同樣回報一次，引擎排下一支。
//  - 單片循環：`loop-file=inf`，不會有任何播完事件。

import AppKit
import FoldwallCore

@MainActor
final class MPVSurface: DesktopPlaybackSurface {

    let core: DesktopPlaybackCore = .mpv
    let uuid: String
    weak var delegate: (any DesktopPlaybackSurfaceDelegate)?
    var view: NSView { glView }

    private let glView: MPVOpenGLView
    private let mpv: MPVCore
    private let renderer: MPVRenderer
    private var loop: Bool
    /// 正在播的 playlist entry。0＝還沒載過。
    private var currentEntry: Int64 = 0
    private var preloaded: (url: URL, entry: Int64)?
    /// 載入後要跳到哪。`start` 選項是每支都套用的，不能用；等 FILE_LOADED 再 seek。
    private var pendingStart: Double?
    /// 這一支的「播完」已經報過了。`eof-reached` 會在幾種情況重複變 true。
    private var endReported = false
    private var lastFailure: String?
    private var waiting = false
    private var isTornDown = false
    private var hwdec: String?

    /// 疊在 `MPVRuntime.playbackOptions` 上的額外選項。**只給 A/B 量測用**
    /// （tools/engine-harness 拿它試 `aid=no` 之類），正式 app 不設。
    static var extraOptions: [String: String] = [:]

    init(uuid: String, frame: NSRect, library: MPVLibraryHandle, loop: Bool) throws {
        self.uuid = uuid
        self.loop = loop
        glView = MPVOpenGLView(frame: frame)
        let options = Dictionary(uniqueKeysWithValues: MPVRuntime.playbackOptions(loop: loop))
            .merging(Self.extraOptions) { _, extra in extra }
        mpv = try MPVCore(library: library, options: options)
        do {
            renderer = try MPVRenderer(core: mpv, view: glView)
        } catch {
            // core 建好了但 render context 不行：core 要自己收掉，不然它會活到行程結束。
            let core = mpv
            DispatchQueue.global(qos: .utility).async { core.destroy() }
            throw error
        }

        // 事件在 core 的 control queue 上來，這裡排回主執行緒。用 main.async 而不是 Task：
        // END_FILE → START_FILE 的順序不能亂，dispatch queue 保證 FIFO。
        mpv.setEventHandler { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        renderer.setFirstFrameHandler { [weak self] in
            MainActor.assumeIsolated { self?.noteFirstFrame() }
        }
        _ = mpv.observeProperty("video-out-params", format: .node)
        _ = mpv.observeProperty("paused-for-cache", format: .flag)
        _ = mpv.observeProperty("eof-reached", format: .flag)
        _ = mpv.observeProperty("hwdec-current", format: .string)
    }

    var canSwitchWhileLooping: Bool { true }

    // MARK: - 載入

    private static func argument(for url: URL) -> String {
        url.isFileURL ? url.path : url.absoluteString
    }

    func load(_ url: URL, location: VideoSourceLocation, loop: Bool, startAt seconds: Double?) {
        guard !isTornDown else { return }
        if loop != self.loop {
            self.loop = loop
            _ = mpv.setString(loop ? "inf" : "no", forProperty: "loop-file")
        }
        // 快取大小照片源決定，跟 AVPlayer 那條的 preferredForwardBufferDuration 同一個判準。
        let cacheSeconds = VideoBufferPolicy.forwardBufferSeconds(for: location)
        _ = mpv.setString(String(format: "%.0f", cacheSeconds), forProperty: "cache-secs")

        endReported = false
        lastFailure = nil
        waiting = false
        pendingStart = if let seconds, seconds.isFinite, seconds > 0 { seconds } else { nil }
        preloaded = nil
        // `replace` 會把整份 playlist 換掉，之前預載的一併清掉。
        currentEntry = command(["loadfile", Self.argument(for: url), "replace"]) ?? 0
        _ = mpv.setFlag(false, forProperty: "pause")   // keep-open 可能把它停在上一支的最後一格
    }

    @discardableResult
    func preload(_ url: URL, location: VideoSourceLocation) -> Bool {
        guard !isTornDown, !loop else { return false }
        if preloaded?.url == url { return true }
        cancelPreload()
        guard let entry = command(["loadfile", Self.argument(for: url), "append"]) else { return false }
        preloaded = (url, entry)
        return true
    }

    func cancelPreload() {
        guard preloaded != nil else { return }
        // 清掉正在播的以外的全部——也就是預載的那支。
        _ = command(["playlist-clear"])
        preloaded = nil
    }

    var hasPreloaded: Bool { preloaded != nil }

    func advanceToPreloaded() {
        guard preloaded != nil else { return }
        _ = command(["playlist-next", "force"])
    }

    func adoptPreloaded() {
        guard let next = preloaded else { return }
        currentEntry = next.entry
        preloaded = nil
        endReported = false
        lastFailure = nil
    }

    func replay() {
        endReported = false
        _ = command(["seek", "0", "absolute+exact"])
        _ = mpv.setFlag(false, forProperty: "pause")
    }

    /// `loop-file` 是可即時改的屬性，不必重建。改成循環時預載的那支要丟掉——
    /// 循環不會走到它，留著只是佔一份 demuxer。
    func setLoop(_ loop: Bool) -> Bool {
        guard !isTornDown else { return false }
        guard loop != self.loop else { return true }
        self.loop = loop
        _ = mpv.setString(loop ? "inf" : "no", forProperty: "loop-file")
        if loop { cancelPreload() }
        return true
    }

    func play() { _ = mpv.setFlag(false, forProperty: "pause") }
    func pause() { _ = mpv.setFlag(true, forProperty: "pause") }

    func setScale(_ applied: VideoScaleMode) {
        _ = mpv.setString(MPVRuntime.panscan(for: applied), forProperty: "panscan")
    }

    var currentSeconds: Double? {
        guard !isTornDown, let value = mpv.double(forProperty: "time-pos")?.doubleValue,
              value.isFinite, value >= 0 else { return nil }
        return value
    }

    var explicitFailure: String? { lastFailure }
    var isWaitingForData: Bool { waiting }

    func diagnosticLines() -> [String] {
        guard !isTornDown else { return [] }
        var lines = ["- " + String(localized: "核心：mpv")]
        if let version = mpv.string(forProperty: "mpv-version") {
            lines.append("- " + String(localized: "載入中的 libmpv：\(version)"))
        }
        let hwdec = mpv.string(forProperty: "hwdec-current") ?? String(localized: "未知")
        // interop 是「解出來的畫格直接留在 GPU 上給 GL 用」；空的就是每格都被拉回 CPU
        // 再上傳一次，CPU 會高一截。兩個都要看。
        let interop = mpv.string(forProperty: "hwdec-interop").flatMap { $0.isEmpty ? nil : $0 }
            ?? String(localized: "無（畫格經過 CPU）")
        lines.append("- " + String(localized: "硬體解碼：\(hwdec)（interop：\(interop)）"))
        if let decoder = mpv.int64(forProperty: "decoder-frame-drop-count")?.int64Value,
           let output = mpv.int64(forProperty: "frame-drop-count")?.int64Value {
            lines.append("- " + String(localized: "掉幀計數（解碼／輸出）：\(decoder)／\(output)"))
        }
        // 這是 render 呼叫數，**不是螢幕實際出畫數**；寫進去只為了看它有沒有在動。
        let rendered = renderer.renderedFrames
        lines.append("- " + String(localized: "render 呼叫數：\(rendered)"))
        return lines
    }

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        delegate = nil
        mpv.setEventHandler(nil)
        // render context 要先於 core 釋放（render.h）。兩個都會等，別在主執行緒做：
        // renderer.shutdown 等最後一次渲染跑完，core.destroy 等 core 收乾淨。
        let renderer = renderer, core = mpv
        DispatchQueue.global(qos: .utility).async {
            renderer.shutdown()
            core.destroy()
        }
    }

    // MARK: - 私有

    /// 下指令；回傳 `playlist_entry_id`（只有 loadfile 有）。失敗記 log。
    private func command(_ arguments: [String]) -> Int64? {
        do {
            let result = try mpv.command(arguments)
            return (result["playlist_entry_id"] as? NSNumber)?.int64Value
        } catch {
            Log.video.error("mpv 指令失敗：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func handle(_ event: MPVEvent) {
        guard !isTornDown else { return }
        switch event.kind {
        case .startFile:
            break

        case .fileLoaded:
            // 「第一格」在這裡才開始等：load／adopt 當下就等的話，換片前的最後一格
            // 被重畫一次也會被算成新的那支的第一格（實測每次接上都記到兩筆）。
            renderer.expectFirstFrame()
            if let seconds = pendingStart {
                pendingStart = nil
                _ = command(["seek", String(format: "%.3f", seconds), "absolute+exact"])
            }

        case .endFile:
            guard event.playlistEntryID == currentEntry else { return }
            switch event.endReason {
            case .endOfFile:
                // 只有佇列裡有下一支時才會走到這裡（keep-open 的情況不會發 END_FILE）。
                reportEndOnce()
            case .error:
                // 讀取、格式、輸出要分開：輸出建不起來是我們的事，不能怪影片。
                let failure = MPVRuntime.classifyPlaybackError(Int(event.errorCode))
                let reason = failure.localizedDescription
                    + (event.errorText.map { "（\($0)）" } ?? "")
                lastFailure = failure.blamesSource ? reason : nil
                delegate?.surface(uuid, didFail: reason, blamesSource: failure.blamesSource)
            case .stop, .quit, .redirect:
                break
            @unknown default:
                break
            }

        case .propertyChange:
            handleProperty(event.propertyName ?? "", value: event.propertyValue)

        case .shutdown:
            break

        @unknown default:
            break
        }
    }

    private func handleProperty(_ name: String, value: Any?) {
        switch name {
        case "eof-reached":
            // keep-open 停在最後一格：沒有下一支，這支播完了。
            if (value as? NSNumber)?.boolValue == true, preloaded == nil { reportEndOnce() }

        case "paused-for-cache":
            guard let flag = (value as? NSNumber)?.boolValue else { return }
            if flag, !waiting {
                waiting = true
                delegate?.surface(uuid, didStall: String(localized: "等快取"))
            } else if !flag, waiting {
                waiting = false
                delegate?.surfaceDidResume(uuid)
            }

        case "hwdec-current":
            // 硬體解碼有沒有真的用上要看得到：掉回軟體解碼是「突然變燙」最常見的原因。
            let current = (value as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard current != hwdec else { return }
            hwdec = current
            if let current, current != "videotoolbox" {
                Log.video.info("mpv 解碼器不是 VideoToolbox：\(current, privacy: .public)")
            }

        case "video-out-params":
            guard let params = value as? [String: Any],
                  let width = (params["dw"] as? NSNumber)?.doubleValue,
                  let height = (params["dh"] as? NSNumber)?.doubleValue,
                  width > 0, height > 0 else { return }
            // dw／dh 是**旋轉前**的顯示尺寸；旋轉是 VO 畫的時候才套上，所以自己換。
            let rotate = (params["rotate"] as? NSNumber)?.intValue ?? 0
            let swapped = rotate % 180 != 0
            delegate?.surface(uuid, didLearnAspect: swapped ? height / width : width / height)

        default:
            break
        }
    }

    private func reportEndOnce() {
        guard !endReported else { return }
        endReported = true
        delegate?.surfaceDidReachEnd(uuid)
    }

    private func noteFirstFrame() {
        guard !isTornDown else { return }
        delegate?.surfaceDidShowFirstFrame(uuid)
    }
}
