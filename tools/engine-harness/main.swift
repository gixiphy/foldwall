import AppKit
import FoldwallCore

// engine-harness <screen uuid> <video A> <video B> [--stress | --measure <core> <seconds> [occluded] [extra=k=v,...]]
//
// 用正式 app 裡的 DesktopVideoEngine 在桌面層真的播。三種腳本：
// - 預設（40 秒）：mpv 播、預載接上、mpv↔AVPlayer 各換一次且從同一秒接續、暫停恢復、模式切換、收乾淨。
// - --stress：50 次手動下一片、20 次換核心、10 次暫停恢復、6 次改模式，最後檢查沒有孤兒視窗、
//   記憶體沒有階梯成長。這是 P1 驗收清單的自動化版本（睡眠喚醒用暫停恢復代替，真的睡眠要人做）。
// - --measure：固定片段、固定核心，暖機 10 秒後量 N 秒的 CPU／GPU／記憶體。加 occluded 會拿一個
//   不透明視窗把整個螢幕蓋住，量「被完全遮住」時的成本。加 extra=aid=no 可以 A/B mpv 選項。
//   每次一行 TSV，外面用 shell 迴圈跑三次取平均。

@MainActor
final class Harness: NSObject, NSApplicationDelegate {
    let engine = DesktopVideoEngine()
    let uuid: String
    let videos: [URL]
    let mode: [String]
    var screens: [DisplayTarget] = []
    var tick = 0
    var timer: Timer?
    var occluder: NSWindow?
    var gpuSamples: [Double] = []
    var cpuStart: (user: Double, system: Double, wall: Date)?

    init(uuid: String, videos: [URL], mode: [String]) {
        self.uuid = uuid
        self.videos = videos
        self.mode = mode
    }

    func log(_ text: String) {
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        print("[\(stamp)] \(text)")
        fflush(stdout)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        screens = NSScreen.screens.compactMap { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber
            let id = CGDirectDisplayID(number.uint32Value)
            let cf = CGDisplayCreateUUIDFromDisplayID(id)!.takeRetainedValue()
            let uuid = CFUUIDCreateString(nil, cf)! as String
            return DisplayTarget(id: id, uuid: uuid, canvas: screen.frame.size)
        }
        guard screens.contains(where: { $0.uuid == uuid }) else {
            log("screen not found"); exit(2)
        }
        engine.onCoreStatusChanged = { [weak self] status in
            self?.log("CORE STATUS requested=\(status.requested.rawValue) effective=\(status.effective.rawValue) failure=\(status.failure.map(DesktopVideoEngine.describe) ?? "-")")
        }
        engine.onVideoEnded = { [weak self] uuid, url in self?.log("ENDED \(url.lastPathComponent)") }
        engine.onPlaybackFailed = { [weak self] url, reason in self?.log("FAILED \(url.lastPathComponent): \(reason)") }
        engine.nextVideoProvider = { [weak self] _, current in
            guard let self else { return nil }
            return videos.first { $0 != current } ?? current
        }
        switch mode.first {
        case "--stress": runStress()
        case "--measure": runMeasure()
        default: runScript()
        }
    }

    func apply(core: DesktopPlaybackCore, mode: VideoPlaybackMode = .repeatAll, url: URL? = nil) {
        let url = url ?? engine.playingURLs[uuid] ?? videos[0]
        engine.apply(plan: [uuid: url], layer: .belowIcons, screens: screens,
                     mode: mode, scale: .fill, core: core)
        engine.setPaused(false)
    }

    func every(_ seconds: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { _ in
            Task { @MainActor in body() }
        }
    }

    func finish(_ code: Int32) {
        timer?.invalidate()
        engine.stopAll()
        occluder?.close()
        let orphans = NSApp.windows.filter { $0.isVisible }.count
        log("STOPPED activeCount=\(engine.activeCount) visibleWindows=\(orphans) rss=\(residentMB())MB")
        let clean = engine.activeCount == 0 && orphans == 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(clean ? code : 3) }
    }

    // MARK: - 預設腳本

    func runScript() {
        apply(core: .mpv)
        every(1) { [weak self] in self?.scriptStep() }
    }

    func scriptStep() {
        tick += 1
        let playing = engine.playingURLs[uuid]?.lastPathComponent ?? "-"
        log("t=\(tick) playing=\(playing) effective=\(engine.coreStatus.effective.rawValue) reserved=\(engine.reservedURLs().count)")
        switch tick {
        case 3, 9, 17, 29: apply(core: engine.coreStatus.requested)   // 冪等的 refresh：不該重播
        case 14: log("SWITCH → avPlayer"); apply(core: .avPlayer)
        case 22: log("SWITCH → mpv"); apply(core: .mpv)
        case 26: log("PAUSE"); engine.setPaused(true)
        case 28: log("RESUME"); engine.setPaused(false)
        case 31: log("MODE → repeatOne"); apply(core: .mpv, mode: .repeatOne)
        case 36: log("MODE → repeatAll"); apply(core: .mpv, mode: .repeatAll)
        case 40:
            print(engine.diagnosticsReport())
            finish(0)
        default: break
        }
    }

    // MARK: - 壓力

    var stressPhase = 0
    var stressCount = 0
    var rssSamples: [Int] = []

    func runStress() {
        apply(core: .mpv)
        rssSamples.append(residentMB())
        every(0.7) { [weak self] in self?.stressStep() }
    }

    func stressStep() {
        tick += 1
        stressCount += 1
        switch stressPhase {
        case 0:   // 50 次手動下一片：換到另一支（預載好的話走接上那條）
            let current = engine.playingURLs[uuid]
            let next = videos.first { $0 != current } ?? videos[0]
            apply(core: .mpv, url: next)
            if stressCount % 10 == 0 { log("next×\(stressCount) playing=\(engine.playingURLs[uuid]?.lastPathComponent ?? "-") rss=\(residentMB())MB") }
            if stressCount == 50 { stressPhase = 1; stressCount = 0; rssSamples.append(residentMB()) }
        case 1:   // 20 次換核心
            apply(core: stressCount % 2 == 1 ? .avPlayer : .mpv)
            if stressCount % 5 == 0 { log("core×\(stressCount) effective=\(engine.coreStatus.effective.rawValue) rss=\(residentMB())MB") }
            if stressCount == 20 { stressPhase = 2; stressCount = 0; rssSamples.append(residentMB()) }
        case 2:   // 10 次暫停恢復
            engine.setPaused(stressCount % 2 == 1)
            if stressCount == 20 { stressPhase = 3; stressCount = 0; rssSamples.append(residentMB()); log("pause/resume×10 done") }
        case 3:   // 6 次改模式（mpv 即時改，不重建）
            apply(core: .mpv, mode: stressCount % 2 == 1 ? .repeatOne : .repeatAll)
            if stressCount == 6 { stressPhase = 4; stressCount = 0; rssSamples.append(residentMB()); log("mode×6 done") }
        case 4:   // 靜置 8 秒看它還在不在播
            if stressCount == 12 {
                rssSamples.append(residentMB())
                log("rss samples (MB): \(rssSamples)")
                print(engine.diagnosticsReport())
                let playing = engine.playingURLs[uuid] != nil
                let windows = NSApp.windows.filter { $0.isVisible }.count
                log("still playing=\(playing) visibleWindows=\(windows)")
                finish(playing && windows == 1 ? 0 : 4)
            }
        default: break
        }
    }

    // MARK: - 量測

    func runMeasure() {
        let core: DesktopPlaybackCore = mode.count > 1 && mode[1] == "mpv" ? .mpv : .avPlayer
        let seconds = mode.count > 2 ? Double(mode[2]) ?? 60 : 60
        let occluded = mode.contains("occluded")
        if let extra = mode.first(where: { $0.hasPrefix("extra=") }) {
            var options: [String: String] = [:]
            for pair in extra.dropFirst(6).split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { options[parts[0]] = parts[1] }
            }
            MPVSurface.extraOptions = options
        }
        apply(core: core, mode: .repeatOne)   // 單片循環：整段量測都是同一支
        if occluded, let screen = NSScreen.screens.first(where: { screenUUID($0) == uuid }) {
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.level = .normal
            window.backgroundColor = .black
            window.isOpaque = true
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.orderFrontRegardless()
            occluder = window
        }
        // 暖機 10 秒，再量 seconds 秒
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in
            cpuStart = cpuTimes()
            gpuSamples = []
            every(5) { [weak self] in
                guard let self else { return }
                gpuSamples.append(gpuUtilization())
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
                let end = cpuTimes()
                let start = cpuStart!
                let wall = end.wall.timeIntervalSince(start.wall)
                let cpu = ((end.user - start.user) + (end.system - start.system)) / wall * 100
                let gpu = gpuSamples.isEmpty ? -1 : gpuSamples.reduce(0, +) / Double(gpuSamples.count)
                let effective = engine.coreStatus.effective.rawValue
                let occl = engine.diagnosticsReport().contains("視窗目前被完全遮住")
                print(String(format: "MEASURE\tcore=%@\toccluded=%d\tseen_occluded=%d\tcpu_pct=%.1f\tgpu_pct=%.1f\trss_mb=%d\tseconds=%.0f",
                             effective, occluded ? 1 : 0, occl ? 1 : 0, cpu, gpu, residentMB(), wall))
                finish(0)
            }
        }
    }

    func screenUUID(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let cf = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, cf) as String
    }

    func cpuTimes() -> (user: Double, system: Double, wall: Date) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return (user, system, .now)
    }

    func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
    }

    /// 整台 GPU 的使用率（ioreg 的 Device Utilization %）。不是只算我們這個行程的，
    /// 所以量的時候別做別的事。讀不到回 -1。
    func gpuUtilization() -> Double {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/ioreg")
        process.arguments = ["-r", "-d", "1", "-c", "IOAccelerator"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard let range = text.range(of: "\"Device Utilization %\"=") else { return -1 }
        let rest = text[range.upperBound...].prefix { $0.isNumber }
        return Double(rest) ?? -1
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    print("usage: engine-harness <uuid> <videoA> <videoB> [--stress | --measure <mpv|avPlayer> <seconds> [occluded] [extra=k=v,...]]")
    exit(1)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let harness = Harness(uuid: arguments[1], videos: [URL(filePath: arguments[2]), URL(filePath: arguments[3])],
                      mode: Array(arguments.dropFirst(4)))
app.delegate = harness
app.run()
