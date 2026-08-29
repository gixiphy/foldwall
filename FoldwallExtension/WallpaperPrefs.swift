import AVFoundation
import Foundation
import os
import QuartzCore

/// The image a layer is showing, if it is showing one. `CALayer.contents` is `Any?`
/// and a plain `as? CGImage` on a CoreFoundation type always "succeeds" (the compiler
/// says so), so the type has to be checked at runtime.
private func stillImage(of layer: CALayer) -> CGImage? {
    guard let contents = layer.contents as AnyObject?,
          CFGetTypeID(contents) == CGImage.typeID else { return nil }
    return (contents as! CGImage)
}

/// How a video fills the screen. Mirrors `FoldwallCore.VideoScaleMode` — the extension
/// deliberately doesn't link FoldwallCore (it's a Phosphene fork kept rebasable), so the
/// raw values are the contract between the two sides. Changing one without the other
/// silently falls back to `.fill`.
enum VideoScaleMode: String {
    case fill
    /// Scale to the screen's HEIGHT, aspect preserved (sides cropped or letterboxed).
    case matchHeight
    /// Scale to the screen's WIDTH, aspect preserved (top/bottom cropped or letterboxed).
    case matchWidth
    case fit
    case random

    /// The concrete choices `random` draws from. `matchHeight`/`matchWidth` are left
    /// out on purpose: each always reduces to `fill` or `fit` for a given video, so
    /// including them would only skew the odds.
    static let concrete: [VideoScaleMode] = [.fill, .fit]

    /// Every mode preserves the video's aspect ratio — there is deliberately no
    /// "stretch to fill" (System Settings has one; it squashes the picture).
    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fill, .random, .matchHeight, .matchWidth: .resizeAspectFill
        case .fit: .resizeAspect
        }
    }

    /// The matching CALayer gravity, for the still-frame and root layers that sit
    /// under the video layer — they must crop/letterbox the same way or the still
    /// shown before the first decoded frame jumps when the video takes over.
    var contentsGravity: CALayerContentsGravity {
        switch self {
        case .fill, .random, .matchHeight, .matchWidth: .resizeAspectFill
        case .fit: .resizeAspect
        }
    }

    /// Whether this mode can only be settled once the video's aspect ratio is known.
    var needsVideoAspect: Bool { self == .matchHeight || self == .matchWidth }

    /// Settle against a still image standing in for the video (the cached BMP snapshot
    /// has the video's own dimensions) and the surface it is drawn into. Used for the
    /// layers that show that still before a renderer exists.
    func resolved(still: CGImage?, surface: CGSize) -> VideoScaleMode {
        guard needsVideoAspect else { return self }
        guard let still, still.height > 0 else { return .fill }
        return resolved(videoAspect: Double(still.width) / Double(still.height),
                        screenAspect: surface.height > 0
                            ? Double(surface.width / surface.height) : 1)
    }

    /// Reduce "scale to one axis" to `fill` or `fit`; other modes pass through.
    ///
    /// `matchHeight`'s scale factor is `screenH / videoH`, which is exactly
    /// aspect-FILL's factor (the larger of the two) iff the video is wider than the
    /// screen, and aspect-FIT's otherwise. `matchWidth` is the mirror image. So no
    /// custom layout is needed — only the right gravity. Unknown aspect (nil, zero,
    /// NaN) falls back to `fill`, the pre-0.6.3 behaviour.
    func resolved(videoAspect: Double?, screenAspect: Double) -> VideoScaleMode {
        guard needsVideoAspect else { return self }
        guard let videoAspect, videoAspect.isFinite, videoAspect > 0,
              screenAspect.isFinite, screenAspect > 0 else { return .fill }
        let videoIsWider = videoAspect >= screenAspect
        switch self {
        case .matchHeight: return videoIsWider ? .fill : .fit
        case .matchWidth: return videoIsWider ? .fit : .fill
        default: return self
        }
    }

    /// Resolve `random` to one concrete mode, deterministically per (display, video):
    /// re-resolving on every reload would make a playing video change framing at
    /// random moments. Same hash on both sides isn't required — nothing compares the
    /// app's draw with the extension's; only stability within a process matters.
    func resolved(seed: String) -> VideoScaleMode {
        guard self == .random else { return self }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
        return Self.concrete[Int(hash % UInt64(Self.concrete.count))]
    }
}

/// Extension-side reader for shared preferences written by the main app,
/// and writer for extension state (isActive) read by the app.
///
/// Thread-safe via `OSAllocatedUnfairLock`. Observes `app.foldwall.prefsChanged`
/// Darwin notification to reload when the app writes new values.
final class WallpaperPrefs: @unchecked Sendable {
    static let shared = WallpaperPrefs()

    private struct PrefsFile: Codable {
        var userPaused: Bool
        var alwaysPauseDesktop: Bool
        var pauseWhenOccluded: Bool
        var desktopOccluded: Bool
        var pausedDisplays: Set<UInt32>?
        var screenSaverIsOurs: Bool?
        /// Raw `VideoScaleMode`. Optional — written by the app since 0.6.3; an older
        /// prefs file (or none at all) means `.fill`, which is what the extension did
        /// unconditionally before.
        var videoScaleMode: String?

        init(userPaused: Bool = false, alwaysPauseDesktop: Bool = false, pauseWhenOccluded: Bool = false, desktopOccluded: Bool = false, pausedDisplays: Set<UInt32>? = nil, screenSaverIsOurs: Bool? = nil, videoScaleMode: String? = nil) {
            self.userPaused = userPaused
            self.alwaysPauseDesktop = alwaysPauseDesktop
            self.pauseWhenOccluded = pauseWhenOccluded
            self.desktopOccluded = desktopOccluded
            self.pausedDisplays = pausedDisplays
            self.screenSaverIsOurs = screenSaverIsOurs
            self.videoScaleMode = videoScaleMode
        }
    }

    private struct ContextState: Codable {
        var displayID: UInt32
        var videoID: String?
        var videoName: String?
    }

    private struct StateFile: Codable {
        var isActive: Bool
        var currentVideoID: String?
        var currentVideoName: String?
        var contexts: [ContextState]?
    }

    private let lock = OSAllocatedUnfairLock(initialState: PrefsFile())

    private static var docsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private static var prefsURL: URL {
        docsURL.appendingPathComponent("phosphene-prefs.json")
    }

    private static var stateURL: URL {
        docsURL.appendingPathComponent("phosphene-state.json")
    }

    private init() {
        reload()
    }

    // MARK: - Public (Prefs — app → extension)

    var userPaused: Bool {
        lock.withLock { $0.userPaused }
    }

    var alwaysPauseDesktop: Bool {
        lock.withLock { $0.alwaysPauseDesktop }
    }

    var pauseWhenOccluded: Bool {
        lock.withLock { $0.pauseWhenOccluded }
    }

    var desktopOccluded: Bool {
        lock.withLock { $0.desktopOccluded }
    }

    var pausedDisplays: Set<UInt32> {
        lock.withLock { $0.pausedDisplays ?? [] }
    }

    /// How videos fill the screen (fill / scale to height / scale to width / fit /
    /// random), set in the app. Every one of them preserves the aspect ratio.
    var videoScaleMode: VideoScaleMode {
        lock.withLock { VideoScaleMode(rawValue: $0.videoScaleMode ?? "") ?? .fill }
    }

    /// Whether a Phosphene choice is the active screensaver (relayed by the app from
    /// the wallpaper store's Idle sections).
    var screenSaverIsOurs: Bool {
        lock.withLock { $0.screenSaverIsOurs ?? false }
    }

    // MARK: - Public (State — extension → app)

    /// Call when the extension gains or loses active wallpaper contexts.
    func setActive(_ active: Bool) {
        let videoID = active ? WallpaperState.shared.currentVideoID : nil
        let videoName = videoID.flatMap { VideoLibrary.shared.entry(for: $0)?.name }
        let contexts = active ? buildContextStates() : nil
        let state = StateFile(isActive: active, currentVideoID: videoID, currentVideoName: videoName, contexts: contexts)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
        postStateNotification()
        extensionLog("[WallpaperPrefs] setActive(\(active), video: \(videoName ?? "nil"))")
    }

    /// Call when the active video changes while the extension is already active.
    func updateCurrentVideo() {
        let videoID = WallpaperState.shared.currentVideoID
        let videoName = videoID.flatMap { VideoLibrary.shared.entry(for: $0)?.name }
        let contexts = buildContextStates()
        let state = StateFile(isActive: true, currentVideoID: videoID, currentVideoName: videoName, contexts: contexts)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
        postStateNotification()
        traceLog("[WallpaperPrefs] updateCurrentVideo(\(videoName ?? "nil"))")
    }

    private func buildContextStates() -> [ContextState] {
        WallpaperState.shared.activeDisplayContexts().map { ctx in
            let name = ctx.videoID.flatMap { VideoLibrary.shared.entry(for: $0)?.name }
            return ContextState(displayID: ctx.displayID, videoID: ctx.videoID, videoName: name)
        }
    }

    // MARK: - Reload

    func reload() {
        let data: Data
        do {
            data = try Data(contentsOf: Self.prefsURL)
        } catch {
            return // File doesn't exist yet — normal on first launch
        }
        do {
            let prefs = try JSONDecoder().decode(PrefsFile.self, from: data)
            lock.withLock { state in
                state = prefs
            }
            traceLog("[WallpaperPrefs] Loaded: userPaused=\(prefs.userPaused), alwaysPauseDesktop=\(prefs.alwaysPauseDesktop), pauseWhenOccluded=\(prefs.pauseWhenOccluded), desktopOccluded=\(prefs.desktopOccluded)")
        } catch {
            extensionLog("[WallpaperPrefs] Failed to decode prefs: \(error)")
        }
    }

    // MARK: - Darwin Observer

    private var isObservingChanges = false

    func observeChanges() {
        guard !isObservingChanges else { return }
        isObservingChanges = true

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in
                WallpaperPrefs.shared.reload()
                WallpaperPrefs.shared.applyPauseState()
                WallpaperPrefs.shared.applyScaleMode()
            },
            "app.foldwall.prefsChanged" as CFString,
            nil,
            .deliverImmediately,
        )
    }

    func stopObserving() {
        guard isObservingChanges else { return }
        isObservingChanges = false

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            center,
            observer,
            CFNotificationName("app.foldwall.prefsChanged" as CFString),
            nil,
        )
    }

    /// Recompute playback policy and apply to all active renderers.
    /// Uses ramp animation for occlusion transitions (desktop covered/uncovered).
    private var previousDesktopOccluded = false

    private func applyPauseState() {
        let state = WallpaperState.shared
        let occlusionChanged = desktopOccluded != previousDesktopOccluded
        previousDesktopOccluded = desktopOccluded
        let animated = occlusionChanged && pauseWhenOccluded

        let displayIDs = state.uniqueDisplayIDs()
        let currentPausedDisplays = pausedDisplays

        let power = PowerMonitor.shared.currentState

        if displayIDs.isEmpty {
            // No per-display info — apply globally (backward compat)
            let policy = PlaybackPolicy.compute(
                presentationMode: state.presentationMode,
                activityState: state.activityState,
                userPaused: userPaused,
                alwaysPauseDesktop: alwaysPauseDesktop,
                pauseWhenOccluded: pauseWhenOccluded,
                desktopOccluded: desktopOccluded,
                screenSaverIsOurs: screenSaverIsOurs,
                powerState: power,
            )
            state.forEachRenderer { renderer in
                renderer.applyPolicy(policy, animated: animated)
            }
        } else {
            for displayID in displayIDs {
                let isDisplayPaused = currentPausedDisplays.contains(displayID)
                let policy = PlaybackPolicy.compute(
                    presentationMode: state.presentationMode,
                    activityState: state.activityState,
                    userPaused: userPaused || isDisplayPaused,
                    alwaysPauseDesktop: alwaysPauseDesktop,
                    pauseWhenOccluded: pauseWhenOccluded,
                    desktopOccluded: desktopOccluded,
                    screenSaverIsOurs: screenSaverIsOurs,
                    powerState: power,
                )
                state.forRenderers(displayID: displayID) { renderer in
                    renderer.applyPolicy(policy, animated: animated)
                }
            }
        }
    }

    /// Push the current scale mode onto every live surface. Cheap (a gravity write per
    /// layer, no decoder work), so the user sees the change while the video keeps
    /// playing rather than after the next switch.
    private func applyScaleMode() {
        let mode = videoScaleMode
        WallpaperState.shared.forEachSurface { rootLayer, renderer, videoID in
            // The renderer knows which file it is actually playing, so let it resolve
            // `random` and follow its answer on the root layer (which holds the cached
            // still under the video). No renderer yet → resolve from the choice id.
            let resolved = renderer?.applyScaleMode(mode)
                ?? mode.resolved(seed: videoID ?? "")
                    .resolved(still: stillImage(of: rootLayer),
                              surface: rootLayer.bounds.size)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            rootLayer.contentsGravity = resolved.contentsGravity
            CATransaction.commit()
            CATransaction.flush()
        }
        extensionLog("[WallpaperPrefs] Scale mode → \(mode.rawValue)")
    }

    private func postStateNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("app.foldwall.stateChanged" as CFString),
            nil,
            nil,
            true,
        )
    }
}
