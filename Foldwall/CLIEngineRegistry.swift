//  CLIEngineRegistry.swift
//  本機 AI CLI 的偵測與選擇（給介面翻譯用）。掃描順序：自訂路徑 → PATH → 常見安裝位置。
//
//  **不在啟動時掃描**：每個引擎都要 spawn 一次 `--version`，一個桌布 app 沒理由在
//  每次登入時拉起一串子行程。設定 → 語言分頁出現時才掃第一次。
//
//  「偵測到」只是第一關：設定頁與翻譯看的是 `available`——檔案在、而且**真的跑得
//  起來**（`--version` 在期限內結束）。模型不給選，一律用該 CLI 自己的預設。

import Foundation
import Observation
import FoldwallCore

@MainActor
@Observable
final class CLIEngineRegistry {

    struct DetectedEngine: Identifiable {
        let engine: KnownCLIEngine
        let url: URL
        var probe: CLIProbeState = .pending
        var auth: CLIAuthState = .unknown
        var id: String { engine.id }
        /// `--version` 的第一行（探測成功且退出碼 0 才有）。
        var version: String? {
            guard case let .ready(version) = probe else { return nil }
            return version
        }
    }

    private(set) var detected: [DetectedEngine] = []
    private(set) var hasScanned = false

    @ObservationIgnored private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// 可以拿來用的引擎：執行探測沒有失敗。`.pending` 也算——探測還沒回來就先列出，
    /// 否則開設定頁會先閃一次空清單。
    var available: [DetectedEngine] {
        detected.filter { $0.probe != .failed }
    }

    /// 偵測到但跑不起來的（設定頁用一行 caption 交代，不混進可選清單）。
    var unrunnable: [DetectedEngine] {
        detected.filter { $0.probe == .failed }
    }

    /// 使用者選定且可用的引擎；選定的不合格（被移除、跑不起來、未登入）時
    /// 回落 claude → 任一合格的。回落是為了「按了翻譯不該沒反應」，設定頁勾的是
    /// 實際會用到的那個。**永不**回落到已知未登入的引擎：那只是把「未登入」的
    /// 錯誤換一家報，白等一次逾時。
    var activeEngine: DetectedEngine? {
        let usable = available.filter { $0.auth != .notLoggedIn }
        return usable.first { $0.id == settings.translationEngineID }
            ?? usable.first { $0.id == "claude" }
            ?? usable.first
    }

    /// 第一次打開設定頁時掃；之後靠「重新掃描」。
    func scanIfNeeded() {
        guard !hasScanned else { return }
        rescan()
    }

    func rescan() {
        hasScanned = true
        detected = KnownCLIEngine.catalog.compactMap { engine in
            CLIEngineLocator.locate(engine, customPath: settings.translationCustomPaths[engine.id])
                .map { DetectedEngine(engine: engine, url: $0) }
        }
        probeAll()
    }

    /// 測試注入：直接布置偵測結果，跳過實機掃描。
    func injectDetected(_ entries: [DetectedEngine]) {
        hasScanned = true
        detected = entries
    }

    /// 各引擎並行查「跑不跑得起來」與登入狀態，各自有期限（`CLIEngineProbe.timeout`）。
    private func probeAll() {
        for entry in detected {
            let url = entry.url
            let engine = entry.engine
            Task.detached { [weak self] in
                let probe = CLIEngineProbe.probeExecutable(at: url, extraEnvironment: engine.extraEnvironment)
                await self?.update(engine.id, url: url) { $0.probe = probe }
            }
            guard let authProbe = engine.authProbe else { continue }
            Task.detached { [weak self] in
                let auth = CLIEngineProbe.evaluateAuth(
                    authProbe, executable: url, extraEnvironment: engine.extraEnvironment)
                await self?.update(engine.id, url: url) { $0.auth = auth }
            }
        }
    }

    /// 探測回來時那一筆可能已經被重新掃描換掉了：id 與路徑都對得上才寫。
    private func update(_ engineID: String, url: URL, _ change: (inout DetectedEngine) -> Void) {
        guard let index = detected.firstIndex(where: { $0.id == engineID }),
              detected[index].url == url else { return }
        change(&detected[index])
    }
}
