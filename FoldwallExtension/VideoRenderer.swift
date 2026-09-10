import AVFoundation
import CoreMedia
import ObjectiveC
import os

/// Call AVSampleBufferDisplayLayer's private `_setDisallowsVideoLayerDisplayCompositing:`
/// (a BOOL setter Apple's WallpaperExtensionKit uses on every AVSBDL). Resolved via the
/// ObjC runtime so the private selector never appears in a header; a no-op if the API
/// ever disappears. Prevents the layer painting opaque black before its first frame.
private func setDisallowsVideoLayerDisplayCompositing(_ layer: CALayer, _ flag: Bool) {
    let sel = NSSelectorFromString("_setDisallowsVideoLayerDisplayCompositing:")
    guard layer.responds(to: sel),
          let imp = class_getMethodImplementation(type(of: layer), sel) else { return }
    typealias SetBoolFn = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
    unsafeBitCast(imp, to: SetBoolFn.self)(layer, sel, ObjCBool(flag))
}

final class VideoRenderer: @unchecked Sendable {
    /// Process-wide instance counter so log lines can be attributed to a specific
    /// renderer object (to catch stale/duplicate renderers from acquire races).
    private static let idCounter = OSAllocatedUnfairLock(initialState: 0)
    let debugID: Int = VideoRenderer.idCounter.withLock { $0 += 1; return $0 }

    let displayLayer: AVSampleBufferDisplayLayer
    let timebase: CMTimebase
    private let renderer: AVSampleBufferVideoRenderer
    private let stillFrameLayer: CALayer
    private var asset: AVURLAsset
    private var videoTrack: AVAssetTrack
    private let queue = DispatchQueue(label: "video-renderer", qos: .userInitiated)
    private var isRunning = true
    private(set) var isPaused = false
    private var currentPolicy: PlaybackPolicy = .full
    private var rampTimer: (any DispatchSourceTimer)?
    private var deepPauseTimer: (any DispatchSourceTimer)?

    /// Asset/track loading, kept OFF `queue`. `queue` is the feed loop's queue, and a
    /// blocking track load there stalls sample delivery for as long as the load takes —
    /// on a NAS that is the visible "switch takes a moment" stutter. Only the (cheap,
    /// non-blocking) install hops back onto `queue`.
    private let loadQueue = DispatchQueue(label: "video-renderer-load", qos: .utility)

    private var currentReader: AVAssetReader?
    private var currentOutput: AVAssetReaderTrackOutput?
    private var nextReader: AVAssetReader?
    private var nextOutput: AVAssetReaderTrackOutput?
    /// Track timing for the preloaded next reader, handed to the timeline at the swap.
    private var nextTiming: VideoTrackTiming = .unknown
    /// The preloaded reader has actually been told to start reading — the difference
    /// between "a reader object exists" and "it is filling its queue". Preloading while
    /// paused would defeat the read-ahead cap, so a paused install defers the start.
    private var nextReaderStarted = false

    /// Playback session. Bumped by EVERY path that resets the pipeline (switch, error
    /// recovery, deep-pause wake, stop), and captured by every async continuation —
    /// flush completions, the off-queue asset load, the feed loop's own callback. A
    /// continuation whose generation is stale returns without touching anything, so a
    /// late callback from a superseded switch can never restart playback on top of a
    /// newer one.
    private var generation = 0

    /// Per-switch token. Bumped by every `switchVideo` request so the last REQUESTED
    /// pick wins even when two loads are in flight at once.
    private var switchRequestID = 0
    /// A switch whose asset load hasn't landed yet. Only used to defuse the dedup
    /// check — otherwise a re-pick of the currently playing file while a switch is in
    /// flight would look like a no-op and the surface would stay on the wrong video.
    private var pendingSwitchURL: URL?

    /// A renderer `flush` (decoder reset) is the one async hop in the pipeline, and
    /// TWO overlapping flushes corrupt the renderer (rapid-switch breakage). These two
    /// fields — touched ONLY on `queue` — serialize it: at most one flush is ever in
    /// flight, and a reset arriving during a flush is coalesced, so when the flush
    /// completes we restart once, to the latest selected asset, with the merged intent.
    ///
    /// **Every path that needs a decoder reset goes through here** — switch, error
    /// recovery and deep-pause wake alike. Error recovery used to call `flush` directly,
    /// which is exactly the second overlapping flush this gate exists to prevent.
    private var flushInFlight = false
    private var pendingReset: ResetRequest?

    /// What a pipeline reset should do. Two orthogonal bits, so that coalescing two
    /// requests is just an OR — no priority table to get wrong.
    private struct ResetRequest: Equatable {
        /// Timeline goes back to 0 (a different video, or a hard error reset), rather
        /// than continuing from where the timebase was paused.
        var restartFromZero: Bool
        /// Drop the frame currently on screen. Only error recovery wants this — a
        /// switch keeps the last frame so the swap has no blank.
        var clearDisplayedImage: Bool

        static let newAsset = ResetRequest(restartFromZero: true, clearDisplayedImage: false)
        static let errorReset = ResetRequest(restartFromZero: true, clearDisplayedImage: true)
        static let wake = ResetRequest(restartFromZero: false, clearDisplayedImage: false)

        func merged(with other: ResetRequest) -> ResetRequest {
            ResetRequest(
                restartFromZero: restartFromZero || other.restartFromZero,
                clearDisplayedImage: clearDisplayedImage || other.clearDisplayedImage)
        }
    }

    /// Diagnostic: number of remaining feed-loop ticks to log after a restart.
    private var feedLogBudget = 0

    /// The continuous output timeline this renderer feeds the display layer.
    /// Every PTS/DTS adjustment, loop boundary and resume position goes through it.
    /// Touched ONLY on `queue`.
    private var timeline = LoopTimeline()

    /// Consecutive failed recovery attempts. Reset by any loop that actually produced
    /// frames. Bounded so a permanently broken file can't spin the appex forever.
    private var recoveryAttempts = 0
    /// Consecutive loops that read zero samples. A reader that opens fine but yields
    /// nothing would otherwise turn the loop boundary into a tight spin.
    private var emptyLoops = 0

    private static let maxRecoveryAttempts = 3
    private static let recoveryBackoff: TimeInterval = 3
    private static let maxEmptyLoops = 3

    /// This renderer cannot play its asset any more (URL, reason). The host retargets
    /// the surface to another video — without it a broken file leaves the surface on a
    /// frozen frame with nobody informed, which is what the desktop engine's watchdog
    /// already avoids on its side.
    var onPlaybackFailed: (@Sendable (URL, String) -> Void)?

    /// Called at each loop boundary to select the video URL for the next iteration.
    var variantSelector: (@Sendable () -> URL)?

    /// The user's scale choice, plus everything needed to settle it: which video it
    /// applies to (`random` draws per video), the video's display aspect ratio and the
    /// surface's. Locked because it is read from the prefs (Darwin notification) thread
    /// as well as from `queue` — `asset` itself is only safe to touch on `queue`.
    private struct Scale {
        var mode: VideoScaleMode
        var url: URL
        /// Width ÷ height AFTER the track's preferred transform (a portrait phone video
        /// has a landscape naturalSize; using it raw flips the ratio). nil until loaded.
        var videoAspect: Double?
        var screenAspect: Double

        /// The concrete mode to hand to the layers: `random` drawn for this video,
        /// then "scale to height/width" reduced against the two aspect ratios.
        var settled: VideoScaleMode {
            mode.resolved(seed: url.path)
                .resolved(videoAspect: videoAspect, screenAspect: screenAspect)
        }
    }

    private let scaleState: OSAllocatedUnfairLock<Scale>

    /// Apply a new scale choice to this renderer's layers. Cheap — a gravity write, no
    /// decoder work — so the change lands on the playing video, not the next one.
    /// Returns the concrete mode used (`random` drawn for this video, "scale to height/
    /// width" reduced against the two aspect ratios), which the caller applies to the
    /// root layer so the still underneath frames the same way.
    @discardableResult
    func applyScaleMode(_ mode: VideoScaleMode) -> VideoScaleMode {
        let resolved = scaleState.withLock { state -> VideoScaleMode in
            state.mode = mode
            return state.settled
        }
        setGravity(resolved)
        return resolved
    }

    /// Re-settle the scale for a video we just switched to: `random` draws per video and
    /// the aspect ratio belongs to the old one, so both are reset here. The new ratio
    /// arrives asynchronously (`loadAspect`); until it does, "scale to height/width"
    /// falls back to fill. Call on `queue`.
    private func rescale(for url: URL) {
        let resolved = scaleState.withLock { state -> VideoScaleMode in
            state.url = url
            state.videoAspect = nil
            return state.settled
        }
        setGravity(resolved)
        loadAspect(of: url)
    }

    /// Record the video's display aspect ratio and re-apply the gravity it settles.
    /// Ignores a late arrival for a video we have already switched away from.
    private func noteAspect(_ aspect: Double, for url: URL) {
        let resolved = scaleState.withLock { state -> VideoScaleMode? in
            guard state.url == url else { return nil }
            state.videoAspect = aspect
            return state.settled
        }
        guard let resolved else { return }
        setGravity(resolved)
        traceLog("  [scale #\(debugID)] aspect \(aspect) → \(resolved.rawValue)")
    }

    /// Load the display aspect ratio off the main path. Re-opening the asset costs a
    /// header read of a local file in our own container (a few ms) and keeps the
    /// non-Sendable `AVAssetTrack` on the thread that owns it.
    private func loadAspect(of url: URL) {
        Task { [weak self] in
            guard let self else { return }
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let aspect = try? await Self.displayAspect(of: track) else { return }
            noteAspect(aspect, for: url)
        }
    }

    /// Width ÷ height of a surface. 1 for a degenerate size, which only makes
    /// "scale to height/width" behave like fill until a real size arrives.
    static func aspect(of size: CGSize) -> Double {
        guard size.width > 0, size.height > 0 else { return 1 }
        return Double(size.width / size.height)
    }

    /// Width ÷ height as displayed — `naturalSize` put through `preferredTransform`.
    /// nil for a degenerate size (a track that reports 0 in either direction).
    static func displayAspect(of track: AVAssetTrack) async throws -> Double? {
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let display = size.applying(transform)
        let width = abs(display.width), height = abs(display.height)
        guard width > 0, height > 0 else { return nil }
        return Double(width / height)
    }

    private func setGravity(_ mode: VideoScaleMode) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.videoGravity = mode.videoGravity
        stillFrameLayer.contentsGravity = mode.contentsGravity
        CATransaction.commit()
    }

    static func create(
        rootLayer: CALayer,
        videoURL: URL,
        stillImage: CGImage? = nil,
    ) async throws -> VideoRenderer {
        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "No video track found in \(videoURL.lastPathComponent)",
            ])
        }

        let displayLayer = AVSampleBufferDisplayLayer()
        // The user's choice (Settings → 影片 → 縮放), relayed by the app through
        // WallpaperPrefs. `random` draws per video and "scale to height/width" needs
        // both aspect ratios, so this is settled here — and again on every switch —
        // not once per process. The track is already loaded, so the video's ratio costs
        // nothing extra here (the switch path loads it separately).
        let scaleMode = WallpaperPrefs.shared.videoScaleMode
        let videoAspect = try? await displayAspect(of: track)
        // The track is loaded here anyway, so its timing costs nothing extra. Getting
        // it up front means the very first loop already knows the real frame duration
        // instead of falling back to an observed estimate.
        let timing = await trackTiming(of: track)
        let screenAspect = Self.aspect(of: rootLayer.bounds.size)
        let settled = scaleMode.resolved(seed: videoURL.path)
            .resolved(videoAspect: videoAspect ?? nil, screenAspect: screenAspect)
        displayLayer.videoGravity = settled.videoGravity
        displayLayer.frame = rootLayer.bounds
        displayLayer.contentsScale = rootLayer.contentsScale
        // Opaque: the per-surface context fix (each Space/lock surface owns its own
        // CAContext) is what stops the black, not this layer's opacity. Leaving the
        // layer non-opaque only adds a per-frame blend against what's behind it, which
        // makes the layer visibly blink while the compositor rebuilds it during a
        // switch. Opaque keeps the switch seamless.
        displayLayer.isOpaque = true
        // Match Apple's WallpaperExtensionKit: stop the AVSampleBufferDisplayLayer from
        // painting opaque BLACK before its first frame is composited. On a cold start the
        // Agent hosts our context the instant we reply, and without this an as-yet-empty
        // layer flashes black (the residual "black still"). Apple sets this on every AVSBDL.
        setDisallowsVideoLayerDisplayCompositing(displayLayer, true)
        // Added to the tree in init() inside an action-free transaction (below).

        return VideoRenderer(
            rootLayer: rootLayer,
            displayLayer: displayLayer,
            asset: asset,
            videoTrack: track,
            trackTiming: timing,
            stillImage: stillImage,
            scaleMode: scaleMode,
            videoAspect: videoAspect ?? nil,
            screenAspect: screenAspect,
            settled: settled,
        )
    }

    /// Read a track's timing into the shared model. Every field is best-effort: a
    /// track that won't answer leaves `VideoTrackTiming.unknown`, and the timeline
    /// then learns the start from the first sample rather than assuming zero.
    static func trackTiming(of track: AVAssetTrack) async -> VideoTrackTiming {
        let timeRange = try? await track.load(.timeRange)
        let minFrameDuration = try? await track.load(.minFrameDuration)
        let nominalFrameRate = try? await track.load(.nominalFrameRate)
        return trackTiming(timeRange: timeRange, minFrameDuration: minFrameDuration,
                           nominalFrameRate: nominalFrameRate)
    }

    static func trackTiming(
        timeRange: CMTimeRange?, minFrameDuration: CMTime?, nominalFrameRate: Float?,
    ) -> VideoTrackTiming {
        var frameDuration: CMTime?
        if let minFrameDuration, minFrameDuration.isNumeric, minFrameDuration > .zero {
            frameDuration = minFrameDuration
        } else if let nominalFrameRate, nominalFrameRate > 0, nominalFrameRate.isFinite {
            // A big timescale so 23.976 / 29.97 don't round into a per-frame error that
            // accumulates over a loop. This is only a fallback for samples that carry
            // no duration of their own.
            frameDuration = CMTime(seconds: 1.0 / Double(nominalFrameRate),
                                   preferredTimescale: 600_000)
        }
        guard let timeRange, timeRange.start.isNumeric, timeRange.duration.isNumeric else {
            return VideoTrackTiming(start: .zero, duration: .invalid,
                                    nominalFrameDuration: frameDuration, startIsKnown: false)
        }
        return VideoTrackTiming(start: timeRange.start, duration: timeRange.duration,
                                nominalFrameDuration: frameDuration)
    }

    private init(
        rootLayer: CALayer,
        displayLayer: AVSampleBufferDisplayLayer,
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        trackTiming: VideoTrackTiming,
        stillImage: CGImage?,
        scaleMode: VideoScaleMode,
        videoAspect: Double?,
        screenAspect: Double,
        settled: VideoScaleMode,
    ) {
        self.scaleState = OSAllocatedUnfairLock(initialState: Scale(
            mode: scaleMode, url: asset.url,
            videoAspect: videoAspect, screenAspect: screenAspect))
        self.displayLayer = displayLayer
        self.renderer = displayLayer.sampleBufferRenderer
        self.asset = asset
        self.videoTrack = videoTrack
        self.timeline = LoopTimeline(track: trackTiming)

        self.stillFrameLayer = CALayer()
        stillFrameLayer.frame = rootLayer.bounds
        // Same gravity as the video layer: the still is what the user sees until the
        // first decoded frame lands, and a mismatch makes the picture jump at that moment.
        stillFrameLayer.contentsGravity = settled.contentsGravity
        stillFrameLayer.contentsScale = rootLayer.contentsScale
        stillFrameLayer.opacity = 0
        stillFrameLayer.name = "phosphene.stillFrame"

        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb,
        )
        self.timebase = tb!
        CMTimebaseSetTime(timebase, time: .zero)
        // Rate stays 0 until start() — prevents the timebase from advancing
        // during the async gap between init and start, which would cause
        // the first batch of frames to be considered "late" and dropped.
        CMTimebaseSetRate(timebase, rate: 0.0)
        displayLayer.controlTimebase = timebase

        // Install the layers and seed the still in ONE action-free transaction, so
        // Core Animation doesn't play an implicit "onOrderIn" animation (the video
        // appearing to zoom/fade in). The still is an IOSurface-backed sample buffer
        // at PTS 0 — unlike CALayer.contents (black when hosted cross-process) it
        // composites into WallpaperAgent's CALayerHost, so the desktop shows the
        // still immediately; the video's first real frame (also PTS 0) plays over it
        // once rate=1.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.sublayers?.filter { $0.name == "phosphene.stillFrame" }.forEach { $0.removeFromSuperlayer() }
        rootLayer.addSublayer(displayLayer)
        rootLayer.addSublayer(stillFrameLayer)
        traceLog("  [Renderer #\(debugID)] CREATED for \(asset.url.lastPathComponent), displayLayer=\(ObjectIdentifier(displayLayer)), rootLayer sublayers=\((rootLayer.sublayers?.count ?? 0))")
        if let stillImage, let stillBuffer = makeStillSampleBuffer(from: stillImage) {
            // Tag DisplayImmediately so the still is shown the instant it's enqueued,
            // rather than waiting on the control timebase (which is frozen at rate 0 here).
            // Without this the frame can sit undisplayed → the layer reads empty → black.
            Self.setDisplayImmediately(stillBuffer)
            renderer.enqueue(stillBuffer)
            traceLog("  [Renderer #\(debugID)] Seeded still into display layer (\(stillImage.width)x\(stillImage.height))")
        } else {
            traceLog("  [Renderer #\(debugID)] No still to seed (stillImage present: \(stillImage != nil))")
        }
        CATransaction.commit()
        // flush() (not just commit()) is what pushes the layer tree to the render
        // server for a REMOTE context — without it the still never reaches the
        // WindowServer and the desktop stays black until a later flush.
        CATransaction.flush()
    }

    /// Start playback: decode and enqueue the first frame, then begin the feed loop.
    /// Runs on the renderer's serial queue rather than the caller's thread — the
    /// first-frame `copyNextSampleBuffer` is a blocking decode, and the caller is a
    /// Swift-concurrency (cooperative) task; blocking a cooperative thread violates
    /// forward progress and starves the extension's tiny executor.
    ///
    /// `onFirstFrameReady`, if provided, is invoked AFTER the first frame is enqueued and
    /// flushed to the render server — i.e. once this renderer's CAContext is actually
    /// displaying video. The acquire path uses it to defer its XPC reply until the new
    /// context is live, so WallpaperAgent keeps compositing the OLD wallpaper until then
    /// and the host swap lands directly on playing video (no blink / still-flash / zoom),
    /// mirroring Apple's own extensions. It is called exactly once on every path,
    /// including early exits, so a gated reply can never hang.
    func start(onFirstFrameReady: (@Sendable () -> Void)? = nil) {
        traceLog("  [start #\(debugID)] asset=\(asset.url.lastPathComponent)")
        queue.async { [weak self] in
            guard let self else { onFirstFrameReady?(); return }
            guard isRunning else { traceLog("  [start #\(debugID)] aborted — already stopped"); onFirstFrameReady?(); return }
            generation &+= 1
            let gen = generation
            timeline.rebase(to: timeline.track)
            guard let (reader, output) = makeReader(asset: asset, track: videoTrack) else {
                // A reader that won't open is a dead surface unless somebody is told.
                // Report and let the host retarget; do NOT leave the acquire hanging.
                onFirstFrameReady?()
                reportFailure("無法開啟影片（AVAssetReader 建立或啟動失敗）")
                return
            }

            // Reset timebase BEFORE first enqueue so the frame isn't seen as late.
            CMTimebaseSetTime(timebase, time: .zero)

            // Enqueue the first frame and flush it to the render server inside an
            // action-free transaction, so the context is genuinely displaying video
            // before onFirstFrameReady fires (the deferred acquire reply gates on this).
            if let firstSample = output.copyNextSampleBuffer() {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                renderer.enqueue(retimed(firstSample))
                CATransaction.commit()
                CATransaction.flush()
            }

            currentReader = reader
            currentOutput = output

            // Begin advancing the timebase — playback starts.
            CMTimebaseSetRate(timebase, rate: 1.0)

            // The context now holds a live, composited video frame — release the gate so
            // the acquire can reply and the agent can swap to us.
            onFirstFrameReady?()

            prepareNextReader(generation: gen)
            feedFromCurrentReader(generation: gen)
        }
    }

    /// Build a reader and start it, or return nil. Both halves are checked: a reader
    /// that constructs fine can still refuse to start (missing file, unreadable track,
    /// sandbox denial), and the old code looked at neither — a failed start showed up
    /// only as a surface that never produced a frame.
    /// - Parameter timeRange: restrict reading to this range (a resume). nil reads all.
    /// Must run on `queue`.
    private func makeReader(
        asset: AVURLAsset, track: AVAssetTrack, timeRange: CMTimeRange? = nil,
        start: Bool = true,
    ) -> (AVAssetReader, AVAssetReaderTrackOutput)? {
        guard let reader = try? AVAssetReader(asset: asset) else {
            extensionLog("  [reader #\(debugID)] create FAILED for \(asset.url.lastPathComponent)")
            return nil
        }
        if let timeRange { reader.timeRange = timeRange }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            extensionLog("  [reader #\(debugID)] cannot add output for \(asset.url.lastPathComponent)")
            return nil
        }
        reader.add(output)
        if start, !reader.startReading() {
            extensionLog("  [reader #\(debugID)] startReading FAILED for \(asset.url.lastPathComponent): \(reader.error?.localizedDescription ?? "unknown")")
            return nil
        }
        return (reader, output)
    }

    /// Put a sample on this renderer's output timeline. Returns the original buffer
    /// when no adjustment is needed (the first loop of a zero-start track), so the
    /// common case still costs no copy. Must run on `queue`.
    private func retimed(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        let adjusted = timeline.admit(
            pts: CMSampleBufferGetPresentationTimeStamp(sample),
            dts: CMSampleBufferGetDecodeTimeStamp(sample),
            duration: CMSampleBufferGetDuration(sample))
        guard adjusted.needsRetiming else { return sample }

        var timingInfo = CMSampleTimingInfo(
            duration: adjusted.duration,
            presentationTimeStamp: adjusted.presentationTimeStamp,
            decodeTimeStamp: adjusted.decodeTimeStamp,
        )
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &copy,
        )
        return copy ?? sample
    }

    /// Switch to a different video IN PLACE, reusing this renderer's existing
    /// `displayLayer`. The layer is already attached to the display's CAContext and
    /// hosted by WallpaperAgent, so feeding it frames from a new asset updates the
    /// desktop — whereas building a fresh renderer (new `AVSampleBufferDisplayLayer`)
    /// added to an already-hosted context does NOT composite (the switch-between-
    /// videos bug). So we keep the one hosted layer and restart it on the new asset.
    ///
    /// Fully serialized on `queue`, no `Task`: the track load blocks the queue thread
    /// (a real thread we own, which already blocks for decodes). Because every switch
    /// runs to completion in FIFO order on one thread, rapid switching is naturally
    /// last-*requested*-wins with no cancellation bookkeeping — the only async hop is
    /// the renderer's `flush`, which is serialized and coalesces rapid switches.
    /// Re-frame the video + still layers to a new destination geometry (points) and
    /// backing scale — used when a display reconnects at, or switches to, a different
    /// resolution. Both layers fill the root and are `resizeAspectFill`, so re-framing
    /// them to the full bounds is all that's needed; the AVSampleBufferDisplayLayer
    /// re-fits the decoded frames to the new size on the next composite. Synchronous,
    /// inside an action-free flushed transaction, to match the acquire path's own layer
    /// mutations (which run on the same Lifecycle queue, off the main thread).
    func resize(to destSize: CGSize, scale: CGFloat) {
        let bounds = CGRect(origin: .zero, size: destSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        displayLayer.contentsScale = scale
        stillFrameLayer.frame = bounds
        stillFrameLayer.contentsScale = scale
        // A new destination geometry can flip which axis "scale to height/width"
        // resolves to (a 16:9 video is wider than a 16:10 panel but narrower than an
        // ultrawide), so re-settle inside the same transaction.
        let settled = scaleState.withLock { state -> VideoScaleMode in
            state.screenAspect = Self.aspect(of: destSize)
            return state.settled
        }
        displayLayer.videoGravity = settled.videoGravity
        stillFrameLayer.contentsGravity = settled.contentsGravity
        CATransaction.commit()
        CATransaction.flush()
        traceLog("  [resize #\(debugID)] → \(destSize) @\(scale)x")
    }

    func switchVideo(to url: URL) {
        traceLog("  [switchVideo #\(debugID)] REQUEST target=\(url.lastPathComponent)")
        queue.async { [weak self] in
            guard let self, isRunning else { return }
            // Same file already playing → nothing to do (defuses repeated identical picks).
            if asset.url == url, pendingSwitchURL == nil {
                traceLog("  [switchVideo #\(debugID)] DEDUP: already on \(url.lastPathComponent)")
                return
            }
            // Last *requested* wins. The generation counter can't serve as the token
            // here: two switches issued before either load finishes share a generation,
            // so the second install would be dropped and the surface would settle on
            // the older pick. This counter is bumped per request instead.
            switchRequestID &+= 1
            let request = switchRequestID
            pendingSwitchURL = url

            // The track load blocks; keep it off the feed queue so sample delivery for
            // the CURRENTLY playing video isn't interrupted while we open the next file
            // (on a NAS that load is the visible stutter at every switch).
            loadQueue.async { [weak self] in
                guard let self else { return }
                let newAsset = AVURLAsset(url: url)
                guard let track = Self.loadFirstVideoTrackBlocking(newAsset) else {
                    traceLog("  [switchVideo #\(debugID)] no video track in \(url.lastPathComponent)")
                    queue.async { [weak self] in
                        guard let self, switchRequestID == request else { return }
                        pendingSwitchURL = nil
                    }
                    return
                }
                let boxed = SendableBox(value: track)
                queue.async { [weak self] in
                    guard let self, isRunning else { return }
                    guard switchRequestID == request else {
                        traceLog("  [switchVideo #\(debugID)] superseded — dropping \(url.lastPathComponent)")
                        return
                    }
                    pendingSwitchURL = nil
                    asset = newAsset
                    videoTrack = boxed.value
                    timeline.rebase(to: .unknown)
                    loadTrackDetails(boxed.value, for: url)
                    rescale(for: url)
                    traceLog("  [switchVideo #\(debugID)] restarting from 0 → \(url.lastPathComponent)")
                    requestReset(.newAsset)
                }
            }
        }
    }

    /// Fill in the track's declared duration and frame duration once AVFoundation
    /// answers. Deliberately asynchronous and best-effort: the timeline already learned
    /// the real start from the first sample, and blocking the feed queue for a header
    /// read is what this whole reshuffle exists to avoid. A late answer for a video we
    /// have already switched away from is dropped.
    private func loadTrackDetails(_ track: AVAssetTrack, for url: URL) {
        let boxed = SendableBox(value: track)
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let timing = await Self.trackTiming(of: boxed.value)
            queue.async { [weak self] in
                guard let self, asset.url == url else { return }
                timeline.noteTrackDetails(duration: timing.duration,
                                          nominalFrameDuration: timing.nominalFrameDuration)
            }
        }
    }

    /// Tag a sample buffer so the renderer displays it immediately, replacing all
    /// previously enqueued/displayed images regardless of timestamps (per
    /// AVQueuedSampleBufferRendering docs). Used for the first frame of a switched
    /// video so the swap is instant and doesn't wait on the control timebase.
    private static func setDisplayImmediately(_ sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else { return }
        let count = CFArrayGetCount(attachments)
        for i in 0 ..< count {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, i), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque(),
            )
        }
    }

    /// Load the first video track synchronously. Call ONLY from the renderer's serial
    /// `queue` — it blocks that (real, owned) thread on a semaphore while AVFoundation
    /// loads the track on its own internal queue, so there's no cooperative-executor
    /// starvation and no out-of-order Task completion. Local files load in a few ms.
    private static func loadFirstVideoTrackBlocking(_ asset: AVURLAsset) -> AVAssetTrack? {
        traceLog("  [load] blocking-load START \(asset.url.lastPathComponent) (queue will block until AVF replies)")
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: AVAssetTrack?
        asset.loadTracks(withMediaType: .video) { tracks, _ in
            result = tracks?.first
            sem.signal()
        }
        sem.wait()
        traceLog("  [load] blocking-load DONE \(asset.url.lastPathComponent) track=\(result != nil ? "ok" : "nil")")
        return result
    }

    /// Stop playback. Dispatches synchronously to the renderer queue to ensure
    /// no callback is mid-flight before canceling the reader.
    func stop() {
        extensionLog("  [stop #\(debugID)] stopping renderer for \(asset.url.lastPathComponent)")
        cancelDeepPauseTimer()
        queue.sync {
            isRunning = false
            // Bump the session so any flush completion, off-queue asset load or feed
            // callback still in flight returns without touching a torn-down renderer.
            generation &+= 1
            switchRequestID &+= 1
            renderer.stopRequestingMediaData()
            currentReader?.cancelReading()
            nextReader?.cancelReading()
        }
        // Clean up layers from the layer tree
        displayLayer.removeFromSuperlayer()
        stillFrameLayer.removeFromSuperlayer()
    }

    func pause() {
        guard !isPaused else { return }
        traceLog("  [pause #\(debugID)]")
        isPaused = true
        CMTimebaseSetRate(timebase, rate: 0.0)
        generateStillFrame()
        // Cap read-ahead while paused. Without this the feed loop keeps pulling from
        // the reader until the renderer's own queue is full, so a surface that is
        // paused for hours (occluded desktop, lock screen with alwaysPauseDesktop)
        // still holds a decoder's worth of buffered frames until deep pause fires.
        queue.async { [weak self] in
            guard let self, isPaused else { return }
            renderer.stopRequestingMediaData()
        }
        scheduleDeepPause()
    }

    func resume() {
        guard isPaused else { return }
        traceLog("  [resume #\(debugID)] currentReader=\(currentReader == nil ? "nil(deep)" : "live") asset=\(asset.url.lastPathComponent) rate→1")
        isPaused = false
        cancelDeepPauseTimer()
        stillFrameLayer.opacity = 0
        queue.async { [weak self] in
            guard let self, isRunning, !isPaused else { return }
            if currentReader == nil {
                // Woke from deep pause — readers were freed. Rebuild CONTINUING from the
                // paused position (seamless, no black) so a screen-lock/display-sleep wake
                // resumes the same video instead of restarting it.
                requestReset(.wake)
            } else {
                // Still have a live reader: just restart the feed that `pause` stopped.
                CMTimebaseSetRate(timebase, rate: 1.0)
                feedFromCurrentReader(generation: generation)
            }
        }
    }

    func applyPolicy(_ policy: PlaybackPolicy, animated: Bool = false) {
        guard policy != currentPolicy else { return }
        let oldPolicy = currentPolicy
        currentPolicy = policy
        extensionLog("  [applyPolicy #\(debugID)] \(oldPolicy) → \(policy) animated=\(animated) asset=\(asset.url.lastPathComponent)")
        cancelRamp()

        switch policy {
        case .paused:
            if animated {
                rampDown()
            } else {
                pause()
            }
        case .full, .reduced, .minimal:
            if animated, oldPolicy == .paused {
                rampUp()
            } else {
                resume()
            }
        }
    }

    // MARK: - Ramp (Apple-like lock screen transition)

    /// Ramp durations in seconds and step interval aligned to display refresh rate.
    /// Ramp-down (unlock → desktop pause) matches the ~6 s deceleration of Apple's
    /// built-in wallpapers after unlock; ramp-up (→ lock screen) stays short so
    /// playback reaches full speed while the lock reveal is still on screen.
    private static let rampUpDuration: TimeInterval = 2.0
    private static let rampDownDuration: TimeInterval = 6.0
    private static let rampStepInterval: TimeInterval = 1.0 / 120.0

    /// Ease-in-out cubic: smooth acceleration then deceleration.
    /// t in [0, 1] → output in [0, 1].
    private static func easeInOut(_ t: Double) -> Double {
        t < 0.5
            ? 4.0 * t * t * t
            : 1.0 - pow(-2.0 * t + 2.0, 3) / 2.0
    }

    /// Ramp the timebase from its CURRENT rate to `target` over the remaining slice
    /// of `duration`, then run `completion`.
    ///
    /// **Progress comes from a monotonic clock, not from counting timer callbacks.**
    /// A `DispatchSourceTimer` under load coalesces and drops ticks, so a tick count
    /// makes the transition run long by however much the system was busy — exactly
    /// when a wallpaper is most likely to be descheduled. Reading elapsed time instead
    /// keeps the ramp the length it claims to be.
    ///
    /// Reversing mid-ramp continues from wherever the rate currently is, so an
    /// unlock during a lock-screen ramp doesn't snap the picture back to 0 or 1.
    private func ramp(to target: Double, duration: TimeInterval,
                      completion: (@Sendable () -> Void)? = nil) {
        let startRate = Double(CMTimebaseGetRate(timebase))
        let span = target - startRate
        guard abs(span) > 0.001, duration > 0 else {
            CMTimebaseSetRate(timebase, rate: Float64(target))
            completion?()
            return
        }
        // Only the remaining fraction of the distance takes time — a reversal at 40%
        // shouldn't take the full duration again.
        let remaining = duration * abs(span)
        let began = DispatchTime.now().uptimeNanoseconds

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.rampStepInterval, repeating: Self.rampStepInterval)
        timer.setEventHandler { [weak self] in
            guard let self, isRunning else {
                timer.cancel()
                return
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000
            let progress = min(elapsed / remaining, 1.0)
            CMTimebaseSetRate(timebase, rate: Float64(startRate + span * Self.easeInOut(progress)))

            if progress >= 1.0 {
                timer.cancel()
                rampTimer = nil
                CMTimebaseSetRate(timebase, rate: Float64(target))
                completion?()
            }
        }
        rampTimer = timer
        timer.resume()
    }

    /// Gradually reduce timebase rate to zero, then freeze.
    private func rampDown() {
        guard !isPaused else { return }
        ramp(to: 0, duration: Self.rampDownDuration) { [weak self] in
            guard let self else { return }
            isPaused = true
            generateStillFrame()
            renderer.stopRequestingMediaData()
            scheduleDeepPause()
        }
    }

    /// Gradually increase timebase rate to 1.0.
    private func rampUp() {
        let wasDeepPaused = currentReader == nil
        isPaused = false
        cancelDeepPauseTimer()
        stillFrameLayer.opacity = 0

        if wasDeepPaused {
            // Deep-paused: no frames to ramp into. Wake instantly (continuing from the
            // paused position, seamless) instead of ramping an empty pipeline.
            queue.async { [weak self] in
                guard let self, isRunning else { return }
                requestReset(.wake)
            }
            return
        }
        // `pause` stopped the feed to cap read-ahead; a ramp needs frames to ramp into.
        queue.async { [weak self] in
            guard let self, isRunning, !isPaused else { return }
            feedFromCurrentReader(generation: generation)
        }
        ramp(to: 1.0, duration: Self.rampUpDuration)
    }

    private func cancelRamp() {
        rampTimer?.cancel()
        rampTimer = nil
    }

    // MARK: - Deep Pause

    //
    // After a sustained pause (lock screen overnight, brightness at zero, etc.)
    // the asset reader still holds decoded buffers and the underlying video
    // decoder. Tearing them down frees memory and lets the system fully idle.
    // On resume `requestReset(.wake)` rebuilds it, continuing from the paused
    // position rather than restarting the clip.

    private static let deepPauseDelay: TimeInterval = 30

    private func scheduleDeepPause() {
        cancelDeepPauseTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.deepPauseDelay)
        timer.setEventHandler { [weak self] in
            self?.enterDeepPause()
        }
        deepPauseTimer = timer
        timer.resume()
    }

    private func cancelDeepPauseTimer() {
        deepPauseTimer?.cancel()
        deepPauseTimer = nil
    }

    /// Runs on the renderer queue when the deep-pause timer fires.
    private func enterDeepPause() {
        deepPauseTimer = nil
        guard isRunning, isPaused, currentReader != nil else { return }
        renderer.stopRequestingMediaData()
        currentReader?.cancelReading()
        nextReader?.cancelReading()
        currentReader = nil
        currentOutput = nil
        nextReader = nil
        nextOutput = nil
        nextReaderStarted = false
        extensionLog("  [Renderer] Deep-paused — freed asset readers")
    }

    // MARK: - Pipeline Reset

    /// Ask for a pipeline reset. **The single entry point for every decoder reset** —
    /// a switch, an error recovery and a deep-pause wake all land here.
    ///
    /// A `flush` is a decoder RESET: it discards anything enqueued before it completes,
    /// and two overlapping flushes corrupt the renderer. So at most one is ever in
    /// flight, and a request arriving during one is merged into `pendingReset` and
    /// applied once when the flush lands — against whatever `asset` is by then, i.e.
    /// the latest pick. Must run on `queue`.
    private func requestReset(_ request: ResetRequest) {
        guard isRunning else { return }
        traceLog("  [reset #\(debugID)] REQUEST fromZero=\(request.restartFromZero) clear=\(request.clearDisplayedImage) flushInFlight=\(flushInFlight) asset=\(asset.url.lastPathComponent)")
        if flushInFlight {
            pendingReset = pendingReset?.merged(with: request) ?? request
            return
        }
        performReset(request)
    }

    /// Must run on `queue`.
    private func performReset(_ request: ResetRequest) {
        flushInFlight = true
        generation &+= 1

        // Freeze the clock up front so it can't advance during the async flush —
        // otherwise the frames that follow arrive "late" and get dropped.
        let resumeTimelineTime = request.restartFromZero ? CMTime.zero : CMTimebaseGetTime(timebase)
        CMTimebaseSetRate(timebase, rate: 0.0)
        renderer.stopRequestingMediaData()
        currentReader?.cancelReading()
        nextReader?.cancelReading()
        currentReader = nil
        currentOutput = nil
        nextReader = nil
        nextOutput = nil
        nextReaderStarted = false

        // Keep the displayed frame unless this is an error reset (where it may be the
        // corrupt one). The first new frame is tagged DisplayImmediately and replaces
        // it the instant it decodes, so a switch has no blank.
        renderer.flush(removingDisplayedImage: request.clearDisplayedImage) { [weak self] in
            guard let self else {
                extensionLog("  [reset] FLUSH-CB but self gone (flushInFlight leaks!)")
                return
            }
            queue.async { [weak self] in
                guard let self else { return }
                flushInFlight = false
                if let pending = pendingReset {
                    pendingReset = nil
                    traceLog("  [reset #\(debugID)] coalesced → \(asset.url.lastPathComponent)")
                    performReset(pending)
                    return
                }
                guard isRunning else { return }
                beginReading(request, resumeTimelineTime: resumeTimelineTime)
            }
        }
    }

    /// Open a reader and start feeding, either from the top of the timeline or
    /// continuing from where the timebase was paused. Must run on `queue`.
    private func beginReading(_ request: ResetRequest, resumeTimelineTime: CMTime) {
        let gen = generation
        var timeRange: CMTimeRange?

        if request.restartFromZero {
            timeline.rebase(to: timeline.track)
            CMTimebaseSetTime(timebase, time: .zero)
        } else {
            // **Translate the timeline position into a position inside the FILE.**
            // The timebase accumulates across loops, so after the first loop its value
            // is past the end of the file; handing it to `AVAssetReader.timeRange`
            // yields a reader that returns nothing, and the surface silently restarts
            // from the top — the "waking up replays the video" symptom.
            let filePosition = timeline.filePosition(forTimelineTime: resumeTimelineTime)
            timeline.resumeReading(atFilePosition: filePosition, timelineTime: resumeTimelineTime)
            timeRange = CMTimeRange(start: filePosition, duration: .positiveInfinity)
            traceLog("  [reset #\(debugID)] resume timeline=\(resumeTimelineTime.seconds)s → file=\(filePosition.seconds)s")
        }

        guard let (reader, output) = makeReader(asset: asset, track: videoTrack, timeRange: timeRange) else {
            scheduleRecovery(reason: "無法開啟影片（AVAssetReader 建立或啟動失敗）")
            return
        }
        currentReader = reader
        currentOutput = output

        // Enqueue the first frame while the clock is still frozen, exactly like
        // start(), so it isn't dropped as late. Tag it DisplayImmediately so it
        // replaces the retained old frame the moment it decodes — an instant,
        // blank-free swap that doesn't depend on the timebase (important since a
        // switch can land while paused, rate=0).
        if let first = output.copyNextSampleBuffer() {
            let adjusted = retimed(first)
            Self.setDisplayImmediately(adjusted)
            renderer.enqueue(adjusted)
        }

        CMTimebaseSetRate(timebase, rate: isPaused ? 0.0 : 1.0)
        traceLog("  [reset #\(debugID)] playing \(asset.url.lastPathComponent) rate=\(isPaused ? 0 : 1) rendererStatus=\(renderer.status.rawValue) requiresFlush=\(renderer.requiresFlushToResumeDecoding) readerStatus=\(reader.status.rawValue) err=\(renderer.error?.localizedDescription ?? "-")")
        feedLogBudget = 4
        prepareNextReader(generation: gen)
        guard !isPaused else { return }
        feedFromCurrentReader(generation: gen)
    }

    // MARK: - Failure Recovery

    /// Try again, with a ceiling and a backoff. Past the ceiling the surface is handed
    /// back to the host so it can retarget to a video that works.
    ///
    /// **Bounded on purpose.** The old error path re-created the pipeline on every
    /// failure with no counter, so a file that cannot be decoded at all — a truncated
    /// download, a codec this Mac has no hardware path for — turned into an endless
    /// rebuild loop inside a sandboxed appex nobody is watching.
    /// Must run on `queue`.
    private func scheduleRecovery(reason: String) {
        guard isRunning else { return }
        recoveryAttempts += 1
        guard recoveryAttempts <= Self.maxRecoveryAttempts else {
            reportFailure(reason)
            return
        }
        let delay = Self.recoveryBackoff * Double(recoveryAttempts)
        extensionLog("  [recover #\(debugID)] \(reason) — attempt \(recoveryAttempts)/\(Self.maxRecoveryAttempts) in \(delay)s (\(asset.url.lastPathComponent))")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, isRunning else { return }
            requestReset(.errorReset)
        }
    }

    /// Give up on this asset and tell the host. Must run on `queue`.
    private func reportFailure(_ reason: String) {
        extensionLog("  [recover #\(debugID)] GIVING UP on \(asset.url.lastPathComponent): \(reason)")
        recoveryAttempts = 0
        emptyLoops = 0
        renderer.stopRequestingMediaData()
        currentReader?.cancelReading()
        currentReader = nil
        currentOutput = nil
        let url = asset.url
        let handler = onPlaybackFailed
        DispatchQueue.main.async { handler?(url, reason) }
    }

    // MARK: - Preloaded Loop Reader

    /// Pick and open the video for the NEXT loop iteration, ahead of the boundary.
    ///
    /// **The pick and the asset load run off `queue`.** `variantSelector` reaches into
    /// the shuffle controller and the wallpaper state, and the track load blocks on
    /// AVFoundation; doing either on the feed queue stalls delivery of the frames that
    /// are on screen right now. Only the install hops back. Must be called on `queue`.
    private func prepareNextReader(generation gen: Int) {
        let selector = variantSelector
        let currentURL = asset.url
        let currentTrack = SendableBox(value: videoTrack)
        let currentTiming = timeline.track

        loadQueue.async { [weak self] in
            guard let self else { return }
            let nextURL = selector?()

            guard let nextURL, nextURL != currentURL else {
                // Same clip again: reuse the track we already have, no load at all.
                queue.async { [weak self] in
                    guard let self, isRunning, gen == generation else { return }
                    installNextReader(asset: asset, track: currentTrack.value, timing: currentTiming)
                }
                return
            }

            let newAsset = AVURLAsset(url: nextURL)
            guard let track = Self.loadFirstVideoTrackBlocking(newAsset) else {
                traceLog("  [Renderer] No video track in variant: \(nextURL.lastPathComponent)")
                queue.async { [weak self] in
                    guard let self, isRunning, gen == generation else { return }
                    installNextReader(asset: asset, track: currentTrack.value, timing: currentTiming)
                }
                return
            }
            let boxed = SendableBox(value: track)
            queue.async { [weak self] in
                guard let self, isRunning, gen == generation else { return }
                installNextReader(asset: newAsset, track: boxed.value, timing: .unknown)
            }
            // The declared duration follows separately; the timeline works without it
            // (it learns the start from the first sample) and adopts it when it lands.
            Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                let timing = await Self.trackTiming(of: boxed.value)
                queue.async { [weak self] in
                    guard let self, gen == generation else { return }
                    if nextReader?.asset as? AVURLAsset === newAsset { nextTiming = timing }
                    if asset.url == nextURL {
                        timeline.noteTrackDetails(duration: timing.duration,
                                                  nominalFrameDuration: timing.nominalFrameDuration)
                    }
                }
            }
        }
    }

    /// Build the preloaded next reader. Must run on `queue`.
    ///
    /// Starting it here is what makes the preload real: an `AVAssetReader` that has
    /// only been constructed has done no work, so a boundary would still pay for the
    /// first decode. **Except while paused** — starting a second reader filling its
    /// queue is exactly the read-ahead the pause is meant to cap, so a paused install
    /// defers the start to the swap.
    private func installNextReader(asset: AVURLAsset, track: AVAssetTrack, timing: VideoTrackTiming) {
        guard let (reader, output) = makeReader(asset: asset, track: track, start: !isPaused) else {
            traceLog("  [Renderer] Failed to create next reader for \(asset.url.lastPathComponent)")
            nextReader = nil
            nextOutput = nil
            nextReaderStarted = false
            return
        }
        nextReader = reader
        nextOutput = output
        nextTiming = timing
        nextReaderStarted = !isPaused
    }

    /// Swap to the preloaded next reader at a loop boundary.
    /// Uses the timeline's offset for gapless continuation — no flush, no timebase reset.
    /// Must run on `queue`.
    private func swapToNextReader(generation gen: Int) {
        guard isRunning, gen == generation else { return }
        renderer.stopRequestingMediaData()

        // Close out the loop that just ended and open the next one on the same
        // continuous timeline.
        let produced = timeline.advanceToNextLoop()
        if produced {
            emptyLoops = 0
            recoveryAttempts = 0
        } else {
            emptyLoops += 1
            // A reader that opens but yields nothing turns the boundary into a tight
            // spin: swap → first read is nil → swap again. Escalate instead.
            guard emptyLoops < Self.maxEmptyLoops else {
                emptyLoops = 0
                scheduleRecovery(reason: "連續 \(Self.maxEmptyLoops) 輪讀不到任何畫格")
                return
            }
        }

        if let reader = nextReader, let output = nextOutput {
            if let nextAsset = reader.asset as? AVURLAsset, nextAsset.url != asset.url {
                asset = nextAsset
                videoTrack = output.track
                // A different clip means a different timeline: its start, length and
                // frame duration are its own. Rebase rather than carrying the previous
                // clip's numbers into the new one's loop maths.
                let base = timeline.loopBase
                timeline.rebase(to: nextTiming)
                timeline.resumeReading(atFilePosition: nextTiming.start, timelineTime: base)
                rescale(for: nextAsset.url)
                traceLog("  [Renderer] Switched variant: \(nextAsset.url.lastPathComponent)")
            }
            currentReader = reader
            currentOutput = output
            if !nextReaderStarted, !reader.startReading() {
                extensionLog("  [Renderer] preloaded reader failed to start: \(reader.error?.localizedDescription ?? "unknown")")
                currentReader = nil
                currentOutput = nil
                nextReader = nil
                nextOutput = nil
                nextReaderStarted = false
                scheduleRecovery(reason: "預載的 reader 啟動失敗")
                return
            }
            nextReader = nil
            nextOutput = nil
            nextReaderStarted = false
        } else {
            traceLog("  [Renderer] Next reader not ready, creating synchronously")
            guard let (reader, output) = makeReader(asset: asset, track: videoTrack) else {
                scheduleRecovery(reason: "循環邊界無法重新開啟影片")
                return
            }
            currentReader = reader
            currentOutput = output
        }

        prepareNextReader(generation: gen)
        feedFromCurrentReader(generation: gen)
    }

    // MARK: - Playback Loop

    private func feedFromCurrentReader(generation gen: Int) {
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self, isRunning, gen == generation else {
                self?.renderer.stopRequestingMediaData()
                return
            }

            // Unrecoverable failure — full reset.
            // Dispatch async: requestMediaDataWhenReady is not reentrant.
            if renderer.status == .failed {
                let reason = renderer.error?.localizedDescription ?? "unknown"
                extensionLog("  [Renderer] Status failed: \(reason), recovering")
                renderer.stopRequestingMediaData()
                queue.async { [weak self] in
                    self?.scheduleRecovery(reason: "解碼器失敗：\(reason)")
                }
                return
            }

            // Decoder hit a discontinuity or error — flush and continue feeding.
            if renderer.requiresFlushToResumeDecoding {
                traceLog("  [feed #\(debugID)] requiresFlushToResumeDecoding=YES → renderer.flush() (frames enqueued after may be discarded); status=\(renderer.status.rawValue)")
                renderer.flush()
            }

            var enqueuedThisTick = 0
            while renderer.isReadyForMoreMediaData {
                guard let sample = currentOutput?.copyNextSampleBuffer() else {
                    // **Why the reader stopped matters.** `nil` means end of file,
                    // a read error, or a cancel we issued ourselves — treating all
                    // three as "loop around" turned a mid-file decode error into a
                    // rebuild loop and raced a cancel against the reset that issued it.
                    let status = currentReader?.status ?? .cancelled
                    let error = currentReader?.error?.localizedDescription
                    if feedLogBudget > 0 {
                        traceLog("  [feed #\(debugID)] reader stopped (status=\(status.rawValue)) after enqueuing this tick=\(enqueuedThisTick)")
                    }
                    renderer.stopRequestingMediaData()
                    queue.async { [weak self] in
                        self?.readerDidStop(status: status, error: error, generation: gen)
                    }
                    return
                }
                renderer.enqueue(retimed(sample))
                enqueuedThisTick += 1
            }
            if feedLogBudget > 0 {
                feedLogBudget -= 1
                traceLog("  [feed #\(debugID)] tick enqueued=\(enqueuedThisTick) status=\(renderer.status.rawValue) requiresFlush=\(renderer.requiresFlushToResumeDecoding) ready=\(renderer.isReadyForMoreMediaData) timebase=\(CMTimebaseGetTime(timebase).seconds)")
            }
        }
    }

    /// The current reader stopped producing samples. Only a clean EOF continues the
    /// loop. Must run on `queue`.
    private func readerDidStop(status: AVAssetReader.Status, error: String?, generation gen: Int) {
        guard isRunning, gen == generation else { return }
        switch status {
        case .completed:
            swapToNextReader(generation: gen)
        case .failed:
            scheduleRecovery(reason: "讀取失敗：\(error ?? "未知錯誤")")
        case .cancelled:
            // We cancelled it (a switch, a deep pause, a stop). Whoever cancelled owns
            // what happens next — restarting here would fight them.
            traceLog("  [feed #\(debugID)] reader cancelled — leaving the restart to whoever cancelled it")
        case .reading, .unknown:
            // Ran dry without finishing. Not a clean EOF, but not an error either;
            // treat as a boundary — the empty-loop counter catches a spin.
            traceLog("  [feed #\(debugID)] reader ran dry while status=\(status.rawValue) — treating as boundary")
            swapToNextReader(generation: gen)
        @unknown default:
            swapToNextReader(generation: gen)
        }
    }

    // MARK: - Still Frame

    private func generateStillFrame() {
        // DISABLED. This spawned an AVAssetImageGenerator (its own video decoder) on
        // every pause to set stillFrameLayer.contents — but a CALayer.contents CGImage
        // does NOT composite in a remote CAContext (RE-confirmed), so it never showed
        // anything. Meanwhile, when the desktop thrashes idle/default, these generators
        // pile up and compete with the playback reader for the appex's limited video-
        // decoder resources, stalling playback (the ~20s "starvation"). When paused the
        // displayLayer already holds the last frame, so nothing visible is lost.
        traceLog("  [generateStillFrame #\(debugID)] skipped (no-op still; last frame held by displayLayer)")
    }
}
