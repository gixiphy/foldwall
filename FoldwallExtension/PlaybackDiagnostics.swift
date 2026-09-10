import Foundation
import os

/// The extension's half of the playback diagnostics.
///
/// The renderer lives in a sandboxed appex the user never sees a window of, so a
/// stutter there leaves no trace the app can read: `extensionLog` goes to the unified
/// log, which is fine for a developer and useless for "the wallpaper judders on some
/// videos". This collects the same `PlaybackEvent` records the desktop-window engine
/// keeps, and writes them where the app can pick them up.
///
/// **The transport is the one that already exists.** The app writes videos and prefs
/// straight into this container's Documents (see `ExtensionPrefs`); this goes the other
/// way through the same directory. No new XPC surface, nothing to keep in sync with the
/// private WallpaperExtensionKit ABI.
///
/// Writing is on demand: the app posts a Darwin notification, we dump the ring buffer
/// once. A wallpaper runs for days, so a write per event would be a steady trickle of
/// disk traffic for a report nobody is reading yet.
final class PlaybackDiagnostics: @unchecked Sendable {

    static let shared = PlaybackDiagnostics()

    /// Posted by the app to ask for a fresh dump.
    static let requestNotification = "app.foldwall.requestPlaybackDiagnostics"
    /// Posted by us once the file is on disk, so the app doesn't have to poll blindly.
    static let readyNotification = "app.foldwall.playbackDiagnosticsReady"

    private let log = OSAllocatedUnfairLock(initialState: PlaybackEventLog())
    private let queue = DispatchQueue(label: "app.foldwall.diagnostics", qos: .utility)

    private var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
            .appendingPathComponent("playback-diagnostics.json")
    }

    private init() {}

    func record(_ event: PlaybackEvent) {
        log.withLock { $0.record(event) }
    }

    /// Convenience for the renderer, which knows its surface and session but not the
    /// engine identifier or the current policy.
    func record(_ kind: PlaybackEvent.Kind, surface: String, session: Int,
                sourceKey: String?, policy: String?, detail: String? = nil) {
        record(PlaybackEvent(kind: kind, engine: "systemExtension", surface: surface,
                             session: session, sourceKey: sourceKey, policy: policy,
                             detail: detail))
    }

    /// Start answering the app's requests. Call once at extension startup.
    func observeRequests() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, _, _, _ in PlaybackDiagnostics.shared.flush() },
            Self.requestNotification as CFString,
            nil,
            .deliverImmediately,
        )
    }

    /// Dump the ring buffer to the container. Cheap enough to call on a request;
    /// **not** something to call per event.
    func flush() {
        queue.async { [self] in
            let snapshot = log.withLock { current in
                Snapshot(writtenAt: .now, droppedCount: current.droppedCount,
                         events: current.all)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            do {
                try data.write(to: fileURL, options: .atomic)
            } catch {
                extensionLog("[Diagnostics] write failed: \(error.localizedDescription)")
                return
            }
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(Self.readyNotification as CFString), nil, nil, true)
        }
    }

    /// What lands on disk. Field names are the contract with the app side
    /// (`ExtensionDiagnostics` over there) — changing one means changing both.
    struct Snapshot: Codable, Sendable {
        var writtenAt: Date
        /// How many records the ring buffer already discarded. The app has to say so
        /// in the report, otherwise the reader assumes they are looking at everything.
        var droppedCount: Int
        var events: [PlaybackEvent]
    }
}
