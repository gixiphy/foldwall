//  DesktopVideoEngine.swift
//  用桌面層級的 NSWindow 播影片。每台螢幕一個視窗。
//
//  做法參考 wallpaper-play（MIT）：borderless window 壓在桌面圖示層附近、
//  collectionBehavior 讓它跟著所有 Space、hitTest 回 nil 讓點擊穿透。
//  全部是公開 API——這是它相對於私有 WallpaperExtensionKit 的主要價值。
//
//  沒有拷貝：播放器直接吃來源 URL，SMB、雲端掛載點、遠端 http 串流都行。
//
//  **視窗裡放的播放器是可以抽換的**（見 DesktopPlaybackSurface）：預設 AVPlayer，
//  使用者裝了 mpv 可以改用它。這一層只管視窗、每台螢幕的 session、排片預約、
//  看門狗與事件紀錄；載入、播放、定位、縮放是 surface 的事。
//  mpv 載不起來（沒裝、相依斷了、版本不合）就回退到 AVPlayer，**回退一次就記住**，
//  不會因為一次掉幀在兩個核心之間來回跳；原因留給設定頁顯示。
//
//  **一支播完之後怎麼辦有兩種建法，決定在 load 的當下**（見 VideoPlaybackMode）：
//  單片循環無縫接回開頭、永遠不會發播畢通知；其餘模式播完停在最後一格，回報上層，
//  由上層決定下一支是哪一支：挑哪支要看模式、要避開別台正在播的、還要看冷卻名單，
//  那些都不是引擎的事。
//
//  **播不動要有人知道。** 桌布是無人看管的東西：來源掉線、串流網址失效、檔案壞掉，
//  預設行為就是停在那裡黑畫面，永遠不會自己恢復。所以這裡有一條看門狗，
//  由上層把壞掉那支冷卻、改播別的（見 PlaybackCooldown）。
//
//  **它只認明確的錯誤，不用「停太久」當判斷依據。** 試過那條路，會誤殺：
//  桌布視窗被其他視窗完全遮住時 macOS 判定 occluded 並讓 AVPlayer 停下來、
//  換片的空檔、系統節流——全都會讓播放器離開「播放中」，而畫面其實是好的。
//  唯一沒有歧義的「還在等資料」是 surface 的 `isWaitingForData`，只有那個卡太久才算數。

import AppKit
import FoldwallCore

private final class DesktopVideoWindow: NSWindow {

    init(screen: NSScreen, layer: DesktopVideoLayer, content: NSView) {
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

        content.frame = NSRect(origin: .zero, size: screen.frame.size)
        content.autoresizingMask = [.width, .height]
        contentView = content

        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 使用者選的核心、實際在用的核心、以及兩者不同時的原因。設定頁與診斷報告用。
struct DesktopPlaybackCoreStatus: Equatable {
    var requested: DesktopPlaybackCore
    var effective: DesktopPlaybackCore
    /// 選了 mpv 卻用不上的原因。`nil` 就是選什麼用什麼。
    var failure: MPVRuntime.LoadFailure?
}

@MainActor
final class DesktopVideoEngine {

    private struct Playing {
        var window: DesktopVideoWindow
        var surface: any DesktopPlaybackSurface
        var url: URL
        /// 這一支是第幾次播放。**每次 start／換片／播畢前進都 +1。**
        ///
        /// 為什麼不夠用 URL 比對：同一支被重播（池裡只剩它、或隨機又抽到它）時
        /// 前後兩輪的 URL 一樣，遲到的通知就分不出是哪一輪的。
        var session: Int
        /// 片源在哪。決定預讀多少，也是診斷「不定時停一下」的第一個線索。
        var location: VideoSourceLocation
        /// 已經備好、排在佇列裡的下一支。播完就直接接上，不必當場開檔。
        var preloaded: URL?
        /// 視窗是照哪個圖層設定建的。視窗層級只在 init 設得了，改了就得重建視窗。
        var layer: DesktopVideoLayer
        /// 使用者要的縮放，`random` 已經抽定；可能還是「填滿高度／寬度」。
        var scale: VideoScaleMode
        /// 真的設進 surface 的那個（fill 或 fit）。存起來才知道要不要動——
        /// 每輪都寫一次不會壞，但寫了就看不出「改過」與「沒改」的差別。
        var applied: VideoScaleMode
        /// 影片的寬÷高，**已套用旋轉**。拿到第一格的畫面尺寸之前是 nil，
        /// 「填滿高度／寬度」在那之前只能先用 fill 頂著。
        var videoAspect: Double?
        /// 視窗被遮蔽／露出的觀察者。AVPlayer 被完全遮住時系統會自己讓它停下，
        /// mpv 加 OpenGL 沒有這回事——所以 mpv 那條由我們自己在遮住時暫停（見 `shouldRun`）。
        var occlusionObserver: (any NSObjectProtocol)?
        /// 視窗現在被完全遮住（全螢幕視窗蓋著、切到別的全螢幕 Space）。
        var occluded = false
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
    /// 現在這批視窗裡是哪個核心。跟 `apply` 傳進來的不一樣就整批換，盡量保留時間點。
    private var activeCore: DesktopPlaybackCore = .avPlayer
    /// 選了 mpv 卻用不上：這個行程裡就用 AVPlayer 頂著，直到使用者再動核心設定。
    private var mpvFallback: MPVRuntime.LoadFailure?
    /// 發過幾次播放 session。全域遞增，不重複使用。
    private var sessionCounter = 0
    /// mpv 在播的時候宣告的背景活動：擋 App Nap，**不擋系統睡眠**（桌布不該讓電腦
    /// 睡不著）。AVPlayer 自己會宣告，這條只給 mpv；暫停、遮住、全部停掉就收回。
    private var activity: (any NSObjectProtocol)?

    /// 播放事件。兩條引擎記同一種格式（見 PlaybackEvent），診斷報告才拼得起來。
    private(set) var events = PlaybackEventLog()

    /// 這支播不動了。上層據此冷卻該 URL 並重新排片。
    var onPlaybackFailed: ((URL, String) -> Void)?

    /// 這支播完了（螢幕 UUID、剛播完的 URL）。上層據此更新狀態。
    /// 單片循環不會發這個——那條路無縫接回開頭。
    var onVideoEnded: ((String, URL) -> Void)?

    /// **這台螢幕接下來要播哪一支**（螢幕 UUID、正在播的那支）→ 下一支。
    ///
    /// 為什麼引擎要提前問：換片本來是「播完 → 通知上層 → 上層排片 → 開新檔」，
    /// 那一串全部發生在最後一格播完之後，中間的開檔時間就是看得見的停頓——
    /// 走 SMB 或串流時更明顯。改成一開始播就先問好、把下一支排進佇列，
    /// 接縫的成本就只剩播放器自己的切換。
    ///
    /// **挑哪一支仍然不是引擎的事**：要看播放模式、要避開別台正在播的、
    /// 還要看冷卻名單。回 nil 就是「沒有下一支」，播完停在最後一格。
    var nextVideoProvider: ((String, URL) -> URL?)?

    /// 核心狀態變了（第一次決定、或回退到 AVPlayer）。設定頁靠這個顯示原因。
    var onCoreStatusChanged: ((DesktopPlaybackCoreStatus) -> Void)?

    /// 目前有幾台螢幕在播。
    var activeCount: Int { playing.count }

    /// 螢幕 → 正在播的影片。排片時用來沿用，不要每輪重選。
    var playingURLs: [String: URL] { playing.mapValues(\.url) }

    /// 使用者選的、實際在用的、以及回退的原因。還沒播過任何東西時只反映載入結果。
    private(set) var coreStatus = DesktopPlaybackCoreStatus(requested: .avPlayer, effective: .avPlayer)

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
            .flatMap { [$0.url] + ($0.preloaded.map { [$0] } ?? []) })
    }

    /// 讓畫面符合 `plan`：沒在計畫裡的關掉，換片的重建，沒變的留著。
    func apply(plan: [String: URL], layer: DesktopVideoLayer, screens: [DisplayTarget],
               mode: VideoPlaybackMode, scale: VideoScaleMode,
               core requestedCore: DesktopPlaybackCore = .avPlayer) {
        // 循環方式是**建 player 當下**決定的（走不走 AVPlayerLooper），改不動已經在跑的
        // 那個。所以模式一換就整批重建——這是使用者剛動過手的那一刻，重播一次不突兀。
        if mode != activeMode {
            let loop = !mode.advancesAtEnd
            // mpv 的 loop-file 是可即時改的屬性，改完接著播；AVPlayer 那條是建 player
            // 當下決定的，只能整批重建（使用者剛動過手的那一刻，重播一次不突兀）。
            let live = !playing.isEmpty && playing.values.allSatisfy { $0.surface.setLoop(loop) }
            activeMode = mode
            if live {
                for uuid in playing.keys.sorted() {
                    if loop {
                        playing[uuid]?.preloaded = nil
                        if playing[uuid]?.ended == true { replay(uuid) }
                    } else {
                        preloadNext(uuid)
                    }
                }
                Log.video.info("桌面視窗即時改播放模式：\(mode.displayName, privacy: .public)")
            } else {
                stopAll()
            }
        }
        // 換核心：只作用於影片視窗，不重跑蒙太奇；同一支從同一秒接著播。
        var resume: [String: (url: URL, seconds: Double?)] = [:]
        let core = resolveCore(requestedCore)
        if core != activeCore {
            activeCore = core
            resume = playing.mapValues { ($0.url, $0.surface.currentSeconds) }
            stopAll()
            Log.video.info("桌面視窗換核心：\(core.rawValue, privacy: .public)")
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
                // 縮放改得動已經在播的那個（不像循環方式），所以只設縮放，
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
            // AVPlayer 只有「播完接下一支」那條路這樣做。單片循環的 player 身上掛著
            // AVPlayerLooper，它的 disableLooping 有沒有立刻把佇列清乾淨沒有保證，
            // 在同一個 player 上接著建第二個 looper 是在賭。那條路換片是使用者
            // 按「下一片」的偶發動作，閃一下換整批重建的確定性，划得來。
            // mpv 的 loop-file 是可即時改的屬性，沒有這個限制。
            if let current = playing[uuid], current.layer == layer,
               mode.advancesAtEnd || current.surface.canSwitchWhileLooping {
                switchVideo(uuid, to: url, screen: screen, mode: mode, scale: scale)
                continue
            }
            teardown(uuid)
            let startAt = resume[uuid]?.url == url ? resume[uuid]?.seconds : nil
            start(url: url, uuid: uuid, screen: screen, layer: layer, mode: mode, scale: scale,
                  startAt: startAt)
        }
    }

    func stopAll() {
        for uuid in playing.keys { teardown(uuid) }
    }

    /// 使用者又動了核心設定：上次的回退不算數，下一輪重新試。
    func resetCoreFallback() {
        mpvFallback = nil
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
                       detail: paused ? String(localized: "暫停") : String(localized: "恢復"))
            }
            applyRunState(uuid)
            // 恢復播放＝重新開始計時，不要把暫停那段算進去。
            // **只在真的從暫停恢復時才重設**：每輪排片都會呼叫一次 setPaused(false)，
            // 以前每次都歸零，診斷裡「已播 N 秒」永遠不會超過兩輪 refresh 的間隔，
            // 進行中的停頓也會被抹掉起點、量不出長度。
            if changed, !paused {
                playing[uuid]?.waitingSince = nil
                playing[uuid]?.startedAt = .now
            }
        }
    }

    /// 這台現在該不該真的在跑：政策沒暫停、沒播完，而且（mpv）沒被完全遮住。
    ///
    /// 播完停在最後一格的不要 play()：它在等上層排下一支，叫 play 只會讓 rate 空轉。
    /// 沒暫停過也照樣 play()：對 AVPlayer 是冪等的，而它是被系統因遮蔽停下之後
    /// 唯一會再推它一下的地方。mpv 被遮住時系統不會替它停，所以我們自己停——
    /// 全螢幕視窗蓋著時照樣解碼加渲染，那是白燒的電。
    private func shouldRun(_ entry: Playing) -> Bool {
        !isPolicyPaused && !entry.ended && !(entry.occluded && entry.surface.core == .mpv)
    }

    private func applyRunState(_ uuid: String) {
        guard let entry = playing[uuid] else { return }
        if shouldRun(entry) { entry.surface.play() } else { entry.surface.pause() }
        updateActivity()
    }

    /// mpv 有東西在跑就宣告活動、沒有就收回。`userInitiatedAllowingIdleSystemSleep`：
    /// 擋 App Nap 與自動終止，但**允許系統照常睡**。
    private func updateActivity() {
        let wanted = playing.values.contains { $0.surface.core == .mpv && shouldRun($0) }
        if wanted, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Foldwall desktop video (mpv)")
        } else if !wanted, let token = activity {
            ProcessInfo.processInfo.endActivity(token)
            activity = nil
        }
    }

    // MARK: - 核心

    /// 使用者要哪個、實際給哪個。mpv 載不起來就回退，**回退一次就記住**。
    private func resolveCore(_ requested: DesktopPlaybackCore) -> DesktopPlaybackCore {
        var effective = requested
        var failure: MPVRuntime.LoadFailure?
        if requested == .mpv {
            if let fallback = mpvFallback {
                failure = fallback
            } else if let loadFailure = MPVLibrary.outcome.failure {
                mpvFallback = loadFailure
                failure = loadFailure
            }
            if failure != nil { effective = .avPlayer }
        }
        let status = DesktopPlaybackCoreStatus(requested: requested, effective: effective, failure: failure)
        if status != coreStatus {
            coreStatus = status
            onCoreStatusChanged?(status)
        }
        return effective
    }

    /// 建這台螢幕的播放器。mpv 建不起來（core、render context）就記住原因、改建 AVPlayer。
    private func makeSurface(uuid: String, screen: NSScreen, loop: Bool) -> any DesktopPlaybackSurface {
        let frame = NSRect(origin: .zero, size: screen.frame.size)
        if activeCore == .mpv, let library = MPVLibrary.outcome.loaded {
            do {
                return try MPVSurface(uuid: uuid, frame: frame, library: library.handle, loop: loop)
            } catch {
                let reason = error.localizedDescription
                Log.video.error("mpv 建不起來，改用 AVPlayer：\(reason, privacy: .public)")
                mpvFallback = .coreFailed(reason)
                activeCore = .avPlayer
                _ = resolveCore(.mpv)
            }
        }
        return AVPlayerSurface(uuid: uuid, frame: frame)
    }

    // MARK: - 診斷

    /// 可匯出的播放報告。**取不到的一律標成未知**，不要拿「播放進度正常」
    /// 當成沒有掉幀——那是兩件事。
    func diagnosticsReport() -> String {
        var lines: [String] = []
        lines.append("- " + String(localized: "選用的核心：\(coreStatus.requested.displayName)"))
        lines.append("- " + String(localized: "實際核心：\(coreStatus.effective.displayName)"))
        if let failure = coreStatus.failure {
            lines.append("- " + String(localized: "回退原因：\(Self.describe(failure))"))
        }
        if let loaded = MPVLibrary.loadedIfAny {
            let version = loaded.version ?? String(localized: "未知")
            lines.append("- " + String(localized: "載入中的 libmpv：\(version)（\(loaded.path.path)）"))
        }
        lines.append("")
        if events.droppedCount > 0 {
            let dropped = events.droppedCount
            lines.append(String(localized: "（紀錄有上限，較早的 \(dropped) 則已被擠掉）"))
            lines.append("")
        }
        for (uuid, entry) in playing.sorted(by: { $0.key < $1.key }) {
            let stalls = events.stallSummary(surface: uuid)
            let buffer = Int(VideoBufferPolicy.forwardBufferSeconds(for: entry.location))
            let elapsed = Int(Date.now.timeIntervalSince(entry.startedAt))
            let total = String(format: "%.1f", stalls.totalSeconds)
            let count = stalls.count
            lines.append("### \(String(localized: "螢幕")) \(uuid)")
            lines.append("- " + String(localized: "影片：\(entry.url.lastPathComponent)"))
            lines.append("- " + String(localized: "來源位置：\(entry.location.displayName)"))
            lines.append("- " + String(localized: "預讀上限：\(buffer) 秒"))
            lines.append("- " + String(localized: "播放 session：\(entry.session)"))
            lines.append("- " + String(localized: "已播：\(elapsed) 秒"))
            lines.append("- " + String(localized: "停頓：\(count) 次，共 \(total) 秒")
                + (stalls.unmatched > 0
                   ? String(localized: "（另有 \(stalls.unmatched) 次長度未知）") : ""))
            // 政策暫停跟停頓分開講：睡一整晚不是播放器卡住。
            let paused = events.pausedSummary(surface: uuid)
            let pausedTotal = String(format: "%.0f", paused.totalSeconds)
            let pausedCount = paused.count
            lines.append("- " + String(localized: "政策暫停：\(pausedCount) 次，共 \(pausedTotal) 秒")
                + (paused.ongoing ? String(localized: "（進行中）") : "")
                + (entry.occluded ? String(localized: "，視窗目前被完全遮住") : ""))
            lines.append("- " + String(localized: "下一支已預載：\(entry.preloaded?.lastPathComponent ?? String(localized: "無"))"))
            lines.append(contentsOf: entry.surface.diagnosticLines())
            lines.append("")
        }
        if playing.isEmpty {
            lines.append(String(localized: "目前沒有螢幕在播影片。"))
            lines.append("")
        }
        lines.append("<details><summary>" + String(localized: "桌面視窗事件明細") + "</summary>")
        lines.append("")
        for event in events.all.suffix(120) {
            let stamp = event.at.formatted(date: .omitted, time: .standard)
            lines.append("- \(stamp) [\(event.surface)#\(event.session)] \(event.kind.rawValue)"
                + (event.detail.map { "：\($0)" } ?? ""))
        }
        lines.append("")
        lines.append("</details>")
        return lines.joined(separator: "\n")
    }

    /// 回退原因的一句話，連同能修的那行指令。
    static func describe(_ failure: MPVRuntime.LoadFailure) -> String {
        let text: String = switch failure {
        case .notInstalled:
            String(localized: "沒有找到 libmpv")
        case .dependencyMissing(let path):
            String(localized: "libmpv 的相依找不到：\(path ?? String(localized: "未知"))")
        case .apiVersionMismatch(let found, let expected):
            String(localized: "libmpv 的 API 主版號是 \(found >> 16)，需要 \(expected >> 16)")
        case .tooOld(let installed, let minimum):
            String(localized: "libmpv \(installed.description) 太舊，至少要 \(minimum.description)")
        case .coreFailed(let message):
            String(localized: "mpv 建不起來：\(message)")
        }
        if let command = failure.brewCommand { return "\(text)（\(command)）" }
        return text
    }

    private func engineLabel(for entry: Playing) -> String {
        entry.surface.core == .mpv ? MPVRuntime.engineLabel : VideoEngine.desktopWindow.rawValue
    }

    private func record(_ kind: PlaybackEvent.Kind, entry: Playing, surface: String,
                        detail: String? = nil) {
        events.record(PlaybackEvent(
            kind: kind, engine: engineLabel(for: entry), surface: surface,
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
            // 遮蔽通知偶爾不來（實測四次有三次沒收到）：每輪順手對一次實際狀態，
            // 最多慢 10 秒，不會讓 mpv 在全螢幕視窗底下白燒一整天。
            reconcileOcclusion(uuid)

            // 明確失敗：壞檔、網址 404、憑證錯誤都走這裡。這是唯一沒有歧義的訊號。
            if let reason = entry.surface.explicitFailure {
                handleFailure(uuid, entry: entry, reason: reason)
                continue
            }

            // **只有「想播但沒資料」算在等。** 被遮住、被節流、換片空檔都不算，
            // 而畫面其實好好的。
            guard entry.surface.isWaitingForData else {
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
        record(.recovered, entry: entry, surface: uuid,
               detail: String(localized: "就地重建：\(reason)"))
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

    private func start(url: URL, uuid: String, screen: NSScreen, layer: DesktopVideoLayer,
                       mode: VideoPlaybackMode, scale: VideoScaleMode, startAt: Double? = nil) {
        sessionCounter += 1
        let session = sessionCounter
        let location = VideoBufferPolicy.location(for: url)
        let surface = makeSurface(uuid: uuid, screen: screen, loop: !mode.advancesAtEnd)
        surface.delegate = self

        let wanted = Self.resolve(scale, uuid: uuid, url: url)
        // 第一格解出來之前不知道影片多寬多高，先用 fill 頂著（＝舊行為，不留黑邊），
        // 一拿到畫面尺寸就改成該有的那個。改縮放不必重播。
        let applied = wanted.resolved(videoAspect: nil, screenAspect: Self.aspect(of: screen))
        let window = DesktopVideoWindow(screen: screen, layer: layer, content: surface.view)
        surface.setScale(applied)
        window.orderFront(nil)
        surface.load(url, location: location, loop: !mode.advancesAtEnd, startAt: startAt)

        playing[uuid] = Playing(window: window, surface: surface, url: url, session: session,
                                location: location, preloaded: nil, layer: layer,
                                scale: wanted, applied: applied,
                                occlusionObserver: observeOcclusion(of: window, uuid: uuid),
                                startedAt: .now, frame: screen.frame)
        if let entry = playing[uuid] {
            record(.started, entry: entry, surface: uuid,
                   detail: startAt.map { String(localized: "從 \(String(format: "%.1f", $0)) 秒接著播") })
        }
        applyRunState(uuid)
        startWatchdogIfNeeded()
        preloadNext(uuid)
        Log.video.info(
            "桌面視窗開始播：\(url.lastPathComponent, privacy: .public)（\(surface.core.rawValue, privacy: .public)、\(mode.displayName, privacy: .public)、\(location.displayName, privacy: .public)）")
    }

    /// 換片，但留著視窗與 player。畫面上停在前一支的最後一格，直到新的第一格解出來——
    /// 比拆掉視窗重建（中間是黑的）好得多。
    private func switchVideo(_ uuid: String, to url: URL, screen: NSScreen,
                             mode: VideoPlaybackMode, scale: VideoScaleMode) {
        guard let entry = playing[uuid] else { return }

        // 已經備好的就是它：直接接上，不必再開一次檔。
        if entry.preloaded == url, entry.surface.hasPreloaded {
            entry.surface.advanceToPreloaded()
            adoptPreloaded(uuid)
            reframe(uuid, to: screen)
            applyScale(scale, to: uuid, url: url, screen: screen)
            applyRunState(uuid)
            preloadNext(uuid)
            return
        }

        sessionCounter += 1
        let session = sessionCounter
        let location = VideoBufferPolicy.location(for: url)

        reframe(uuid, to: screen)
        // 隨機縮放是「每支各抽一種」，換片就得重抽——這裡是新的那支。
        // 長寬比也跟著歸零：上一支的比例套在新的那支身上會框錯。
        let wanted = Self.resolve(scale, uuid: uuid, url: url)
        let applied = wanted.resolved(videoAspect: nil, screenAspect: Self.aspect(of: screen))
        entry.surface.setScale(applied)
        entry.surface.load(url, location: location, loop: !mode.advancesAtEnd, startAt: nil)
        playing[uuid]?.url = url
        playing[uuid]?.session = session
        playing[uuid]?.location = location
        playing[uuid]?.preloaded = nil
        playing[uuid]?.scale = wanted
        playing[uuid]?.applied = applied
        playing[uuid]?.videoAspect = nil
        playing[uuid]?.startedAt = .now
        playing[uuid]?.waitingSince = nil
        playing[uuid]?.ended = false
        playing[uuid]?.rebuildAttempts = 0
        if let updated = playing[uuid] { record(.switched, entry: updated, surface: uuid) }
        applyRunState(uuid)
        preloadNext(uuid)
        Log.video.info("桌面視窗換片：\(url.lastPathComponent, privacy: .public)")
    }

    /// 先問好下一支是哪一支，把它排進佇列。
    ///
    /// 這是「換片停頓」的解法：開檔、讀檔頭、解第一格本來全發生在最後一格
    /// 播完之後，走 SMB 或串流時那段就是看得見的黑或凍。提前排進佇列之後，
    /// 播放器會自己預先準備，接縫只剩佇列切換。
    private func preloadNext(_ uuid: String) {
        guard let entry = playing[uuid], activeMode.advancesAtEnd else { return }
        guard let provider = nextVideoProvider,
              let next = provider(uuid, entry.url), next != entry.preloaded else { return }

        let location = VideoBufferPolicy.location(for: next)
        guard entry.surface.preload(next, location: location) else { return }
        playing[uuid]?.preloaded = next
        Log.video.debug("預載下一支：\(next.lastPathComponent, privacy: .public)")
    }

    /// 已預載的那支接上了（播完自動接、或使用者按「下一片」）：把帳更新過來。
    private func adoptPreloaded(_ uuid: String) {
        guard let entry = playing[uuid], let next = entry.preloaded else { return }
        sessionCounter += 1
        let newSession = sessionCounter
        entry.surface.adoptPreloaded()

        playing[uuid]?.url = next
        playing[uuid]?.session = newSession
        playing[uuid]?.location = VideoBufferPolicy.location(for: next)
        playing[uuid]?.preloaded = nil
        playing[uuid]?.startedAt = .now
        playing[uuid]?.waitingSince = nil
        playing[uuid]?.ended = false
        playing[uuid]?.rebuildAttempts = 0
        playing[uuid]?.videoAspect = nil
        // 新的那支要重抽縮放（`random` 是每支各抽一種），長寬比也歸零。
        if let screen = entry.window.screen ?? NSScreen.main {
            let wanted = Self.resolve(entry.scale, uuid: uuid, url: next)
            let applied = wanted.resolved(videoAspect: nil, screenAspect: Self.aspect(of: screen))
            playing[uuid]?.scale = wanted
            playing[uuid]?.applied = applied
            entry.surface.setScale(applied)
        }
        if let updated = playing[uuid] {
            record(.switched, entry: updated, surface: uuid,
                   detail: String(localized: "預載接上，無停頓"))
        }
    }

    /// 從頭再播一次同一支：上層排的「下一支」就是它自己（池裡只剩這支，
    /// 或隨機又抽到它）。不重建 player，省一次解碼器初始化。
    private func replay(_ uuid: String) {
        guard let entry = playing[uuid] else { return }
        playing[uuid]?.ended = false
        playing[uuid]?.startedAt = .now
        playing[uuid]?.waitingSince = nil
        entry.surface.replay()
        applyRunState(uuid)
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

    /// 把縮放套到正在播的那台。已經是這個縮放就不動——寫一次不貴，
    /// 但每輪 refresh 都碰會讓「真的改過」在 log 與除錯時看不出來。
    private func applyScale(_ scale: VideoScaleMode, to uuid: String, url: URL,
                            screen: NSScreen) {
        guard let entry = playing[uuid] else { return }
        let wanted = Self.resolve(scale, uuid: uuid, url: url)
        playing[uuid]?.scale = wanted
        let applied = wanted.resolved(videoAspect: entry.videoAspect,
                                      screenAspect: Self.aspect(of: screen))
        guard applied != entry.applied else { return }
        entry.surface.setScale(applied)
        playing[uuid]?.applied = applied
        Log.video.info(
            "影片縮放改為 \(wanted.displayName, privacy: .public)（\(applied.rawValue, privacy: .public)）")
    }

    /// `random` 在這裡抽定：seed 是「螢幕 ＋ 影片」，所以同一支在同一台螢幕上
    /// 每次算出來都一樣，重新排片不會讓播到一半的影片突然換一種縮放。
    /// **「填滿高度／寬度」不在這裡化簡**——那要等長寬比，見 `surface(_:didLearnAspect:)`。
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

    /// 把記下來的遮蔽狀態對到視窗實際的狀態；不一樣就當成剛收到通知處理。
    private func reconcileOcclusion(_ uuid: String) {
        guard let entry = playing[uuid] else { return }
        let visible = entry.window.occlusionState.contains(.visible)
        guard entry.occluded == visible else { return }
        playing[uuid]?.occluded = !visible
        record(.policyChanged, entry: entry, surface: uuid,
               detail: visible ? String(localized: "視窗露出") : String(localized: "視窗被完全遮住"))
        applyRunState(uuid)
    }

    /// 視窗被完全遮住／又露出來。AVPlayer 被遮住時系統會讓它停下（免費省電），
    /// mpv 加 OpenGL 沒有這回事——照樣解碼加渲染，所以 mpv 那條由我們自己停
    /// （`shouldRun`）。區間也記進事件，能耗比較才對得上時間。
    private func observeOcclusion(of window: NSWindow, uuid: String) -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor [weak self] in
                guard let self, window != nil else { return }
                reconcileOcclusion(uuid)
            }
        }
    }

    private func teardown(_ uuid: String) {
        guard let entry = playing.removeValue(forKey: uuid) else { return }
        if let observer = entry.occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        entry.surface.teardown()
        entry.window.orderOut(nil)
        entry.window.close()
        events.record(PlaybackEvent(
            kind: .released, engine: engineLabel(for: entry), surface: uuid,
            session: entry.session, sourceKey: entry.url.absoluteString))
        stopWatchdogIfIdle()
        updateActivity()
    }

    private static func screen(for target: DisplayTarget) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDirectDisplayID(number.uint32Value) == target.id
        }
    }
}

// MARK: - surface 的事件

extension DesktopVideoEngine: DesktopPlaybackSurfaceDelegate {

    /// 播完了。
    ///
    /// 有預載的話播放器已經自己接上去了，這裡只是把帳更新過來、再排下一支。
    /// 沒有預載就停在最後一格，通知上層排片。
    ///
    /// 這裡**不自己挑下一支**：挑哪支要看播放模式、要避開別台螢幕正在播的、
    /// 還要看冷卻名單——那些都在上層，由 `nextVideoProvider` 回答。
    func surfaceDidReachEnd(_ uuid: String) {
        guard let entry = playing[uuid], !entry.ended else { return }
        let finished = entry.url

        guard entry.preloaded != nil else {
            playing[uuid]?.ended = true
            record(.loopBoundary, entry: entry, surface: uuid,
                   detail: String(localized: "沒有下一支，停在最後一格"))
            Log.video.info("播畢：\(finished.lastPathComponent, privacy: .public)")
            onVideoEnded?(uuid, finished)
            return
        }

        adoptPreloaded(uuid)
        let next = playing[uuid]?.url.lastPathComponent ?? ""
        Log.video.info(
            "播畢，接上預載：\(finished.lastPathComponent, privacy: .public) → \(next, privacy: .public)")
        onVideoEnded?(uuid, finished)
        preloadNext(uuid)
    }

    /// 知道影片多寬多高了 → 「填滿高度／寬度」這時才算得出要 fill 還是 fit。
    func surface(_ uuid: String, didLearnAspect aspect: Double) {
        guard let entry = playing[uuid] else { return }
        playing[uuid]?.videoAspect = aspect
        guard entry.scale.needsVideoAspect,
              let screen = entry.window.screen ?? NSScreen.main else { return }
        let applied = entry.scale.resolved(videoAspect: aspect,
                                           screenAspect: Self.aspect(of: screen))
        guard applied != entry.applied else { return }
        entry.surface.setScale(applied)
        playing[uuid]?.applied = applied
        Log.video.info(
            "影片長寬比 \(aspect, format: .fixed(precision: 2), privacy: .public)：\(entry.scale.displayName, privacy: .public) → \(applied.rawValue, privacy: .public)")
    }

    func surfaceDidShowFirstFrame(_ uuid: String) {
        guard let entry = playing[uuid] else { return }
        let seconds = Date.now.timeIntervalSince(entry.startedAt)
        record(.firstFrame, entry: entry, surface: uuid,
               detail: String(localized: "出畫 \(String(format: "%.2f", seconds)) 秒"))
    }

    func surface(_ uuid: String, didStall reason: String?) {
        // 只有「想播但沒資料」算停頓；已經在停頓中就不重複記。
        guard let entry = playing[uuid], entry.waitingSince == nil else { return }
        playing[uuid]?.waitingSince = .now
        record(.stalled, entry: entry, surface: uuid,
               detail: reason ?? String(localized: "原因未知"))
    }

    func surfaceDidResume(_ uuid: String) {
        guard let entry = playing[uuid], let since = entry.waitingSince else { return }
        let seconds = Date.now.timeIntervalSince(since)
        playing[uuid]?.waitingSince = nil
        record(.resumed, entry: entry, surface: uuid,
               detail: String(localized: "停頓 \(String(format: "%.2f", seconds)) 秒"))
    }

    func surface(_ uuid: String, didFail reason: String, blamesSource: Bool) {
        guard let entry = playing[uuid] else { return }
        // 不是影片的錯（視訊輸出建不起來）：這不能冷卻影片，也不該用同一個核心
        // 再試——換 AVPlayer 頂著，同一支從同一秒接著播，原因留給設定頁。
        if !blamesSource, entry.surface.core == .mpv {
            fallbackToAVPlayer(uuid, entry: entry, reason: reason)
            return
        }
        handleFailure(uuid, entry: entry, reason: reason)
    }

    private func fallbackToAVPlayer(_ uuid: String, entry: Playing, reason: String) {
        Log.video.error("mpv 播放器自己出錯，改用 AVPlayer：\(reason, privacy: .public)")
        record(.recovered, entry: entry, surface: uuid,
               detail: String(localized: "mpv 出錯，改用 AVPlayer：\(reason)"))
        mpvFallback = .coreFailed(reason)
        activeCore = .avPlayer
        _ = resolveCore(coreStatus.requested)
        let seconds = entry.surface.currentSeconds
        guard let screen = entry.window.screen ?? NSScreen.main else {
            teardown(uuid)
            return
        }
        teardown(uuid)
        start(url: entry.url, uuid: uuid, screen: screen, layer: entry.layer, mode: activeMode,
              scale: entry.scale, startAt: seconds)
    }
}
