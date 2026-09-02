//  UITranslationTests.swift
//  介面翻譯：prompt 組裝、回覆容錯、specifier 驗證、CLI 輸出解析、翻譯 bundle 落地與覆蓋。

import Foundation
import ObjectiveC
import Testing
@testable import FoldwallCore

@Suite("UI translation prompt")
struct UITranslationPromptTests {

    @Test("prompt 帶目標語言、詞彙表與輸入 JSON")
    func promptContents() {
        let items = [
            UITranslationItem(id: 0, key: "下一張", english: "Next"),
            UITranslationItem(id: 1, key: "%lld 分鐘", english: "%lld minutes"),
        ]
        let prompt = UITranslationPrompt.prompt(items: items, targetLanguage: "Japanese")
        #expect(prompt.contains("into Japanese"))
        #expect(prompt.contains("Foldwall: product name, never translate"))
        #expect(prompt.contains("\"zh_Hant\": \"下一張\""))
        #expect(prompt.contains("\"en\": \"%lld minutes\""))
        #expect(prompt.contains(CLIExecution.outputInstruction))
        #expect(prompt.contains("\"translations\""))
    }

    /// 這條規則有沒有在裡面，是「整批有沒有輸出」的差別，不是措辭問題：
    /// 這些 CLI 都是 coding agent，headless 下模型一決定去讀檔或跑指令就被自動拒絕，
    /// 然後什麼都不回（agy 實測 2026-09-02：不加這條 4 次死 3 次）。
    @Test("prompt 明講不要動工具")
    func promptForbidsTools() {
        let prompt = UITranslationPrompt.prompt(
            items: [UITranslationItem(id: 0, key: "下一張", english: "Next")],
            targetLanguage: "Japanese")
        #expect(prompt.contains("Do not use any tools"))
    }

    @Test("複數形以 plural_en 物件附上；引號與換行有逃逸")
    func inputJSON() {
        let items = [
            UITranslationItem(id: 3, key: "說 \"嗨\"\n第二行", english: "Say \"hi\"\nline two"),
            UITranslationItem(id: 4, key: "%lld 個", english: "%lld items", plural: ["one": "%lld item", "other": "%lld items"]),
        ]
        let json = UITranslationPrompt.inputJSON(items)
        #expect(json.contains(#""zh_Hant": "說 \"嗨\"\n第二行""#))
        #expect(json.contains(#""plural_en": {"one": "%lld item", "other": "%lld items"}"#))
        // 是合法 JSON
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        #expect(parsed?.count == 2)
    }

    @Test("回覆容錯：缺 translations 當空、缺 text 的條目保留 id")
    func batchDecoding() throws {
        let empty = try JSONDecoder().decode(UITranslationBatch.self, from: Data("{}".utf8))
        #expect(empty.translations.isEmpty)

        let json = """
        {"translations": [{"id": 0, "text": "次へ"}, {"id": 1}, {"id": 2, "plural": {"other": "%lld 分"}}]}
        """
        let batch = try JSONDecoder().decode(UITranslationBatch.self, from: Data(json.utf8))
        #expect(batch.translations.count == 3)
        #expect(batch.translations[0].text == "次へ")
        #expect(batch.translations[1].text == nil)
        #expect(batch.translations[2].plural?["other"] == "%lld 分")
    }
}

@Suite("UI translation validator")
struct UITranslationValidatorTests {

    @Test("specifier 正規化：去位置編號、排序、略過 %% 與孤立的 %")
    func specifiers() {
        #expect(UITranslationValidator.normalizedSpecifiers("%2$@ — %1$lld") == ["%@", "%lld"])
        #expect(UITranslationValidator.normalizedSpecifiers("回到 100%") == [])
        #expect(UITranslationValidator.normalizedSpecifiers("100%% done %d") == ["%d"])
        #expect(UITranslationValidator.normalizedSpecifiers("%lld×%lld") == ["%lld", "%lld"])
        #expect(UITranslationValidator.normalizedSpecifiers("%.1f MB") == ["%.1f"])
    }

    @Test("驗收：非空且 specifier 一致；型別或數量不同一律退")
    func acceptance() {
        #expect(UITranslationValidator.isAcceptable(candidate: "%lld 分", source: "%lld minutes"))
        #expect(UITranslationValidator.isAcceptable(candidate: "%2$@（%1$lld）", source: "%lld (%@)"))
        #expect(!UITranslationValidator.isAcceptable(candidate: "   ", source: "Next"))
        #expect(!UITranslationValidator.isAcceptable(candidate: "%d 分", source: "%lld minutes"))
        #expect(!UITranslationValidator.isAcceptable(candidate: "分", source: "%lld minutes"))
    }
}

@Suite("CLI codec")
struct CLICodecTests {

    struct Reply: Decodable, Equatable { var ok: Bool }

    @Test("claude envelope 取 result；is_error 映射成 CLI 自報錯誤")
    func jsonEnvelope() throws {
        let reply: Reply = try CLICodec.decode(stdout: #"{"result": "```json\n{\"ok\": true}\n```"}"#, codec: .jsonEnvelope, as: Reply.self)
        #expect(reply == Reply(ok: true))
        #expect(throws: CLIDecodeError.cliReportedError(message: "Not logged in")) {
            try CLICodec.decode(stdout: #"{"is_error": true, "result": "Not logged in"}"#, codec: .jsonEnvelope, as: Reply.self)
        }
    }

    @Test("agy envelope 優先吃 structured_output；沒有就走 response 文字")
    func responseEnvelope() throws {
        let structured: Reply = try CLICodec.decode(
            stdout: #"{"response": "garbage", "structured_output": {"ok": false}}"#,
            codec: .responseEnvelope, as: Reply.self)
        #expect(structured == Reply(ok: false))
        let text: Reply = try CLICodec.decode(stdout: #"{"response": "{\"ok\": true}"}"#, codec: .responseEnvelope, as: Reply.self)
        #expect(text == Reply(ok: true))
        #expect(throws: CLIDecodeError.emptyOutput) {
            try CLICodec.decode(stdout: #"{"status": "SUCCESS", "response": ""}"#, codec: .responseEnvelope, as: Reply.self)
        }
    }

    @Test("plain stdout：旁白之後的第一個 JSON 物件也撈得到")
    func plainStdout() throws {
        let reply: Reply = try CLICodec.decode(
            stdout: "Sure, here it is:\n{\"ok\": true}\nDone.", codec: .plainStdout, as: Reply.self)
        #expect(reply == Reply(ok: true))
        #expect(throws: CLIDecodeError.emptyOutput) {
            try CLICodec.decode(stdout: "  \n", codec: .plainStdout, as: Reply.self)
        }
        #expect(throws: CLIDecodeError.bodyParseFailed(raw: "nope")) {
            try CLICodec.decode(stdout: "nope", codec: .plainStdout, as: Reply.self)
        }
    }

    @Test("第一個成對大括號：略過字串裡的括號")
    func firstJSONObject() {
        #expect(CLICodec.firstJSONObject(in: #"x {"a": "{"} y"#) == #"{"a": "{"}"#)
        #expect(CLICodec.firstJSONObject(in: "no braces") == nil)
    }
}

@Suite("CLI engine catalog")
struct CLIEngineTests {

    @Test("claude 走 stdin、其餘以參數帶 prompt；模型留空不帶 --model")
    func invocations() throws {
        let run = KnownCLIEngine.RunContext(sandbox: URL(fileURLWithPath: "/tmp/x"), model: "  ", timeout: .seconds(60))
        let claude = try #require(KnownCLIEngine.named("claude")).invocation(prompt: "P", run: run)
        #expect(claude.stdin == "P")
        #expect(claude.arguments == ["-p", "--output-format", "json"])

        let codex = try #require(KnownCLIEngine.named("codex")).invocation(prompt: "P", run: run)
        #expect(codex.stdin == nil)
        #expect(codex.arguments.first == "exec")
        #expect(codex.arguments.last == "P")
        #expect(codex.arguments.contains("--skip-git-repo-check"))
        #expect(!codex.arguments.contains("--model"))

        var withModel = run
        withModel.model = "opus"
        let claudeModel = try #require(KnownCLIEngine.named("claude")).invocation(prompt: "P", run: withModel)
        #expect(claudeModel.arguments == ["-p", "--output-format", "json", "--model", "opus"])
    }

    @Test("偵測：自訂路徑優先，PATH 裡沒有就回 nil")
    func locate() throws {
        let engine = KnownCLIEngine(id: "fake", executableName: "definitely-not-installed-\(UUID().uuidString)",
                                    displayName: "Fake", codec: .plainStdout,
                                    supportsModelSelection: false, loginCommand: "fake")
        #expect(CLIEngineLocator.locate(engine, environment: ["PATH": "/usr/bin"]) == nil)
        let custom = CLIEngineLocator.locate(engine, customPath: "/usr/bin/true", environment: [:])
        #expect(custom?.path == "/usr/bin/true")
    }

    /// 每家官方 installer 的落點都要在掃描清單裡。GUI app 的 PATH 只有系統目錄，
    /// 漏一個的症狀是「終端明明打得出來，設定頁卻說未安裝」。
    @Test("目錄裡每家的官方安裝位置都掃得到")
    func knownDirectoriesCoverEveryEngine() {
        let home = NSHomeDirectory()
        for suffix in ["/.local/bin", "/.claude/local", "/.grok/bin", "/.codex/bin", "/.opencode/bin"] {
            #expect(CLIEngineLocator.knownDirectories.contains(home + suffix), "少了 \(suffix)")
        }
    }

    @Test("錯誤訊息裡的 token 被遮蔽")
    func sanitized() {
        let text = CLIExecution.sanitized("failed: Bearer abc.def sk-1234567890abcdef")
        #expect(!text.contains("abc.def"))
        #expect(!text.contains("sk-1234567890abcdef"))
    }
}

@Suite("UI translation store")
struct UITranslationStoreTests {

    private func makeStore() -> UITranslationStore {
        UITranslationStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("foldwall-uitranslation-\(UUID().uuidString)", isDirectory: true))
    }

    private let manifest = UITranslationStore.Manifest(
        language: "ja", engineID: "codex", model: nil, date: Date(),
        sourceBuild: "46", translated: 2, skipped: [])

    @Test("寫入後 Bundle(url:) 讀得到字串與複數形，即使使用者偏好裡沒有這個語言")
    func roundTrip() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.write(
            language: "ja",
            strings: ["下一張": "次へ"],
            plurals: ["%lld 分鐘": ["other": "%lld 分"]],
            pluralValueTypes: ["%lld 分鐘": "lld"],
            manifest: manifest)
        let bundle = try #require(Bundle(url: store.bundleURL(for: "ja")))
        #expect(TranslatedBundle.resolve(key: "下一張", table: nil, overlay: bundle) == "次へ")
        // 沒翻的 key 回 nil，讓上層退回內建語言，而不是把 key 本身顯示出來
        #expect(TranslatedBundle.resolve(key: "不存在的 key", table: nil, overlay: bundle) == nil)
        #expect(TranslatedBundle.resolve(key: "下一張", table: nil, overlay: nil) == nil)

        // 複數形交給 Foundation：格式字串套上數字後是日文
        let format = try #require(TranslatedBundle.resolve(key: "%lld 分鐘", table: nil, overlay: bundle))
        #expect(String(format: format, locale: Locale(identifier: "ja"), 3) == "3 分")

        #expect(store.manifest(for: "ja")?.engineID == "codex")
        #expect(store.installedLanguages() == ["ja"])
        let existing = store.existingTranslations(for: "ja")
        #expect(existing.strings["下一張"] == "次へ")
        #expect(existing.plurals["%lld 分鐘"]?["other"] == "%lld 分")
    }

    @Test("換掉 class 後查表先走 overlay，查不到再退回原本的 bundle")
    func overrideMechanics() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.write(language: "ja", strings: ["下一張": "次へ"], plurals: [:],
                        pluralValueTypes: [:], manifest: manifest)
        // 拿 FoldwallCore 自己的 bundle 當受害者；測完把 class 換回去
        let victim = try #require(Bundle(url: Bundle.foldwallCore.bundleURL))
        let originalClass: AnyClass = try #require(object_getClass(victim))
        TranslatedBundle.overlay = Bundle(url: store.bundleURL(for: "ja"))
        defer {
            TranslatedBundle.overlay = nil
            object_setClass(victim, originalClass)
        }
        object_setClass(victim, TranslatedBundle.self)
        #expect(victim.localizedString(forKey: "下一張", value: nil, table: nil) == "次へ")
        // Swift Foundation 的入口（String(localized:) 那條）也要接住
        #expect(victim.__localizedString(forKey: "下一張", value: nil, table: nil, localizations: ["en"]) == "次へ")
        #expect(victim.__localizedAttributedString(forKey: "下一張", value: nil, table: nil).string == "次へ")
        // overlay 沒有的 key 走原本邏輯：內建都沒有就回 key 本身
        #expect(victim.localizedString(forKey: "foldwall.test.nokey", value: nil, table: nil) == "foldwall.test.nokey")
        #expect(victim.__localizedString(forKey: "foldwall.test.nokey", value: nil, table: nil, localizations: []) == "foldwall.test.nokey")
    }

    @Test("真的走 String(localized:) 這條：換掉 FoldwallCore 的 class 後 Swift Foundation 的查表也被接住")
    func swiftFoundationEntryPoint() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.write(language: "ja", strings: ["下一張": "次へ"], plurals: [:],
                        pluralValueTypes: [:], manifest: manifest)
        // 直接對 Bundle.foldwallCore 動手（installOverride 在正式版就是這樣做），測完換回去
        let core = Bundle.foldwallCore
        let originalClass: AnyClass = try #require(object_getClass(core))
        defer {
            TranslatedBundle.overlay = nil
            TranslatedBundle.language = nil
            object_setClass(core, originalClass)
        }
        #expect(store.installOverride(language: "ja", bundles: [core]))
        // `String(localized:bundle:)` 不經公開的 localizedString(forKey:)，走私有 selector
        #expect(String(localized: "下一張", bundle: .foldwallCore) == "次へ")
        // 沒翻的 key 退回內建（這條 Core 有英文／繁中），不會變成 sentinel 或空字串
        let fallback = String(localized: "照片", bundle: .foldwallCore)
        #expect(!fallback.isEmpty && !fallback.contains("\u{1}"))
        // 沒有這個語言的翻譯檔就不該裝上去
        #expect(!store.installOverride(language: "ko", bundles: [core]))
    }

    @Test("移除後 bundle 與 manifest 都不在")
    func remove() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.write(language: "ko", strings: ["a": "b"], plurals: [:], pluralValueTypes: [:], manifest: manifest)
        try store.remove(language: "ko")
        #expect(store.manifest(for: "ko") == nil)
        #expect(store.installedLanguages().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.bundleURL(for: "ko").path))
    }

    @Test("內建英文來源從 FoldwallCore 的 en.lproj 讀得到，且沒有一條是空的")
    func builtinSource() {
        let source = UITranslationStore.builtinSource(bundles: [.foldwallCore])
        #expect(source.strings.count > 50)
        #expect(source.strings.values.allSatisfy { !$0.isEmpty })
        // 同一份 bundle 給兩次不會重複計算
        let twice = UITranslationStore.builtinSource(bundles: [.foldwallCore, .foldwallCore])
        #expect(twice.strings.count == source.strings.count)
    }
}
