//  VideoDiagnostics.swift
//  「診斷播放不順」：把兩條引擎的播放事件和片源事實拼成一份可匯出的報告。
//
//  為什麼需要它：使用者能講的是「有些片會抖」，而抖動至少有四種成因——
//  幀率與螢幕更新率不匹配、讀取或解碼跟不上、循環接縫、政策變速。
//  這四種的處理方式完全不同，猜錯就是白花力氣。這份報告的目的是**把它們分開**。
//
//  兩條原則：
//
//  1. **量不到就說量不到。** 沒有時間分析就寫「未知」，不要因為「播放進度正常」
//     就宣稱沒有掉幀——那是兩件事。
//  2. **分類是待查方向，不是結論。** 24 fps 播在 60 Hz 上會規律微頓，那是呈現
//     節奏，不是播放器故障；報告要講清楚這件事，不要讓人跑去改播放器。

import AppKit
import AVFoundation
import FoldwallCore

@MainActor
enum VideoDiagnostics {

    /// 深入分析（走過整條軌道的時間戳）最多跑幾支。
    ///
    /// **有上限**：那是把影片整支讀一遍，一次診斷跑十幾支 NAS 上的片
    /// 就是幾分鐘加幾 GB 的網路流量。正在播的那幾支才是使用者問的對象。
    static let maxDeepAnalysis = 4

    /// extension 那邊回報事件的檔案。它寫進自己的 container，我們（非沙盒）讀得到。
    /// 名稱與格式的另一半在 `FoldwallExtension/PlaybackDiagnostics.swift`。
    private static let requestNotification = "app.foldwall.requestPlaybackDiagnostics"
    private static var extensionSnapshotURL: URL {
        VideoLibrary.documentsURL.appending(path: "playback-diagnostics.json")
    }

    private struct ExtensionSnapshot: Codable {
        var writtenAt: Date
        var droppedCount: Int
        var events: [PlaybackEvent]
    }

    /// 產生報告。
    ///
    /// - Parameters:
    ///   - engine: 使用者目前選的引擎。決定報告以哪一條為主。
    ///   - playing: 桌面視窗正在播的（螢幕 UUID → 影片）。
    ///   - desktopReport: 桌面視窗引擎自己那段（事件與停頓統計）。
    static func report(
        engine: VideoEngine,
        playing: [String: URL],
        desktopReport: String,
    ) async -> String {
        var lines: [String] = [
            "# Foldwall 影片播放診斷",
            "",
            "產生時間：\(Date.now.formatted(date: .abbreviated, time: .standard))",
            "使用中的引擎：\(engine.displayName)",
            "",
        ]

        lines.append(contentsOf: screenSection())

        // 片源事實。正在播的那幾支才深入分析。
        let subjects = Array(playing.sorted(by: { $0.key < $1.key }).prefix(maxDeepAnalysis))
        if subjects.isEmpty {
            lines.append("## 片源")
            lines.append("")
            lines.append("目前沒有正在播的影片，無法分析片源。")
            lines.append("")
        } else {
            lines.append("## 片源")
            lines.append("")
            for (uuid, url) in subjects {
                lines.append(contentsOf: await sourceSection(uuid: uuid, url: url))
            }
        }

        lines.append("## 桌面視窗引擎")
        lines.append("")
        lines.append(desktopReport)
        lines.append("")

        lines.append(contentsOf: await extensionSection())

        lines.append("## 怎麼讀這份報告")
        lines.append("")
        lines.append("""
            - **規律微頓、慢速橫移特別明顯**：先看「呈現節奏」。幀率與螢幕更新率不整除\
            （24 或 25 fps 播在 60 Hz 上）本來就會這樣，改播放器沒有用。
            - **不定時停一下**：看「停頓」次數與長度，以及片源位置。網路磁碟與串流\
            的停頓要往讀取那邊查，不是解碼。
            - **每次播回開頭頓一下**：看「接縫偏差」。持續同號累積代表循環時間軸有問題；\
            偏差是 0 而畫面仍然跳，那是片源首尾本來就不連續。
            - **解鎖或切換桌面之後忽快忽慢**：看政策事件的密度。
            """)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// 螢幕更新率。**取不到就標未知**，不要假設 60——那會憑空生出一條錯的線索。
    private static func screenSection() -> [String] {
        var lines = ["## 螢幕", ""]
        for screen in NSScreen.screens {
            let hz = refreshHz(of: screen)
            let size = screen.frame.size
            let name = screen.localizedName
            lines.append("- \(name)：\(Int(size.width))×\(Int(size.height)) @\(screen.backingScaleFactor)x、"
                + (hz.map { "更新率 \(String(format: "%.2f", $0)) Hz" } ?? "更新率未知"))
        }
        if NSScreen.screens.isEmpty { lines.append("- （沒有偵測到螢幕）") }
        lines.append("")
        return lines
    }

    static func refreshHz(of screen: NSScreen) -> Double? {
        let rate = screen.maximumFramesPerSecond
        return rate > 0 ? Double(rate) : nil
    }

    private static func sourceSection(uuid: String, url: URL) async -> [String] {
        var profile = await VideoAnalyzer.profile(of: url)
        profile.timing = await VideoAnalyzer.timingAnalysis(of: url)

        let hz = NSScreen.screens.first { screenUUID(of: $0) == uuid }
            .flatMap(refreshHz(of:))
        let risks = profile.risks(screenRefreshHz: hz)

        var lines = ["### \(url.lastPathComponent)（螢幕 \(uuid)）", ""]
        lines.append("| 項目 | 值 |")
        lines.append("|---|---|")
        lines.append("| 編碼 | \(profile.codec ?? "未知") |")
        lines.append("| 畫素尺寸 | \(dimension(profile.pixelWidth, profile.pixelHeight)) |")
        lines.append("| 顯示尺寸（已套旋轉） | \(dimension(profile.displayWidth.map { Int($0) }, profile.displayHeight.map { Int($0) })) |")
        lines.append("| 旋轉 | \(profile.rotationDegrees.map { "\($0)°" } ?? "未知") |")
        lines.append("| 位元深度 | \(profile.bitDepth.map(String.init) ?? "未知") |")
        lines.append("| HDR | \(flag(profile.isHDR)) |")
        lines.append("| 位元率 | \(profile.estimatedDataRate.map { String(format: "%.1f Mbps", $0 / 1_000_000) } ?? "未知") |")
        lines.append("| 宣告幀率 | \(profile.nominalFrameRate.map { String(format: "%.3f", $0) } ?? "未知") |")
        lines.append("| 實測幀率 | \(profile.effectiveFrameRate.map { String(format: "%.3f", $0) } ?? "未知") |")
        lines.append("| 螢幕更新率 | \(hz.map { String(format: "%.2f Hz", $0) } ?? "未知") |")
        lines.append("| 軌道起點 | \(seconds(profile.trackStartSeconds)) |")
        lines.append("| 軌道長度 | \(seconds(profile.trackDurationSeconds)) |")
        lines.append("| 容器長度 | \(seconds(profile.containerDurationSeconds)) |")
        lines.append("| 片源位置 | \(VideoBufferPolicy.location(for: url).displayName) |")

        if let timing = profile.timing {
            lines.append("| 分析畫格數 | \(timing.sampleCount) |")
            lines.append("| 呈現間隔（最小／中位／最大） | \(interval(timing.minIntervalSeconds))／\(interval(timing.medianIntervalSeconds))／\(interval(timing.maxIntervalSeconds)) |")
            lines.append("| 可變幀率 | \(timing.isVariableFrameRate ? "是" : "否") |")
            lines.append("| 有 B-frame | \(timing.hasBFrames ? "是" : "否") |")
            lines.append("| 沒帶長度的畫格 | \(timing.samplesMissingDuration) |")
            lines.append("| 重複的呈現時間戳 | \(timing.nonMonotonicPresentationCount) |")
        } else {
            lines.append("| 時間戳分析 | **未取得**（讀不到畫格） |")
        }
        lines.append("")

        lines.append("**待查方向**（不是結論）：")
        lines.append("")
        if risks.isEmpty {
            lines.append("- 沒有找到已知的風險特徵。這不等於畫面一定順——"
                + "還沒量到的東西（實際呈現時刻、合成負載）不在這份報告裡。")
        } else {
            for risk in risks { lines.append("- \(risk.summary)") }
        }
        lines.append("")
        return lines
    }

    private static func extensionSection() async -> [String] {
        var lines = ["## 系統 extension 引擎", ""]

        // 先請它把目前的環狀緩衝寫出來，再讀。它可能根本沒被系統跑起來
        // （沒選這個引擎、桌布不是我們），那時就是沒有檔案——要講清楚是
        // 「沒有回報」而不是「沒有問題」。
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(requestNotification as CFString), nil, nil, true)
        try? await Task.sleep(for: .milliseconds(600))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: extensionSnapshotURL),
              let snapshot = try? decoder.decode(ExtensionSnapshot.self, from: data) else {
            lines.append("沒有取得 extension 的播放紀錄。extension 只有在系統設定裡選了 "
                + "Foldwall 當桌布時才會被系統跑起來；**這不代表那條引擎沒有問題**，"
                + "只代表現在問不到。")
            lines.append("")
            return lines
        }

        let age = Date.now.timeIntervalSince(snapshot.writtenAt)
        if age > 30 {
            lines.append("⚠️ 這份紀錄是 \(Int(age)) 秒前寫的，extension 可能沒有回應這次請求。")
            lines.append("")
        }
        if snapshot.droppedCount > 0 {
            lines.append("（紀錄有上限，較早的 \(snapshot.droppedCount) 則已被擠掉）")
            lines.append("")
        }

        var log = PlaybackEventLog(capacity: max(1, snapshot.events.count))
        for event in snapshot.events { log.record(event) }
        for surface in Set(snapshot.events.map(\.surface)).sorted() {
            let stalls = log.stallSummary(surface: surface)
            let events = log.events(surface: surface)
            let loops = events.count { $0.kind == .loopBoundary }
            lines.append("- **\(surface)**：\(events.count) 則事件、循環 \(loops) 輪、"
                + "解碼中斷 \(stalls.count + stalls.unmatched) 次"
                + (events.last(where: { $0.kind == .loopBoundary })?.detail.map { "，最近一輪 \($0)" } ?? ""))
        }
        if snapshot.events.isEmpty { lines.append("- （紀錄是空的）") }
        lines.append("")

        lines.append("<details><summary>extension 事件明細</summary>")
        lines.append("")
        for event in snapshot.events.suffix(120) {
            let stamp = event.at.formatted(date: .omitted, time: .standard)
            lines.append("- \(stamp) [\(event.surface)#\(event.session)] \(event.kind.rawValue)"
                + (event.sourceKey.map { "・\($0)" } ?? "")
                + (event.detail.map { "：\($0)" } ?? ""))
        }
        lines.append("")
        lines.append("</details>")
        lines.append("")
        return lines
    }

    // MARK: - 輸出

    /// 把報告寫成檔案並在 Finder 選起來。回傳檔案位置。
    @discardableResult
    static func write(_ report: String) -> URL? {
        let name = "foldwall-播放診斷-\(Int(Date.now.timeIntervalSince1970)).md"
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.video.error("寫診斷報告失敗：\(error.localizedDescription, privacy: .public)")
            return nil
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return url
    }

    // MARK: - 小工具

    /// 螢幕的 UUID，跟 `ScreenBridge` 那邊用的是同一個識別。
    private static func screenUUID(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let id = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private static func dimension(_ width: Int?, _ height: Int?) -> String {
        guard let width, let height else { return "未知" }
        return "\(width)×\(height)"
    }

    private static func flag(_ value: Bool?) -> String {
        guard let value else { return "未知" }
        return value ? "是" : "否"
    }

    private static func seconds(_ value: Double?) -> String {
        guard let value else { return "未知" }
        return String(format: "%.3f 秒", value)
    }

    private static func interval(_ value: Double?) -> String {
        guard let value else { return "未知" }
        return String(format: "%.4f", value)
    }
}
