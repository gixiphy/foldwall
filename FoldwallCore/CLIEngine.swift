//  CLIEngine.swift
//  本機 AI CLI（claude／codex／agy／grok／opencode／pi）的目錄、呼叫、輸出解析與錯誤。
//
//  移植自 Chorus 的 AdviceEngineRegistry＋CLIAdviceProvider，砍掉送照片那條路——
//  Foldwall 只拿它翻譯介面文字（見 UITranslationStore）。零金鑰：Foldwall 不經手
//  任何 API key，呼叫的是使用者本機已登入的 CLI，計費在他自己的訂閱上。
//
//  每一家的參數組都是實測出來的，不是照文件抄的：各家 headless 行為差異很大
//  （誰要權限旗標、回應在 stdout 還是 envelope 的哪個欄位），猜錯的症狀往往是
//  「跑完了但沒有輸出」這種難查的失敗。

import Foundation

// MARK: - 目錄

/// 已知 CLI 目錄的一筆。偵測到誰就在設定頁列誰；預設引擎＝claude（存在時）。
public struct KnownCLIEngine: Identifiable, Sendable {
    public let id: String
    public let executableName: String
    public let displayName: String
    public let codec: CLIOutputCodec
    /// 支援 `--model`／`-m`：設定頁給一個自訂模型欄位。
    public let supportsModelSelection: Bool
    /// 未登入時提示使用者到終端執行的指令。
    public let loginCommand: String

    /// 模型欄位的格式提示。各家寫法不同——尤其 opencode 要 `provider/model`，
    /// 只填模型名會直接失敗，這種事不該讓使用者自己試出來。
    /// computed 而非存在 catalog 裡：`static let` 會把翻譯結果凍在第一次取用那一刻。
    public var modelHint: String {
        switch id {
        case "claude": String(localized: "別名 opus／sonnet／fable，或完整名稱如 claude-opus-5", bundle: .foldwallCore)
        case "agy": String(localized: "slug，如 gemini-3.1-pro-high、claude-sonnet-4-6", bundle: .foldwallCore)
        case "codex": String(localized: "模型名稱，如 gpt-5.6-terra", bundle: .foldwallCore)
        case "opencode": String(localized: "provider/model 格式", bundle: .foldwallCore)
        case "pi": String(localized: "provider/model 格式，與 pi --list-models 列的一致", bundle: .foldwallCore)
        default: String(localized: "模型 ID", bundle: .foldwallCore)
        }
    }

    /// 可靠的模型列舉方式；沒有就 nil（欄位維持純輸入，不編造清單）。
    /// claude 沒有非互動的列舉指令，改用 `suggestedModels` 的穩定別名。
    public var modelListing: ModelListing? {
        switch id {
        case "agy": .command(arguments: ["models"], format: .tabSeparated)
        case "grok": .command(arguments: ["models"], format: .markerList)
        case "opencode": .command(arguments: ["models"], format: .plainLines)
        case "pi": .command(arguments: ["--list-models"], format: .whitespaceColumns)
        case "codex": .codexModelsCache
        default: nil
        }
    }

    /// 靜態建議項。只放**設計上穩定**的東西（claude 的別名恆指向當代最新模型），
    /// 不放具體版本號——那種清單放著就會過期。
    public var suggestedModels: [String] {
        id == "claude" ? ["opus", "sonnet", "fable", "haiku"] : []
    }

    /// 模型清單的來源。各家不同，照實反映。
    public enum ModelListing: Sendable {
        /// 跑 `<cli> <arguments>` 取得清單。
        case command(arguments: [String], format: CommandFormat)
        /// codex 沒有非互動的列舉指令（`codex models` 會轉進互動式 TUI 並因非 TTY 失敗），
        /// 但它自己在 `~/.codex/models_cache.json` 維護一份抓好的清單——直接讀那份，
        /// 唯讀、不動使用者的檔案。
        case codexModelsCache

        public enum CommandFormat: Sendable {
            /// 每行一個 slug（opencode：`provider/model`）。
            case plainLines
            /// 散文清單，項目以 `*`／`-` 起頭（grok：`  * grok-4.6 (default)`）。
            case markerList
            /// `<slug>\t<顯示名>`（agy）。
            case tabSeparated
            /// 空白對齊的表格＋表頭（pi `--list-models`：`provider  model  context  …`），
            /// 取 provider 與 model 兩欄拼成 `provider/model`。
            case whitespaceColumns
        }
    }

    /// 單發呼叫需要的執行期資訊。
    public struct RunContext: Sendable {
        /// 這次呼叫的沙箱目錄——只放 schema 檔。需要明示宣告工作目錄的 CLI
        /// （agy `--add-dir`、codex `--cd`、grok `--cwd`、opencode `--dir`）都指向這裡。
        public var sandbox: URL?
        /// 寫在沙箱裡的 JSON Schema 檔（吃 schema 檔的引擎才用）。
        public var schemaFile: URL?
        /// 使用者填的模型字串；留空＝用 CLI 自己的預設。
        public var model: String?
        /// 子行程逾時；CLI 自帶 timeout 參數的會設得比它略短，
        /// 讓 CLI 自己乾淨收尾而不是被我們 SIGTERM。
        public var timeout: Duration

        public init(sandbox: URL? = nil, schemaFile: URL? = nil, model: String? = nil,
                    timeout: Duration = .seconds(120)) {
            self.sandbox = sandbox
            self.schemaFile = schemaFile
            self.model = model
            self.timeout = timeout
        }
    }

    /// 單發呼叫的參數與 prompt 傳遞方式。
    /// claude 走 stdin（prompt 長，避開 argv）；其餘以參數帶 prompt。
    public func invocation(prompt: String, run: RunContext) -> (arguments: [String], stdin: String?) {
        let model = run.model?.trimmingCharacters(in: .whitespaces) ?? ""
        switch id {
        case "claude":
            // 翻譯不需要任何工具；不給 --allowedTools 就不會有權限對話框的問題
            var arguments = ["-p", "--output-format", "json"]
            if !model.isEmpty { arguments += ["--model", model] }
            return (arguments, prompt)

        case "agy":
            var arguments = ["-p", prompt, "--output-format", "json"]
            // headless 無法互動式詢問權限；--add-dir 明示宣告工作目錄（範圍限於沙箱），
            // 不用 --dangerously-skip-permissions（那會放行所有工具）。
            if let sandbox = run.sandbox { arguments += ["--add-dir", sandbox.path] }
            if let schema = run.schemaFile { arguments += ["--json-schema", schema.path] }
            if !model.isEmpty { arguments += ["--model", model] }
            arguments += ["--print-timeout", "\(Self.innerTimeoutSeconds(run))s"]
            return (arguments, nil)

        case "grok":
            var arguments = ["-p", prompt, "--output-format", "json"]
            if let sandbox = run.sandbox { arguments += ["--cwd", sandbox.path] }
            if !model.isEmpty { arguments += ["--model", model] }
            return (arguments, nil)

        case "codex":
            // --skip-git-repo-check 必要——沙箱目錄不是 git repo。
            var arguments = ["exec", "--sandbox", "read-only", "--skip-git-repo-check"]
            if let sandbox = run.sandbox { arguments += ["--cd", sandbox.path] }
            if !model.isEmpty { arguments += ["--model", model] }
            arguments.append(prompt)
            return (arguments, nil)

        case "opencode":
            var arguments = ["run", "--dir", run.sandbox?.path ?? FileManager.default.temporaryDirectory.path]
            if !model.isEmpty { arguments += ["--model", model] }
            arguments.append(prompt)
            return (arguments, nil)

        case "pi":
            // pi 沒有 --cd／--cwd，會從行程 cwd 自動撈 AGENTS.md／CLAUDE.md、extensions、
            // skills、prompt templates——沙箱指不過去，只能把探索全關掉，否則使用者
            // 機器上的擴充會默默改變翻譯行為（難查、且無法重現）。--no-tools 直接免掉
            // 權限問題：翻譯不需要任何工具。沒有內建 timeout 參數，只靠我們的 watchdog。
            // 參數順序：pi [options] [messages...]，prompt 排最後。
            var arguments = ["-p", "--no-session", "--no-tools",
                             "--no-context-files", "--no-extensions",
                             "--no-skills", "--no-prompt-templates"]
            if !model.isEmpty { arguments += ["--model", model] }
            arguments.append(prompt)
            return (arguments, nil)

        default:
            return (["-p", prompt], nil)
        }
    }

    /// CLI 自己的逾時：比我們的 watchdog 早 10 秒收手，讓它吐錯誤而不是被砍。
    private static func innerTimeoutSeconds(_ run: RunContext) -> Int {
        max(Int(run.timeout.components.seconds) - 10, 30)
    }

    public static func named(_ id: String) -> KnownCLIEngine? {
        catalog.first { $0.id == id }
    }

    /// Gemini CLI 不在目錄中：Google 已於 2026-06-18 停用（個人帳號停止服務），
    /// 官方遷移目標即 Antigravity CLI（agy）。
    public static let catalog: [KnownCLIEngine] = [
        KnownCLIEngine(id: "claude", executableName: "claude", displayName: "Claude Code",
                       codec: .jsonEnvelope, supportsModelSelection: true, loginCommand: "claude /login"),
        KnownCLIEngine(id: "codex", executableName: "codex", displayName: "Codex CLI",
                       codec: .plainStdout, supportsModelSelection: true, loginCommand: "codex login"),
        KnownCLIEngine(id: "agy", executableName: "agy", displayName: "Antigravity",
                       codec: .responseEnvelope, supportsModelSelection: true, loginCommand: "agy"),
        KnownCLIEngine(id: "grok", executableName: "grok", displayName: "Grok Build",
                       codec: .textEnvelope, supportsModelSelection: true, loginCommand: "grok"),
        KnownCLIEngine(id: "opencode", executableName: "opencode", displayName: "OpenCode",
                       codec: .plainStdout, supportsModelSelection: true, loginCommand: "opencode auth login"),
        // pi `-p` 預設 text 模式：stdout 只有最終回覆（thinking 不進 stdout），
        // 錯誤與進度在 stderr。未登入時 stderr 是 "No API key found for <provider>."、
        // 退出碼 1（實測 pi 0.85.0）。登入走互動式的 /login，所以登入指令就是 `pi`。
        KnownCLIEngine(id: "pi", executableName: "pi", displayName: "Pi",
                       codec: .plainStdout, supportsModelSelection: true, loginCommand: "pi"),
    ]
}

// MARK: - 偵測

/// 在磁碟上找 CLI 執行檔。純函式：掃描順序是自訂路徑 → PATH → 常見安裝位置。
public enum CLIEngineLocator {

    /// GUI app 的 PATH 通常只有系統目錄，補上常見安裝位置。
    /// 家目錄安裝（官方 installer 位置）排在 Homebrew 之前：同一台機器可能有多份，
    /// 優先挑終端實際在用的那顆，鑰匙圈授權才共用得到，否則每次都再跳一次授權視窗。
    public static let knownDirectories = [
        NSHomeDirectory() + "/.local/bin",
        NSHomeDirectory() + "/.claude/local",
        NSHomeDirectory() + "/.grok/bin",
        NSHomeDirectory() + "/.codex/bin",
        NSHomeDirectory() + "/.opencode/bin",
        // pi.dev/install.sh：PATH 裡有 ~/.local/bin 或 ~/bin 就放那裡，都沒有時退到這裡
        NSHomeDirectory() + "/.pi/agent/bin",
        NSHomeDirectory() + "/bin",
        "/opt/homebrew/bin", "/usr/local/bin",
    ]

    public static func locate(
        _ engine: KnownCLIEngine,
        customPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var candidates: [String] = []
        if let customPath, !customPath.isEmpty {
            candidates.append((customPath as NSString).expandingTildeInPath)
        }
        let pathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in pathDirs + knownDirectories {
            candidates.append(dir + "/" + engine.executableName)
        }
        let fm = FileManager.default
        return candidates
            .first { fm.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// `--version` 的第一行，供設定頁顯示；失敗回 nil、不影響可用性。
    public static func readVersion(of url: URL) -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        process.environment = CLIProcessRunner.whitelistedEnvironment(
            executableDirectory: url.deletingLastPathComponent().path)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate(); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first
    }
}

// MARK: - 模型列舉

/// 問 CLI 有哪些模型可用。存在的理由：模型字串各家寫法不同（opencode 要
/// `provider/model`，只填模型名直接失敗），讓使用者自己猜是不合理的。
/// 解析是純函式，可單獨測；抓取會打網路，由呼叫端決定何時做與怎麼快取。
public enum CLIModelLister {

    /// `<cli> models` 的輸出解析。
    public static func parseModels(
        _ output: String,
        format: KnownCLIEngine.ModelListing.CommandFormat
    ) -> [String] {
        let lines = output.components(separatedBy: .newlines)
        switch format {
        case .tabSeparated:
            // agy：`<slug>\t<顯示名>`。沒有 tab 的行（"Fetching available models..."
            // 之類）一律略過。
            return lines.compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                let slug = parts[0].trimmingCharacters(in: .whitespaces)
                return slug.isEmpty ? nil : slug
            }
        case .plainLines:
            // opencode：每行就是一個 provider/model。沒有斜線的是雜訊行。
            return lines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.contains("/") && !$0.contains(" ") }
        case .markerList:
            // grok：`  * grok-4.6 (default)`／`  - grok-4.5`；
            // 標題行（"Available models:"）沒有項目符號，自然被濾掉。
            return lines.compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("* ") || trimmed.hasPrefix("- ") else { return nil }
                let body = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                // 去掉 "(default)" 之類的尾註
                let slug = body.split(separator: " ").first.map(String.init) ?? body
                return slug.isEmpty ? nil : slug
            }
        case .whitespaceColumns:
            // pi：`provider  model  context  max-out  thinking  images` 表頭＋空白對齊的列。
            // 只認表頭**之後**、欄數與表頭相同的列——沒登入時它印的是一段散文
            // （"No models available. Use /login…"），沒有表頭就什麼都不列，
            // 不會把散文拆成 "No/models"。欄位位置照表頭找，欄位順序改了也不會拼錯。
            let rows = lines.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            guard let header = rows.firstIndex(where: { $0.contains("provider") && $0.contains("model") }) else { return [] }
            let columns = rows[header]
            let providerColumn = columns.firstIndex(of: "provider") ?? 0
            let modelColumn = columns.firstIndex(of: "model") ?? 1
            return rows[(header + 1)...].compactMap { parts in
                guard parts.count == columns.count, modelColumn < parts.count else { return nil }
                let provider = parts[providerColumn]
                let model = parts[modelColumn]
                guard !provider.isEmpty, !model.isEmpty else { return nil }
                return "\(provider)/\(model)"
            }
        }
    }

    public static var codexModelsCachePath: String {
        NSString(string: "~/.codex/models_cache.json").expandingTildeInPath
    }

    /// codex 的模型快取：取 `visibility == "list"` 的 slug——標 `hide` 的是它自己
    /// 不放進選單的（legacy／內部），我們也不該列。
    public static func parseCodexModelsCache(_ data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]]
        else { return [] }
        return models.compactMap { model in
            guard let slug = model["slug"] as? String, !slug.isEmpty else { return nil }
            // 沒有 visibility 欄位時保守納入（欄位是新加的就不該整份變空）
            guard (model["visibility"] as? String ?? "list") == "list" else { return nil }
            return slug
        }
    }

    /// 依 `listing` 取得清單；失敗回空陣列——沒有下拉選單而已，輸入欄位照常可用。
    /// **會阻塞**（列舉要打網路，實測 grok／opencode 各十餘秒），呼叫端請丟到背景。
    public static func fetch(_ listing: KnownCLIEngine.ModelListing, executable: URL) -> [String] {
        switch listing {
        case let .command(arguments, format):
            guard let output = runListing(at: executable, arguments: arguments) else { return [] }
            return parseModels(output, format: format)
        case .codexModelsCache:
            guard let data = FileManager.default.contents(atPath: codexModelsCachePath) else { return [] }
            return parseCodexModelsCache(data)
        }
    }

    private static func runListing(at url: URL, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.environment = CLIProcessRunner.whitelistedEnvironment(
            executableDirectory: url.deletingLastPathComponent().path)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning { process.terminate(); return nil }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}

// MARK: - 輸出解析

/// CLI stdout → 結構化回覆的解析方式。四種收斂到同一條尾巴：取回應文字 → 剝 fence → decode。
public enum CLIOutputCodec: String, Codable, Sendable {
    /// claude `--output-format json`：單一 JSON envelope，取 `result` 欄位。
    case jsonEnvelope
    /// agy `--output-format json`：欄位是 `response`；帶 `--json-schema` 時另有
    /// 已解析好的 `structured_output`，優先吃那個（CLI 依 schema 驗過）。
    case responseEnvelope
    /// grok `--output-format json`：欄位是 `text`。
    case textEnvelope
    /// codex／opencode：前言與進度寫 stderr，stdout 只有最終回覆。
    case plainStdout
}

/// 解析失敗的型別化錯誤；`raw` 帶原始文字供 UI 顯示。
public enum CLIDecodeError: Error, Equatable, Sendable {
    case emptyOutput
    case envelopeParseFailed(raw: String)
    /// CLI 在 envelope 中回報執行錯誤（`is_error: true`）。
    case cliReportedError(message: String)
    case bodyParseFailed(raw: String)
}

public enum CLICodec {

    public static func decode<T: Decodable>(stdout: String, codec: CLIOutputCodec, as type: T.Type) throws -> T {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CLIDecodeError.emptyOutput }

        let responseText: String
        switch codec {
        case .jsonEnvelope:
            responseText = try envelopeResult(from: trimmed)
        case .responseEnvelope:
            if let structured: T = try structuredOutput(from: trimmed) { return structured }
            responseText = try stringField("response", from: trimmed)
        case .textEnvelope:
            responseText = try stringField("text", from: trimmed)
        case .plainStdout:
            responseText = trimmed
        }

        let body = strippingCodeFence(responseText)
        if let value: T = decodeBody(body) { return value }
        // 模型常在 JSON 前面加一段旁白。整段 decode 必然失敗，但那段 JSON 本身是好的——
        // 撈出第一個成對的大括號區塊再試一次，比叫模型重來便宜得多。
        if let embedded = firstJSONObject(in: body), let value: T = decodeBody(embedded) {
            return value
        }
        throw CLIDecodeError.bodyParseFailed(raw: responseText)
    }

    private static func decodeBody<T: Decodable>(_ text: String) -> T? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// 文字中第一個成對的 `{…}` 區塊。以括號深度掃描，略過字串字面值裡的括號與逃逸字元。
    public static func firstJSONObject(in text: String) -> String? {
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if escaped { escaped = false; continue }
            if inString {
                if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"":
                inString = true
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                guard depth > 0 else { break }
                depth -= 1
                if depth == 0, let start { return String(text[start...index]) }
            default:
                break
            }
        }
        return nil
    }

    /// 剝除包住整段回應的 markdown code fence；沒有 fence 原樣返回。
    public static func strippingCodeFence(_ text: String) -> String {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        guard let first = lines.first, first.hasPrefix("```") else { return text }
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func structuredOutput<T: Decodable>(from text: String) throws -> T? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let structured = object["structured_output"]
        else { return nil }
        guard let encoded = try? JSONSerialization.data(withJSONObject: structured),
              let value = try? JSONDecoder().decode(T.self, from: encoded)
        else { throw CLIDecodeError.bodyParseFailed(raw: text) }
        return value
    }

    /// 取 envelope 的某個字串欄位；缺欄位或內容為空都視為失敗。
    /// **不看 `status`**：agy headless 權限被拒時 `status` 仍是 SUCCESS、`response` 是空字串。
    private static func stringField(_ key: String, from text: String) throws -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CLIDecodeError.envelopeParseFailed(raw: text) }
        guard let value = object[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw CLIDecodeError.emptyOutput }
        return value
    }

    private static func envelopeResult(from text: String) throws -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CLIDecodeError.envelopeParseFailed(raw: text) }
        let result = object["result"] as? String
        if let isError = object["is_error"] as? Bool, isError {
            throw CLIDecodeError.cliReportedError(message: result ?? text)
        }
        guard let result else { throw CLIDecodeError.envelopeParseFailed(raw: text) }
        return result
    }
}

// MARK: - 錯誤

public enum CLIEngineError: Error, Sendable {
    /// 選定引擎的執行檔不存在。
    case engineNotFound(engineID: String)
    /// CLI 回報未登入／未認證。
    case notLoggedIn(engineID: String)
    /// 逾時後已終止子行程。
    case timedOut
    /// 非零退出且非認證問題；帶 stderr 摘要。
    case processFailed(status: Int32, stderr: String)
    /// 重試一次後仍無法解析；帶模型原始回覆。
    case decodeFailed(raw: String)
    /// CLI 跑完了但沒有產出任何回應（agy headless 權限被拒是典型情況）。
    case emptyResponse(engineID: String, detail: String)

    public var userMessage: String {
        switch self {
        case let .engineNotFound(engineID):
            String(localized: "找不到 \(engineID)，請確認已安裝", bundle: .foldwallCore)
        case let .notLoggedIn(engineID):
            String(localized: "\(engineID) 未登入或憑證已失效，請在終端重新登入後再試", bundle: .foldwallCore)
        case .timedOut:
            String(localized: "翻譯逾時，可重試", bundle: .foldwallCore)
        case let .processFailed(status, stderr):
            stderr.isEmpty
                ? String(localized: "翻譯失敗（退出碼 \(status)），CLI 未提供錯誤訊息", bundle: .foldwallCore)
                : String(localized: "翻譯失敗（退出碼 \(status)）：\(stderr.prefix(200))", bundle: .foldwallCore)
        case let .decodeFailed(raw):
            String(localized: "模型回覆無法解析：\(raw.prefix(300))", bundle: .foldwallCore)
        case let .emptyResponse(engineID, detail):
            detail.isEmpty
                ? String(localized: "\(engineID) 沒有產出回應，可重試", bundle: .foldwallCore)
                : String(localized: "\(engineID) 沒有產出回應：\(detail.prefix(300))", bundle: .foldwallCore)
        }
    }

    /// 未登入時給使用者貼到終端的指令。
    public var loginCommand: String? {
        if case let .notLoggedIn(engineID) = self {
            return KnownCLIEngine.named(engineID)?.loginCommand ?? engineID
        }
        return nil
    }
}

// MARK: - 子行程

/// 子行程執行工具：pipe I/O、環境白名單注入、逾時終止、取消終止。
public enum CLIProcessRunner {
    public struct Output: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
    }

    /// 白名單環境；PATH 前置執行檔目錄，讓 CLI 找得到自帶 runtime。
    /// USER 必要：claude CLI 靠它查 Keychain 憑證，缺了會誤報「未登入」。
    public static func whitelistedEnvironment(executableDirectory: String) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let basePath = inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var environment = [
            "PATH": "\(executableDirectory):\(basePath):/opt/homebrew/bin:/usr/local/bin",
            "HOME": inherited["HOME"] ?? NSHomeDirectory(),
            "TERM": inherited["TERM"] ?? "xterm-256color",
            "USER": inherited["USER"] ?? NSUserName(),
            "LOGNAME": inherited["LOGNAME"] ?? NSUserName(),
        ]
        if let tmpdir = inherited["TMPDIR"] { environment["TMPDIR"] = tmpdir }
        return environment
    }

    /// 執行到結束；逾時或取消都 terminate 子行程。
    /// stdout/stderr 在獨立執行緒並行讀取，避免管線塞滿造成死鎖。
    public static func run(
        executable: URL,
        arguments: [String],
        stdin stdinText: String?,
        timeout: Duration
    ) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = whitelistedEnvironment(
            executableDirectory: executable.deletingLastPathComponent().path)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        let flags = Flags()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // handler 先於 run() 設定，保證必被呼叫
                process.terminationHandler = { _ in
                    if flags.claimResume() { continuation.resume() }
                }
                do {
                    try process.run()
                } catch {
                    if flags.claimResume() { continuation.resume(throwing: error) }
                    return
                }

                if let stdinText {
                    let handle = stdinPipe.fileHandleForWriting
                    Thread.detachNewThread {
                        try? handle.write(contentsOf: Data(stdinText.utf8))
                        try? handle.close()
                    }
                } else {
                    try? stdinPipe.fileHandleForWriting.close()
                }

                // 逾時 watchdog：時限到還在跑就 terminate（terminationHandler 負責 resume）
                let seconds = Double(timeout.components.seconds)
                    + Double(timeout.components.attoseconds) / 1e18
                Thread.detachNewThread {
                    let deadline = Date().addingTimeInterval(seconds)
                    while process.isRunning, Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                    if process.isRunning {
                        flags.markTimedOut()
                        process.terminate()
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        let stdout = await readToEnd(stdoutPipe.fileHandleForReading)
        let stderr = await readToEnd(stderrPipe.fileHandleForReading)

        try Task.checkCancellation()
        if flags.timedOut { throw CLIEngineError.timedOut }
        return Output(
            status: process.terminationStatus,
            stdout: String(data: stdout, encoding: .utf8) ?? "",
            stderr: String(data: stderr, encoding: .utf8) ?? ""
        )
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let data = (try? handle.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }

    /// 一次性 resume 與逾時標記（terminationHandler / run 失敗 / watchdog 之間共享）。
    private final class Flags: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private var didTimeOut = false

        func claimResume() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }

        func markTimedOut() {
            lock.lock(); defer { lock.unlock() }
            didTimeOut = true
        }

        var timedOut: Bool {
            lock.lock(); defer { lock.unlock() }
            return didTimeOut
        }
    }
}

// MARK: - 單發執行

/// 單發 → 解析 → decode 失敗重試一次 → 型別化錯誤映射。輸出型別由呼叫端指定。
public enum CLIExecution {

    /// 兩種 prompt 共用的收尾句：只要 JSON，不要 fence。
    public static let outputInstruction =
        "Output exactly one JSON object (no markdown fence, no other text) that conforms to this JSON Schema:"

    /// decode 失敗重試一次時附加的修正指示。
    public static let retryInstruction =
        "(The previous output could not be parsed as JSON matching the schema. "
        + "Output again: exactly one JSON object, with no other text and no fences.)"

    public static func perform<T: Decodable>(
        engine: KnownCLIEngine,
        executable: URL,
        basePrompt: String,
        run: KnownCLIEngine.RunContext,
        as type: T.Type
    ) async throws -> T {
        do {
            return try await attempt(prompt: basePrompt, engine: engine, executable: executable, run: run, as: type)
        } catch let error as CLIDecodeError {
            // CLI 自報的執行錯誤（如未認證）重試也不會好，直接映射
            if case let .cliReportedError(message) = error {
                throw mapReportedError(engineID: engine.id, message: message)
            }
            do {
                return try await attempt(
                    prompt: basePrompt + "\n\n" + retryInstruction,
                    engine: engine, executable: executable, run: run, as: type)
            } catch let retryError as CLIDecodeError {
                throw CLIEngineError.decodeFailed(raw: rawText(from: retryError))
            }
        }
    }

    /// schema 檔一律寫進沙箱。寫不出來就回 nil——少了 `--json-schema` 只是退回
    /// 文字解析路徑，不該讓整次呼叫失敗。
    public static func writeSchema(_ schemaJSON: String, into sandbox: URL?) -> URL? {
        guard let sandbox else { return nil }
        let url = sandbox.appendingPathComponent("schema.json")
        do {
            try Data(schemaJSON.utf8).write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    private static func attempt<T: Decodable>(
        prompt: String,
        engine: KnownCLIEngine,
        executable: URL,
        run: KnownCLIEngine.RunContext,
        as type: T.Type
    ) async throws -> T {
        let invocation = engine.invocation(prompt: prompt, run: run)
        let output: CLIProcessRunner.Output
        do {
            output = try await CLIProcessRunner.run(
                executable: executable, arguments: invocation.arguments,
                stdin: invocation.stdin, timeout: run.timeout)
        } catch let error as CLIEngineError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CLIEngineError.engineNotFound(engineID: engine.id)
        }

        guard output.status == 0 else {
            throw mapNonZeroExit(engineID: engine.id, output: output)
        }
        do {
            return try CLICodec.decode(stdout: output.stdout, codec: engine.codec, as: type)
        } catch CLIDecodeError.emptyOutput {
            // 退出碼 0 但沒有回應：原因只在 stderr，接過來給使用者看
            throw CLIEngineError.emptyResponse(
                engineID: engine.id,
                detail: sanitized(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    private static func mapReportedError(engineID: String, message: String) -> CLIEngineError {
        if authMarkers.contains(where: message.lowercased().contains) {
            return .notLoggedIn(engineID: engineID)
        }
        return .processFailed(status: 0, stderr: sanitized(message))
    }

    private static let authMarkers = [
        "not logged in", "login", "log in", "authentication", "authenticate",
        "unauthorized", "oauth", "revoked", "401", "api key", "credential",
    ]

    /// 非零退出：stderr／stdout 含認證字樣 → 未登入；其餘帶錯誤摘要。
    /// claude `--output-format json` 出錯時 stderr 是空的、訊息在 stdout 的 envelope
    /// `result` 欄位，stderr 空白時退回從 stdout 取。
    static func mapNonZeroExit(engineID: String, output: CLIProcessRunner.Output) -> CLIEngineError {
        let combined = (output.stderr + "\n" + output.stdout).lowercased()
        if authMarkers.contains(where: combined.contains) {
            return .notLoggedIn(engineID: engineID)
        }
        var message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            message = envelopeResultText(from: output.stdout)
                ?? output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return .processFailed(status: output.status, stderr: sanitized(message))
    }

    private static func envelopeResultText(from stdout: String) -> String? {
        guard let data = stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["result"] as? String
    }

    /// stderr 入 UI／log 前過濾疑似 token 字樣。
    static func sanitized(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(sk-[A-Za-z0-9-_]{8,}|Bearer\s+\S+|eyJ[A-Za-z0-9-_.]{16,})"#,
            with: "[redacted]",
            options: .regularExpression)
    }

    private static func rawText(from error: CLIDecodeError) -> String {
        switch error {
        case .emptyOutput: ""
        case let .envelopeParseFailed(raw): raw
        case let .cliReportedError(message): message
        case let .bodyParseFailed(raw): raw
        }
    }
}
