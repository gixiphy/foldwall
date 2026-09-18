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

    @Test("claude 走 stdin、其餘以參數帶 prompt")
    func invocations() throws {
        let run = KnownCLIEngine.RunContext(sandbox: URL(fileURLWithPath: "/tmp/x"), timeout: .seconds(60))
        let claude = try #require(KnownCLIEngine.named("claude")).invocation(prompt: "P", run: run)
        #expect(claude.stdin == "P")
        #expect(claude.arguments == ["-p", "--output-format", "json"])

        let codex = try #require(KnownCLIEngine.named("codex")).invocation(prompt: "P", run: run)
        #expect(codex.stdin == nil)
        #expect(codex.arguments.first == "exec")
        #expect(codex.arguments.last == "P")
        #expect(codex.arguments.contains("--skip-git-repo-check"))

        // cursor：非 TTY 下少了 --trust 會掛在「信任這個目錄嗎」
        let cursor = try #require(KnownCLIEngine.named("cursor")).invocation(prompt: "P", run: run)
        #expect(cursor.arguments == ["-p", "--output-format", "json", "--mode", "ask", "--trust",
                                     "--workspace", "/tmp/x", "P"])

        let amp = try #require(KnownCLIEngine.named("amp")).invocation(prompt: "P", run: run)
        #expect(amp.stdin == "P")
        #expect(amp.arguments == ["-x"])
    }

    /// 模型選擇已移除：模型名的壽命比 App 的發版週期短，一律用 CLI 自己的預設。
    /// 哪一家偷偷帶了模型旗標，症狀是「昨天還好的引擎今天壞了」。
    @Test("目錄裡每一家都不帶模型旗標")
    func noModelFlags() {
        let run = KnownCLIEngine.RunContext(sandbox: URL(fileURLWithPath: "/tmp/x"),
                                            schemaFile: URL(fileURLWithPath: "/tmp/x/schema.json"),
                                            timeout: .seconds(60))
        for engine in KnownCLIEngine.catalog {
            let arguments = engine.invocation(prompt: "P", run: run).arguments
            #expect(!arguments.contains("--model"), "\(engine.id) 帶了 --model")
            #expect(!arguments.contains("-m"), "\(engine.id) 帶了 -m")
        }
    }

    /// pi 會從行程 cwd 撈 AGENTS.md／extensions／skills，沙箱指不過去，探索旗標一個都不能少——
    /// 少一個的症狀是使用者機器上的擴充默默改變翻譯行為。`--no-tools` 免掉權限對話框。
    @Test("pi：探索旗標全關、prompt 排最後")
    func piInvocation() throws {
        let run = KnownCLIEngine.RunContext(sandbox: URL(fileURLWithPath: "/tmp/x"), timeout: .seconds(60))
        let pi = try #require(KnownCLIEngine.named("pi"))
        let plain = pi.invocation(prompt: "P", run: run)
        #expect(plain.stdin == nil)
        #expect(plain.arguments == ["-p", "--no-session", "--no-tools", "--no-context-files",
                                    "--no-extensions", "--no-skills", "--no-prompt-templates", "P"])
        #expect(pi.codec == .plainStdout)
        #expect(pi.loginCommand == "pi")
    }

    /// 實測 pi 0.85.0：未登入時 stderr 是 "No API key found for anthropic."、退出碼 1。
    /// 這句要映射成「未登入」並附登入指令，而不是一段「退出碼 1」的泛用錯誤。
    @Test("pi 未登入的 stderr 映射成 notLoggedIn")
    func piNotLoggedIn() {
        let output = CLIProcessRunner.Output(status: 1, stdout: "", stderr: "No API key found for anthropic.\n\nUse /login to log into a provider via OAuth or API key.")
        let error = CLIExecution.mapNonZeroExit(engineID: "pi", output: output)
        guard case .notLoggedIn(let engineID) = error else {
            Issue.record("應映射成 notLoggedIn，實際是 \(error)")
            return
        }
        #expect(engineID == "pi")
        #expect(error.loginCommand == "pi")
    }

    @Test("偵測：自訂路徑優先，PATH 裡沒有就回 nil")
    func locate() throws {
        let engine = KnownCLIEngine(id: "fake", executableName: "definitely-not-installed-\(UUID().uuidString)",
                                    displayName: "Fake", codec: .plainStdout, loginCommand: "fake")
        #expect(CLIEngineLocator.locate(engine, environment: ["PATH": "/usr/bin"]) == nil)
        let custom = CLIEngineLocator.locate(engine, customPath: "/usr/bin/true", environment: [:])
        #expect(custom?.path == "/usr/bin/true")
    }

    /// 每家官方 installer 的落點都要在掃描清單裡。GUI app 的 PATH 只有系統目錄，
    /// 漏一個的症狀是「終端明明打得出來，設定頁卻說未安裝」。
    @Test("目錄裡每家的官方安裝位置都掃得到")
    func knownDirectoriesCoverEveryEngine() {
        let home = NSHomeDirectory()
        for suffix in ["/.local/bin", "/.claude/local", "/.grok/bin", "/.codex/bin", "/.opencode/bin",
                       "/.pi/agent/bin", "/.hermes/bin", "/.factory/bin"] {
            #expect(CLIEngineLocator.knownDirectories.contains(home + suffix), "少了 \(suffix)")
        }
    }

    @Test("目錄：前六家順序不變、id 不重複、實測過的八家不標實驗性")
    func catalog() {
        let ids = KnownCLIEngine.catalog.map(\.id)
        #expect(Array(ids.prefix(6)) == ["claude", "codex", "agy", "grok", "opencode", "pi"])
        #expect(Set(ids).count == ids.count)
        let verified = KnownCLIEngine.catalog.filter { !$0.experimental }.map(\.id)
        #expect(verified == ["claude", "codex", "agy", "grok", "opencode", "pi", "cursor", "hermes"])
        // goose 不設 GOOSE_MODE 會在非互動模式下等權限確認
        #expect(KnownCLIEngine.named("goose")?.extraEnvironment["GOOSE_MODE"] == "chat")
    }

    @Test("錯誤訊息裡的 token 被遮蔽")
    func sanitized() {
        let text = CLIExecution.sanitized("failed: Bearer abc.def sk-1234567890abcdef")
        #expect(!text.contains("abc.def"))
        #expect(!text.contains("sk-1234567890abcdef"))
    }
}

/// 登入狀態與執行探測。三種 probe 都只讀狀態，所以測得起來：
/// 憑證檔用臨時家目錄、環境變數用注入的字典、指令用 `/usr/bin/true`／`false`。
@Suite("CLI engine probes")
struct CLIEngineProbeTests {

    private func temporaryDirectory(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func stub(_ script: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("stub")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("credentialFile：檔案存在＝已登入，不存在＝未登入")
    func credentialFile() throws {
        let home = try temporaryDirectory("foldwall-auth-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let probe = KnownCLIEngine.AuthProbe.credentialFile(path: ".grok/auth.json")
        let executable = URL(fileURLWithPath: "/usr/bin/true")
        #expect(CLIEngineProbe.evaluateAuth(probe, executable: executable, home: home.path) == .notLoggedIn)

        let credential = home.appendingPathComponent(".grok/auth.json")
        try FileManager.default.createDirectory(
            at: credential.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: credential)
        #expect(CLIEngineProbe.evaluateAuth(probe, executable: executable, home: home.path) == .loggedIn)
    }

    @Test("environmentKey：任一變數存在且非空＝已登入；缺席或空字串都算未登入")
    func environmentKey() {
        let executable = URL(fileURLWithPath: "/usr/bin/true")
        #expect(CLIEngineProbe.evaluateAuth(
            .environmentKey(names: ["MISSING_KEY", "AMP_API_KEY"]), executable: executable,
            environment: ["AMP_API_KEY": "sk-test"]) == .loggedIn)
        #expect(CLIEngineProbe.evaluateAuth(
            .environmentKey(names: ["AMP_API_KEY"]), executable: executable, environment: [:]) == .notLoggedIn)
        // 空字串是「export 了但沒填」，不該當成已登入
        #expect(CLIEngineProbe.evaluateAuth(
            .environmentKey(names: ["AMP_API_KEY"]), executable: executable,
            environment: ["AMP_API_KEY": ""]) == .notLoggedIn)
    }

    @Test("command：退出碼 0＝已登入、非零＝未登入、跑不起來＝未知")
    func command() {
        #expect(CLIEngineProbe.evaluateAuth(
            .command(arguments: []), executable: URL(fileURLWithPath: "/usr/bin/true")) == .loggedIn)
        #expect(CLIEngineProbe.evaluateAuth(
            .command(arguments: []), executable: URL(fileURLWithPath: "/usr/bin/false")) == .notLoggedIn)
        // 探測失敗不該變成「不能用這家」
        #expect(CLIEngineProbe.evaluateAuth(
            .command(arguments: []), executable: URL(fileURLWithPath: "/nonexistent/foldwall-not-a-cli")) == .unknown)
    }

    @Test("執行探測：退出碼 0 取第一行當版本；不認 --version 但跑得起來＝可用、沒有版本")
    func probeExecutable() throws {
        let directory = try temporaryDirectory("foldwall-probe")
        defer { try? FileManager.default.removeItem(at: directory) }
        let versioned = try stub("#!/bin/sh\nprintf '1.2.3\\nextra line\\n'\n", in: directory)
        #expect(CLIEngineProbe.probeExecutable(at: versioned) == .ready(version: "1.2.3"))

        let unversioned = try stub("#!/bin/sh\necho 'unknown flag' >&2\nexit 2\n", in: directory)
        #expect(CLIEngineProbe.probeExecutable(at: unversioned) == .ready(version: nil))
    }

    @Test("執行探測：跑不起來＝failed（半裝好的 CLI 不該列進可用清單）")
    func probeFailsForMissingExecutable() {
        #expect(CLIEngineProbe.probeExecutable(at: URL(fileURLWithPath: "/nonexistent/foldwall-not-a-cli")) == .failed)
    }
}

@Suite("UI translation batch policy")
struct UITranslationBatchPolicyTests {

    typealias Policy = UITranslationBatchPolicy

    @Test("快的引擎放大，但一次最多 growthFactor 倍；慢的縮小，不低於下限")
    func scaling() {
        // 10 條 2 秒＝每條 0.2 秒；預算 105 秒可塞 525 條 → 受 4 倍與上限 120 夾住
        #expect(Policy.nextBatchSize(previous: 10, elapsed: 2, budget: 105, ceiling: Policy.maxBatchSize) == 40)
        #expect(Policy.nextBatchSize(previous: 40, elapsed: 8, budget: 105, ceiling: Policy.maxBatchSize) == 120)
        // 10 條 120 秒＝每條 12 秒（grok）；預算內只塞得下 8 條
        #expect(Policy.nextBatchSize(previous: 10, elapsed: 120, budget: 105, ceiling: Policy.maxBatchSize) == 8)
        // 再慢也不會低於下限
        #expect(Policy.nextBatchSize(previous: 5, elapsed: 600, budget: 105, ceiling: Policy.maxBatchSize) == Policy.minBatchSize)
    }

    /// 被截斷過一次就壓下來的上限，之後再快也不該長回去——否則在放大→截斷→砍半之間震盪。
    @Test("ceiling 壓住放大；沒有量測資料時維持原批量")
    func ceiling() {
        #expect(Policy.nextBatchSize(previous: 10, elapsed: 1, budget: 105, ceiling: 20) == 20)
        #expect(Policy.nextBatchSize(previous: 30, elapsed: 0, budget: 105, ceiling: Policy.maxBatchSize) == 30)
        #expect(Policy.nextBatchSize(previous: 0, elapsed: 5, budget: 105, ceiling: Policy.maxBatchSize) == Policy.minBatchSize)
    }

    @Test("預算與子行程逾時同源")
    func budget() {
        let timeout = Double(CLIUITranslationBatchRunner.defaultTimeout.components.seconds)
        #expect(Policy.batchBudgetSeconds == timeout * Policy.batchTimeBudget)
        #expect(Policy.batchBudgetSeconds < timeout)
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
