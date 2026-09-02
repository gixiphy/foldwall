//  CLIEngineRegistry.swift
//  本機 AI CLI 的偵測與選擇（給介面翻譯用）。掃描順序：自訂路徑 → PATH → 常見安裝位置。
//
//  **不在啟動時掃描**：每個引擎都要 spawn 一次 `--version`，一個桌布 app 沒理由在
//  每次登入時拉起五個子行程。設定 → 語言分頁出現時才掃第一次。

import Foundation
import Observation
import FoldwallCore

@MainActor
@Observable
final class CLIEngineRegistry {

    struct DetectedEngine: Identifiable {
        let engine: KnownCLIEngine
        let url: URL
        var version: String?
        var id: String { engine.id }
    }

    private(set) var detected: [DetectedEngine] = []
    private(set) var hasScanned = false
    /// 各引擎可用的模型（engine id → slug）。空的就只有輸入欄位，沒有下拉。
    private(set) var models: [String: [String]] = [:]

    @ObservationIgnored private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// 使用者選定且裝了的引擎；選定的不在（被移除、還沒裝）時回落 claude → 任一裝了的。
    /// 回落是為了「按了翻譯不該沒反應」，設定頁會把實際用到的那個標出來。
    var activeEngine: DetectedEngine? {
        detected.first { $0.id == settings.translationEngineID }
            ?? detected.first { $0.id == "claude" }
            ?? detected.first
    }

    func detected(_ engineID: String) -> DetectedEngine? {
        detected.first { $0.id == engineID }
    }

    /// 第一次打開設定頁時掃；之後靠「重新掃描」。
    func scanIfNeeded() {
        guard !hasScanned else { return }
        scan()
    }

    /// 使用者按的「重新掃描」：連模型清單一起重抓。他按這顆的情境就是
    /// 「我剛裝了東西／剛換了模型」，這時還拿快取交差是最不該的。
    func rescan() {
        settings.translationModelCache = [:]
        models = [:]
        scan()
    }

    private func scan() {
        hasScanned = true
        detected = KnownCLIEngine.catalog.compactMap { engine in
            CLIEngineLocator.locate(engine, customPath: settings.translationCustomPaths[engine.id])
                .map { DetectedEngine(engine: engine, url: $0, version: nil) }
        }
        // 靜態建議先就位；能列舉的等版本確定後再補（見 refreshModels）
        for entry in detected where !entry.engine.suggestedModels.isEmpty {
            models[entry.id] = entry.engine.suggestedModels
        }
        fetchVersions()
    }

    /// 版本確定後補上模型清單。
    private func refreshModels(for entry: DetectedEngine) {
        guard let listing = entry.engine.modelListing, let version = entry.version else { return }
        let cacheKey = "\(entry.id)|\(version)"
        if let cached = settings.translationModelCache[cacheKey], !cached.isEmpty {
            models[entry.id] = cached
            return
        }
        let url = entry.url
        let engineID = entry.id
        Task.detached {
            let parsed = CLIModelLister.fetch(listing, executable: url)
            guard !parsed.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.models[engineID] = parsed
                self.settings.translationModelCache[cacheKey] = parsed
            }
        }
    }

    /// 測試注入：直接布置偵測結果，跳過實機掃描。
    func injectDetected(_ entries: [DetectedEngine]) {
        hasScanned = true
        detected = entries
    }

    /// 各引擎 `--version` 供設定頁顯示；失敗不影響可用性。
    private func fetchVersions() {
        for entry in detected {
            let url = entry.url
            let engineID = entry.id
            Task.detached { [weak self] in
                let version = CLIEngineLocator.readVersion(of: url)
                await MainActor.run {
                    guard let self,
                          let index = self.detected.firstIndex(where: { $0.id == engineID }),
                          self.detected[index].url == url
                    else { return }
                    self.detected[index].version = version
                    self.refreshModels(for: self.detected[index])
                }
            }
        }
    }
}
