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

    static let batchSize = 40

    /// 兩份字串表：app 自己的與 FoldwallCore 的。
    static var sourceBundles: [Bundle] { [.main, .foldwallCore] }

    init(store: UITranslationStore, settings: AppSettings, registry: CLIEngineRegistry) {
        self.store = store
        self.settings = settings
        self.registry = registry
        targetLanguage = settings.uiTranslationLanguage
            ?? Self.suggestedLanguage(preferred: Locale.preferredLanguages)
            ?? "ja"
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

    /// 已翻好、檔還在的語言。
    var installedLanguages: [String] { store.installedLanguages() }

    func manifest(for language: String) -> UITranslationStore.Manifest? { store.manifest(for: language) }

    /// 選定的與正在執行的不同：要重啟才會生效（含切回內建語言）。
    var needsRelaunch: Bool {
        var desired = selection
        // 翻譯檔不在（被手動刪掉）就當作沒選——重啟也救不回來，別掛著一個假提示
        if case let .translated(code) = desired, store.manifest(for: code) == nil { desired = .system }
        return desired != Self.runningSelection
    }

    /// 某個已翻語言裡，內建字串尚未翻的條數（升版後會長出來）。
    func missingCount(for language: String) -> Int {
        missingKeys(for: language, source: UITranslationStore.builtinSource(bundles: Self.sourceBundles)).count
    }

    /// 內建字串總數，設定頁用來估「大概要翻幾條」。
    var builtinStringCount: Int {
        let source = UITranslationStore.builtinSource(bundles: Self.sourceBundles)
        return source.strings.count + source.plurals.count
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

    /// 翻譯（或補翻）目標語言。`onlyMissing` 為 true 時保留既有譯文、只送缺的。
    func translate(onlyMissing: Bool) {
        guard !isRunning else { return }
        guard let engine = registry.activeEngine else {
            phase = .failed(message: String(localized: "沒有可用的 AI CLI，先安裝一個或填入路徑"), loginCommand: nil)
            return
        }
        let language = targetLanguage
        let source = UITranslationStore.builtinSource(bundles: Self.sourceBundles)
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

        task = Task { [weak self] in
            defer { self?.task = nil }
            var done = 0
            let batches = stride(from: 0, to: items.count, by: Self.batchSize).map {
                Array(items[$0..<min($0 + Self.batchSize, items.count)])
            }
            do {
                for batch in batches {
                    try Task.checkCancellation()
                    let reply = try await runner.translate(batch, targetLanguage: languageName)
                    let entries = Dictionary(reply.translations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    for item in batch {
                        if let plural = item.plural {
                            if let forms = entries[item.id]?.plural,
                               let other = forms["other"],
                               forms.values.allSatisfy({ UITranslationValidator.isAcceptable(candidate: $0, source: plural["other"] ?? other) }) {
                                plurals[item.key] = forms
                                skipped.remove(item.key)
                            } else {
                                skipped.insert(item.key)
                            }
                        } else if let text = entries[item.id]?.text,
                                  UITranslationValidator.isAcceptable(candidate: text, source: item.english ?? item.key) {
                            strings[item.key] = text
                            skipped.remove(item.key)
                        } else {
                            skipped.insert(item.key)
                        }
                    }
                    done += batch.count
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
                    self.phase = .running(done: done, total: total)
                }
                guard let self else { return }
                self.selection = .translated(language)
                self.phase = .finished(translated: strings.count + plurals.count, skipped: skipped.count)
                Log.app.notice("介面翻譯完成：\(language, privacy: .public) \(strings.count + plurals.count) 條、跳過 \(skipped.count)，引擎 \(engine.id, privacy: .public)")
            } catch is CancellationError {
                self?.phase = .idle
                Log.app.notice("介面翻譯取消：\(language, privacy: .public) 已完成 \(done)/\(total)")
            } catch let error as CLIEngineError {
                self?.phase = .failed(message: error.userMessage, loginCommand: error.loginCommand)
                Log.app.error("介面翻譯失敗：\(language, privacy: .public) 於 \(done)/\(total)，\(error.userMessage, privacy: .public)")
            } catch {
                self?.phase = .failed(message: error.localizedDescription, loginCommand: nil)
                Log.app.error("介面翻譯失敗：\(language, privacy: .public) 於 \(done)/\(total)，\(error.localizedDescription, privacy: .public)")
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
