//  UITranslator.swift
//  「用本機 AI CLI 翻譯介面」的協調器：讀內建英文 → 分批送引擎 → 驗證 → 寫進
//  UITranslationStore。每批寫回一次，取消或中途失敗不白做；補翻只送缺的 key。
//
//  移植自 Chorus（DESIGN-20260902-user-cli-translation）。翻譯來源是內建**英文**
//  而不是繁中：模型對英→X 的品質普遍高於繁中→X，繁中 key 一起附在 prompt 當第二參考。

import AppKit
import Foundation
import Observation
import FoldwallCore

@MainActor
@Observable
final class UITranslator {

    enum Phase: Equatable {
        case idle
        case running(done: Int, total: Int)
        /// 這一輪翻好了（或補翻好了）；`needsRelaunch` 表示目前跑的不是這個語言。
        case finished(translated: Int, skipped: Int)
        case failed(message: String, loginCommand: String?)
    }

    private(set) var phase: Phase = .idle
    /// 目標語言（BCP 47：ja、ko、de、pt-BR…）。預設系統語言裡第一個非內建的。
    var targetLanguage: String

    let registry: CLIEngineRegistry

    @ObservationIgnored private let store: UITranslationStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var task: Task<Void, Never>?
    /// 測試用：換掉真的 CLI。
    @ObservationIgnored var batchRunner: (any UITranslationBatchRunning)?

    /// 已翻好的語言、它們的 manifest 與待補條數。**快取在可觀察的狀態裡**：
    /// `store` 不是 `@Observable`，View 直接讀檔的話 SwiftUI 追蹤不到檔案系統的變化，
    /// 移除語言後那一列不會消失。順帶也省掉每次重算 body 的讀檔。
    private(set) var installedLanguages: [String] = []
    private(set) var manifests: [String: UITranslationStore.Manifest] = [:]
    private(set) var missingCounts: [String: Int] = [:]

    /// 兩份字串表：app 自己的與 FoldwallCore 的。
    static var sourceBundles: [Bundle] { [.main, .foldwallCore] }

    /// 內建英文來源只讀一次：約 400 條字串、執行期不會變，但 `missingCount`
    /// 與設定頁每次重算 body 都會用到。
    static let builtinSource = UITranslationStore.builtinSource(bundles: sourceBundles)

    init(store: UITranslationStore, settings: AppSettings, registry: CLIEngineRegistry) {
        self.store = store
        self.settings = settings
        self.registry = registry
        targetLanguage = settings.uiTranslationLanguage
            ?? Self.suggestedLanguage(preferred: Locale.preferredLanguages)
            ?? "ja"
        refreshInstalled()
    }

    // MARK: - 狀態

    /// 介面語言的三種選法。內建語言靠 App domain 的 `AppleLanguages` 生效，
    /// 自翻語言靠 `TranslatedBundle` 覆蓋 Bundle 查表——兩者都要重啟才會換，
    /// Foundation 在行程啟動時就把語言決定好了。
    enum Selection: Hashable {
        /// 跟隨系統：系統語言是三種內建語言之一就用它，否則由 Foundation 挑。
        case system
        /// 指定一種內建語言（zh-Hant／zh-Hans／en）。
        case builtin(String)
        /// 使用者自翻的語言；沒翻到的字串退回英文。
        case translated(String)
    }

    /// 這個行程實際跑的是哪個語言：App.init 掛完覆蓋後設一次。
    nonisolated(unsafe) static var runningSelection: Selection = .system

    /// 使用者選定要用的介面語言。切走**不會**刪翻譯檔，之後還能再切回來。
    var selection: Selection {
        get {
            if let language = settings.uiTranslationLanguage { return .translated(language) }
            if let builtin = settings.builtinLanguage { return .builtin(builtin) }
            return .system
        }
        set {
            switch newValue {
            case .system:
                settings.uiTranslationLanguage = nil
                settings.builtinLanguage = nil
                settings.applyInterfaceLanguage(nil)
            case let .builtin(code):
                settings.uiTranslationLanguage = nil
                settings.builtinLanguage = code
                settings.applyInterfaceLanguage(code)
            case let .translated(code):
                settings.uiTranslationLanguage = code
                settings.builtinLanguage = nil
                // 覆蓋查不到的 key 會落到內建語言：釘成英文，才是翻譯的來源那一份。
                // 不釘的話，沒翻到的字串會顯示系統語言（在這台就是繁中），
                // 而不是說明裡講的「退回英文」。
                settings.applyInterfaceLanguage("en")
            }
        }
    }

    func manifest(for language: String) -> UITranslationStore.Manifest? { manifests[language] }

    /// 重讀檔案系統，更新上面三份快取。啟動、翻完一批、移除語言時各叫一次——
    /// 檔案只有我們自己會動，不必每次畫面更新都掃一遍。
    func refreshInstalled() {
        let languages = store.installedLanguages()
        var manifests: [String: UITranslationStore.Manifest] = [:]
        var missing: [String: Int] = [:]
        for language in languages {
            manifests[language] = store.manifest(for: language)
            missing[language] = missingKeys(for: language, source: Self.builtinSource).count
        }
        installedLanguages = languages
        self.manifests = manifests
        missingCounts = missing
    }

    /// 選定的與正在執行的不同：要重啟才會生效（含切回內建語言）。
    var needsRelaunch: Bool {
        var desired = selection
        // 翻譯檔不在（被手動刪掉）就當作沒選——重啟也救不回來，別掛著一個假提示
        if case let .translated(code) = desired, manifests[code] == nil { desired = .system }
        return desired != Self.runningSelection
    }

    /// 某個已翻語言裡，內建字串尚未翻的條數（升版後會長出來）。
    func missingCount(for language: String) -> Int { missingCounts[language] ?? 0 }

    /// 內建字串總數，設定頁用來估「大概要翻幾條」。
    var builtinStringCount: Int {
        Self.builtinSource.strings.count + Self.builtinSource.plurals.count
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var activeEngine: CLIEngineRegistry.DetectedEngine? { registry.activeEngine }

    // MARK: - 引擎設定（轉給 AppSettings，讓設定頁只認識 translator）

    var engineID: String {
        get { settings.translationEngineID }
        set { settings.translationEngineID = newValue }
    }

    func model(for engineID: String) -> String {
        settings.translationModelIDs[engineID] ?? ""
    }

    func setModel(_ model: String, for engineID: String) {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            settings.translationModelIDs.removeValue(forKey: engineID)
        } else {
            settings.translationModelIDs[engineID] = trimmed
        }
    }

    func customPath(for engineID: String) -> String {
        settings.translationCustomPaths[engineID] ?? ""
    }

    func setCustomPath(_ path: String, for engineID: String) {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            settings.translationCustomPaths.removeValue(forKey: engineID)
        } else {
            settings.translationCustomPaths[engineID] = trimmed
        }
    }

    // MARK: - 語言

    /// 系統語言裡第一個 App 沒內建的；全都內建就 nil。
    /// "ja-JP" → "ja"；中文保留 script（zh-Hans-CN → zh-Hans）；其餘保留 region
    /// 只在 Apple 有分開在地化的情況（pt-BR、pt-PT、es-419），其他去掉。
    static func suggestedLanguage(preferred: [String]) -> String? {
        for identifier in preferred {
            let normalized = normalize(identifier)
            if !UITranslationStore.builtinLanguages.contains(normalized) { return normalized }
        }
        return nil
    }

    static func normalize(_ identifier: String) -> String {
        let locale = Locale(identifier: identifier)
        guard let code = locale.language.languageCode?.identifier else { return identifier }
        if code == "zh" {
            let script = locale.language.script?.identifier
                ?? (locale.region?.identifier == "CN" || locale.region?.identifier == "SG" ? "Hans" : "Hant")
            return "zh-\(script)"
        }
        if let region = locale.region?.identifier {
            let keepRegion: Set<String> = ["pt-BR", "pt-PT", "es-419", "en-GB", "fr-CA"]
            let candidate = "\(code)-\(region)"
            if keepRegion.contains(candidate) { return candidate }
        }
        return code
    }

    /// 設定頁 Picker 的候選：系統建議 ＋ 常用語言，去重。
    var candidateLanguages: [String] {
        var list: [String] = []
        if let suggested = Self.suggestedLanguage(preferred: Locale.preferredLanguages) { list.append(suggested) }
        // 不列內建語言（zh-Hant／zh-Hans／en）——那三個在上面的「介面語言」選單裡
        for code in ["ja", "ko", "de", "fr", "es", "pt-BR", "it", "ru", "vi", "th", "id", "nl", "pl", "tr", "uk"]
        where !list.contains(code) && !UITranslationStore.builtinLanguages.contains(code) {
            list.append(code)
        }
        if !list.contains(targetLanguage) { list.insert(targetLanguage, at: 0) }
        return list
    }

    /// 「한국어（韓文）」：本地名＋目前介面語言裡的名字。
    ///
    /// 括號存在的理由是「讀不懂本地名的人也知道那是什麼語言」。所以兩邊都是漢字時
    /// 就不加括號——繁中介面下的 `简体中文` 本來就看得懂，補一句「簡體中文」只是雜訊。
    /// 英文介面下 `简体中文（Chinese, Simplified）` 的括號則留著，因為那時它有用。
    static func displayName(for language: String) -> String {
        let endonym = Locale(identifier: language).localizedString(forIdentifier: language) ?? language
        let exonym = Locale.current.localizedString(forIdentifier: language) ?? language
        if endonym == exonym { return endonym }
        if isAllHan(endonym), isAllHan(exonym) { return endonym }
        return "\(endonym)（\(exonym)）"
    }

    /// 整串都是漢字（不含假名、諺文、拉丁字母）。
    private static func isAllHan(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
        }
    }

    /// 語言代碼 → 英文語言名，給 prompt 用（模型看英文名最不會誤解）。
    static func englishName(for language: String) -> String {
        Locale(identifier: "en_US").localizedString(forIdentifier: language) ?? language
    }

    // MARK: - 動作

    /// 一批送出去的結果。TaskGroup 的結果型別必須是 Sendable，而 `any Error`
    /// 不是，所以錯誤在這裡先收斂成可搬運的形狀。
    private struct BatchOutcome: Sendable {
        var items: [UITranslationItem]
        var reply: UITranslationBatch?
        var failure: BatchFailure?
        /// 這批花了多久：加量與否看它。
        var elapsed: TimeInterval
    }

    private enum BatchFailure: Error, Sendable {
        case engine(CLIEngineError)
        case other(String)

        var message: String {
            switch self {
            case let .engine(error): error.userMessage
            case let .other(text): text
            }
        }

        var loginCommand: String? {
            if case let .engine(error) = self { return error.loginCommand }
            return nil
        }
    }

    /// 翻譯（或補翻）目標語言。`onlyMissing` 為 true 時保留既有譯文、只送缺的。
    ///
    /// 批量不是固定的：起手 `probeBatchSize` 條，之後依上一批的實測速率放大或縮小
    /// （`UITranslationBatchPolicy`）；回覆缺條或整批失敗就砍半重送，同時跑
    /// `maxConcurrentBatches` 批。每批各自落地，取消或中途失敗時已翻的都在。
    func translate(onlyMissing: Bool) {
        guard !isRunning else { return }
        guard let engine = registry.activeEngine else {
            phase = .failed(message: String(localized: "沒有可用的 AI CLI，先安裝一個或填入路徑"), loginCommand: nil)
            return
        }
        let language = targetLanguage
        let source = Self.builtinSource
        let existing: (strings: [String: String], plurals: [String: [String: String]]) =
            onlyMissing ? store.existingTranslations(for: language) : (strings: [:], plurals: [:])
        var strings = existing.strings
        var plurals = existing.plurals
        var skipped = Set(onlyMissing ? (store.manifest(for: language)?.skipped ?? []) : [])

        // 沒有中日韓文字、英文又等於 key 的（"%lld×%lld"、"Foldwall"）不用問模型
        var items: [UITranslationItem] = []
        for (key, english) in source.strings.sorted(by: { $0.key < $1.key }) where strings[key] == nil {
            if english == key, !Self.containsCJK(key) {
                strings[key] = english
                continue
            }
            items.append(UITranslationItem(id: items.count, key: key, english: english))
        }
        for (key, forms) in source.plurals.sorted(by: { $0.key < $1.key }) where plurals[key] == nil {
            items.append(UITranslationItem(id: items.count, key: key, english: forms["other"], plural: forms))
        }

        let total = items.count
        guard total > 0 else {
            phase = .finished(translated: strings.count + plurals.count, skipped: skipped.count)
            return
        }
        phase = .running(done: 0, total: total)
        let model = settings.translationModelIDs[engine.id]
        let runner = batchRunner ?? CLIUITranslationBatchRunner(engine: engine.engine, executable: engine.url, model: model)
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let languageName = Self.englishName(for: language)
        typealias Policy = UITranslationBatchPolicy

        task = Task { [weak self] in
            defer { self?.task = nil }
            // 待送佇列：批量是動態的，所以不預先切好批，每次從佇列前面取「當下批量」條。
            var pending = items
            var attempts: [Int: Int] = [:]
            var batchSize = Policy.probeBatchSize
            // 被截斷或失敗過就壓下來，之後不再長回去
            var ceiling = Policy.maxBatchSize
            var resolved = 0
            var failures = 0
            var inFlight = 0
            let started = Date()
            Log.app.notice("介面翻譯開始：\(language, privacy: .public) \(total) 條，起始批量 \(batchSize)、同時 \(Policy.maxConcurrentBatches) 批，引擎 \(engine.id, privacy: .public)")
            do {
                // 併發跑批：收一批補一批，補的時候用**當下**的批量，
                // 所以前一批的結果會影響下一批送多少。
                try await withThrowingTaskGroup(of: BatchOutcome.self) { group in
                    while true {
                        while inFlight < Policy.maxConcurrentBatches, !pending.isEmpty {
                            let chunk = Array(pending.prefix(batchSize))
                            pending.removeFirst(chunk.count)
                            group.addTask {
                                let sent = Date()
                                do {
                                    let reply = try await runner.translate(chunk, targetLanguage: languageName)
                                    return BatchOutcome(items: chunk, reply: reply, failure: nil,
                                                        elapsed: Date().timeIntervalSince(sent))
                                } catch let error as CLIEngineError {
                                    return BatchOutcome(items: chunk, reply: nil, failure: .engine(error),
                                                        elapsed: Date().timeIntervalSince(sent))
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch {
                                    return BatchOutcome(items: chunk, reply: nil,
                                                        failure: .other(error.localizedDescription),
                                                        elapsed: Date().timeIntervalSince(sent))
                                }
                            }
                            inFlight += 1
                        }
                        guard inFlight > 0, let outcome = try await group.next() else { break }
                        inFlight -= 1
                        try Task.checkCancellation()

                        if let failure = outcome.failure {
                            // 未登入重送也不會好，直接停
                            if case .engine(.notLoggedIn) = failure { throw failure }
                            failures += 1
                            // 還有降的空間就砍半重送：引擎吃不下這個量是最常見的死法
                            if failures <= Policy.maxBatchFailures, batchSize > Policy.minBatchSize {
                                ceiling = max(Policy.minBatchSize, outcome.items.count / 2)
                                batchSize = min(batchSize, ceiling)
                                pending.insert(contentsOf: outcome.items, at: 0)
                                Log.app.notice("介面翻譯批次失敗，批量降到 \(batchSize) 重送：\(failure.message, privacy: .public)")
                                continue
                            }
                            throw failure
                        }

                        let entries = Dictionary(
                            (outcome.reply?.translations ?? []).map { ($0.id, $0) },
                            uniquingKeysWith: { first, _ in first })
                        // 模型整條沒回的（多半是輸出被截斷）退回佇列再試，不是直接放棄
                        var missing: [UITranslationItem] = []
                        for item in outcome.items {
                            guard let entry = entries[item.id] else {
                                let tried = (attempts[item.id] ?? 0) + 1
                                attempts[item.id] = tried
                                if tried <= Policy.maxItemAttempts {
                                    missing.append(item)
                                } else {
                                    skipped.insert(item.key)
                                    resolved += 1
                                }
                                continue
                            }
                            if let plural = item.plural {
                                if let forms = entry.plural,
                                   let other = forms["other"],
                                   forms.values.allSatisfy({ UITranslationValidator.isAcceptable(candidate: $0, source: plural["other"] ?? other) }) {
                                    plurals[item.key] = forms
                                    skipped.remove(item.key)
                                } else {
                                    skipped.insert(item.key)
                                }
                            } else if let text = entry.text,
                                      UITranslationValidator.isAcceptable(candidate: text, source: item.english ?? item.key) {
                                strings[item.key] = text
                                skipped.remove(item.key)
                            } else {
                                skipped.insert(item.key)
                            }
                            resolved += 1
                        }

                        if missing.isEmpty {
                            // 依這批的實測速率決定下一批送幾條
                            batchSize = Policy.nextBatchSize(
                                previous: outcome.items.count, elapsed: outcome.elapsed,
                                budget: Policy.batchBudgetSeconds, ceiling: ceiling)
                        } else {
                            // 回覆缺條＝輸出裝不下，壓低上限並把缺的退回佇列
                            ceiling = max(Policy.minBatchSize, outcome.items.count / 2)
                            batchSize = min(batchSize, ceiling)
                            pending.insert(contentsOf: missing, at: 0)
                            Log.app.notice("介面翻譯回覆缺 \(missing.count) 條，批量降到 \(batchSize) 重送")
                        }

                        guard let self else { return }
                        // 每批落地：取消或下一批失敗時已翻的都在
                        try self.store.write(
                            language: language, strings: strings, plurals: plurals,
                            pluralValueTypes: source.pluralValueTypes,
                            manifest: .init(
                                language: language, engineID: engine.id, model: model,
                                date: Date(), sourceBuild: build,
                                translated: strings.count + plurals.count,
                                skipped: skipped.sorted()))
                        self.phase = .running(done: resolved, total: total)
                        self.refreshInstalled()
                        Log.app.info("介面翻譯進度：\(language, privacy: .public) \(resolved)/\(total)，批量 \(batchSize)，本批 \(Int(outcome.elapsed)) 秒，累計 \(Int(Date().timeIntervalSince(started))) 秒")
                    }
                }
                guard let self else { return }
                self.selection = .translated(language)
                self.phase = .finished(translated: strings.count + plurals.count, skipped: skipped.count)
                self.refreshInstalled()
                Log.app.notice("介面翻譯完成：\(language, privacy: .public) \(strings.count + plurals.count) 條、跳過 \(skipped.count)，引擎 \(engine.id, privacy: .public)，收斂批量 \(batchSize)，耗時 \(Int(Date().timeIntervalSince(started))) 秒")
            } catch is CancellationError {
                self?.phase = .idle
                self?.refreshInstalled()
                Log.app.notice("介面翻譯取消：\(language, privacy: .public) 已完成 \(resolved)/\(total)")
            } catch let failure as BatchFailure {
                self?.phase = .failed(message: failure.message, loginCommand: failure.loginCommand)
                self?.refreshInstalled()
                Log.app.error("介面翻譯失敗：\(language, privacy: .public) 於 \(resolved)/\(total)，\(failure.message, privacy: .public)")
            } catch {
                self?.phase = .failed(message: error.localizedDescription, loginCommand: nil)
                self?.refreshInstalled()
                Log.app.error("介面翻譯失敗：\(language, privacy: .public) 於 \(resolved)/\(total)，\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// 刪掉某個語言的翻譯檔；若它正被選用，選回內建。覆蓋還在記憶體裡，重啟才變。
    func remove(language: String) {
        try? store.remove(language: language)
        if settings.uiTranslationLanguage == language { selection = .system }
        phase = .idle
        // 清單／manifest 都在快取裡，刪完要當場更新，畫面那一列才會馬上消失
        refreshInstalled()
    }

    /// 重新啟動 App 套用語言：`open -n` 拉起新實例，自己退出。
    func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: - 內部

    private func missingKeys(for language: String, source: UITranslationStore.BuiltinSource) -> [String] {
        let existing = store.existingTranslations(for: language)
        let skipped = Set(store.manifest(for: language)?.skipped ?? [])
        var missing: [String] = []
        for (key, english) in source.strings where existing.strings[key] == nil && !skipped.contains(key) {
            if english == key, !Self.containsCJK(key) { continue }
            missing.append(key)
        }
        for key in source.plurals.keys where existing.plurals[key] == nil && !skipped.contains(key) {
            missing.append(key)
        }
        return missing
    }

    nonisolated static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
        }
    }
}
