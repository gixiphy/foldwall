//  CLIEngine.swift
//  本機 AI CLI（claude／codex／agy／grok／opencode／pi…）的目錄、呼叫、探測、輸出解析與錯誤。
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
///
/// 模型一律用各 CLI 自己的預設：模型名／別名的壽命比 App 的發版週期短得多，
/// 讓使用者在設定頁填一個會過期的字串，只會製造「昨天還好的引擎今天壞了」。
public struct KnownCLIEngine: Identifiable, Sendable {

    /// 登入狀態的探測方式。三種都只**讀**狀態，不碰憑證內容、不寫任何檔。
    public enum AuthProbe: Sendable {
        /// 跑 `<cli> <arguments>`：退出碼 0 = 已登入。
        case command(arguments: [String])
        /// 憑證檔（相對家目錄）存在即已登入。
        case credentialFile(path: String)
        /// 環境變數任一存在且非空即已登入（吃 API key 的 CLI）。
        case environmentKey(names: [String])
    }

    public let id: String
    public let executableName: String
    public let displayName: String
    public let codec: CLIOutputCodec
    /// headless 行為尚未在本機驗證過：可選，標「實驗性」。
    public let experimental: Bool
    /// 這家 CLI 額外需要的環境變數，在 `CLIProcessRunner.whitelistedEnvironment`
    /// 之後合併（goose 不設 `GOOSE_MODE` 會在非互動模式下等權限確認）。
    public let extraEnvironment: [String: String]
    /// 登入狀態怎麼查；沒有可靠查法就 nil（狀態顯示為未知，照常列出）。
    public let authProbe: AuthProbe?
    /// 未登入時提示使用者到終端執行的指令；沒有就空字串。
    public let loginCommand: String

    public init(id: String, executableName: String, displayName: String, codec: CLIOutputCodec,
                experimental: Bool = false, extraEnvironment: [String: String] = [:],
                authProbe: AuthProbe? = nil, loginCommand: String) {
        self.id = id
        self.executableName = executableName
        self.displayName = displayName
        self.codec = codec
        self.experimental = experimental
        self.extraEnvironment = extraEnvironment
        self.authProbe = authProbe
        self.loginCommand = loginCommand
    }

    /// 單發呼叫需要的執行期資訊。
    public struct RunContext: Sendable {
        /// 這次呼叫的沙箱目錄——只放 schema 檔。需要明示宣告工作目錄的 CLI
        /// （agy `--add-dir`、codex `--cd`、grok `--cwd`、opencode `--dir`）都指向這裡。
        public var sandbox: URL?
        /// 寫在沙箱裡的 JSON Schema 檔（吃 schema 檔的引擎才用）。
        public var schemaFile: URL?
        /// 子行程逾時；CLI 自帶 timeout 參數的會設得比它略短，
        /// 讓 CLI 自己乾淨收尾而不是被我們 SIGTERM。
        public var timeout: Duration

        public init(sandbox: URL? = nil, schemaFile: URL? = nil, timeout: Duration = .seconds(120)) {
            self.sandbox = sandbox
            self.schemaFile = schemaFile
            self.timeout = timeout
        }
    }

    /// 單發呼叫的參數與 prompt 傳遞方式。
    /// claude 與 amp 走 stdin（prompt 長，避開 argv）；其餘以參數帶 prompt。
    /// **不帶任何模型旗標**：一律用 CLI 自己的預設。
    public func invocation(prompt: String, run: RunContext) -> (arguments: [String], stdin: String?) {
        switch id {
        case "claude", "openclaude":
            // 翻譯不需要任何工具；不給 --allowedTools 就不會有權限對話框的問題
            return (["-p", "--output-format", "json"], prompt)

        case "agy":
            var arguments = ["-p", prompt, "--output-format", "json"]
            // headless 無法互動式詢問權限；--add-dir 明示宣告工作目錄（範圍限於沙箱），
            // 不用 --dangerously-skip-permissions（那會放行所有工具）。
            if let sandbox = run.sandbox { arguments += ["--add-dir", sandbox.path] }
            if let schema = run.schemaFile { arguments += ["--json-schema", schema.path] }
            arguments += ["--print-timeout", "\(Self.innerTimeoutSeconds(run))s"]
            return (arguments, nil)

        case "grok":
            var arguments = ["-p", prompt, "--output-format", "json"]
            if let sandbox = run.sandbox { arguments += ["--cwd", sandbox.path] }
            return (arguments, nil)

        case "codex":
            // --skip-git-repo-check 必要——沙箱目錄不是 git repo。
            var arguments = ["exec", "--sandbox", "read-only", "--skip-git-repo-check"]
            if let sandbox = run.sandbox { arguments += ["--cd", sandbox.path] }
            arguments.append(prompt)
            return (arguments, nil)

        case "opencode", "kilo":
            // kilo 與 opencode 同家族，參數一樣。
            return (["run", "--dir", run.sandbox?.path ?? FileManager.default.temporaryDirectory.path, prompt], nil)

        case "pi":
            // pi 沒有 --cd／--cwd，會從行程 cwd 自動撈 AGENTS.md／CLAUDE.md、extensions、
            // skills、prompt templates——沙箱指不過去，只能把探索全關掉，否則使用者
            // 機器上的擴充會默默改變翻譯行為（難查、且無法重現）。--no-tools 直接免掉
            // 權限問題：翻譯不需要任何工具。沒有內建 timeout 參數，只靠我們的 watchdog。
            // 參數順序：pi [options] [messages...]，prompt 排最後。
            return (["-p", "--no-session", "--no-tools",
                     "--no-context-files", "--no-extensions",
                     "--no-skills", "--no-prompt-templates", prompt], nil)

        case "cursor":
            // --mode ask 是唯讀模式（不會編輯檔案）；--trust 免掉「信任這個目錄嗎」
            // 的互動確認，在非 TTY 下那個確認會直接讓行程掛住。
            var arguments = ["-p", "--output-format", "json", "--mode", "ask", "--trust"]
            if let sandbox = run.sandbox { arguments += ["--workspace", sandbox.path] }
            arguments.append(prompt)
            return (arguments, nil)

        case "hermes":
            // -Q 壓掉 banner／spinner；--safe-mode 不寫檔、--ignore-rules 不撈使用者的規則檔。
            return (["chat", "-q", prompt, "-Q", "--oneshot", "--safe-mode", "--ignore-rules"], nil)

        case "copilot":
            return (["-p", prompt, "-s"], nil)

        case "goose":
            // --no-session 不落 session 檔、-q 只印最終回覆。
            // 非互動模式要靠 extraEnvironment 的 GOOSE_MODE=chat 免掉工具權限確認。
            return (["run", "-t", prompt, "--no-session", "-q"], nil)

        case "amp":
            // prompt 一律走 stdin：argv 只有 -x（amp 的 headless 開關）。
            return (["-x"], prompt)

        case "droid":
            return (["exec", "-o", "json", prompt], nil)

        case "qwen":
            return (["-p", prompt, "--output-format", "text", "--approval-mode", "plan"], nil)

        case "kimi":
            // print 模式會強制自動核准工具呼叫；prompt 本身已要求不要動工具。
            return (["-p", prompt, "--quiet"], nil)

        case "omp":
            return (["-p", "--no-session", "--no-tools", prompt], nil)

        case "prime-agent":
            return (["-p", "--no-tools", "--no-session", "--no-extensions", "--no-skills", prompt], nil)

        case "mistral-vibe":
            return (["-p", prompt, "--output", "text", "--max-turns", "3"], nil)

        case "continue":
            return (["-p", prompt, "--silent"], nil)

        case "aug":
            return (["--print", prompt, "--quiet", "--dont-save-session"], nil)

        case "devin":
            return (["-p", prompt, "--permission-mode", "plan"], nil)

        case "crush":
            return (["run", "-q", prompt], nil)

        case "kiro":
            return (["chat", "--no-interactive", prompt], nil)

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

    /// 名單與 Chorus 同一份。前八家（claude…hermes）的 headless 行為是實測過的，
    /// 其餘標 `experimental`。
    ///
    /// **刻意不收**的 CLI，以及理由（收進來只會變成難查的「跑完沒有輸出」）：
    /// - Gemini CLI：Google 2026-06-18 停用個人帳號，官方遷移目標即 agy。
    /// - Codebuff：純 TUI，不認 `-p`。
    /// - MiMo Code：沒有文件化的非互動旗標。
    /// - Trae CN：binary 名稱與文件對不上，且無 JSON 輸出。
    /// - Ante：preview 階段，CLI 介面未文件化。
    /// - Rovo Dev：單則指令有 256 字上限，裝不下翻譯的 prompt。
    /// - Aider：stdout 夾 banner，且模型隨金鑰變。
    /// - OpenClaw：要先自己起一個 gateway。
    /// - Cline：只有事件流輸出，沒有終局回覆欄位。
    public static let catalog: [KnownCLIEngine] = [
        KnownCLIEngine(id: "claude", executableName: "claude", displayName: "Claude Code",
                       codec: .jsonEnvelope,
                       authProbe: .command(arguments: ["auth", "status"]),
                       loginCommand: "claude /login"),
        KnownCLIEngine(id: "codex", executableName: "codex", displayName: "Codex CLI",
                       codec: .plainStdout,
                       authProbe: .command(arguments: ["login", "status"]),
                       loginCommand: "codex login"),
        KnownCLIEngine(id: "agy", executableName: "agy", displayName: "Antigravity",
                       codec: .responseEnvelope,
                       authProbe: .credentialFile(path: ".gemini/antigravity-cli/antigravity-oauth-token"),
                       loginCommand: "agy"),
        KnownCLIEngine(id: "grok", executableName: "grok", displayName: "Grok Build",
                       codec: .textEnvelope,
                       authProbe: .credentialFile(path: ".grok/auth.json"),
                       loginCommand: "grok"),
        KnownCLIEngine(id: "opencode", executableName: "opencode", displayName: "OpenCode",
                       codec: .plainStdout,
                       authProbe: .credentialFile(path: ".local/share/opencode/auth.json"),
                       loginCommand: "opencode auth login"),
        // pi `-p` 預設 text 模式：stdout 只有最終回覆（thinking 不進 stdout），
        // 錯誤與進度在 stderr。未登入時 stderr 是 "No API key found for <provider>."、
        // 退出碼 1（實測 pi 0.85.0）。登入走互動式的 /login，所以登入指令就是 `pi`。
        KnownCLIEngine(id: "pi", executableName: "pi", displayName: "Pi",
                       codec: .plainStdout,
                       authProbe: .credentialFile(path: ".pi/agent/auth.json"),
                       loginCommand: "pi"),
        KnownCLIEngine(id: "cursor", executableName: "cursor-agent", displayName: "Cursor CLI",
                       codec: .jsonEnvelope,
                       authProbe: .command(arguments: ["status", "--format", "json"]),
                       loginCommand: "cursor-agent login"),
        KnownCLIEngine(id: "hermes", executableName: "hermes", displayName: "Hermes",
                       codec: .plainStdout,
                       authProbe: .command(arguments: ["status"]),
                       loginCommand: "hermes auth login"),
        KnownCLIEngine(id: "copilot", executableName: "copilot", displayName: "GitHub Copilot CLI",
                       codec: .plainStdout, experimental: true,
                       loginCommand: "copilot"),
        KnownCLIEngine(id: "goose", executableName: "goose", displayName: "Goose",
                       codec: .plainStdout, experimental: true,
                       extraEnvironment: ["GOOSE_MODE": "chat", "GOOSE_DISABLE_SESSION_NAMING": "1"],
                       loginCommand: "goose configure"),
        KnownCLIEngine(id: "amp", executableName: "amp", displayName: "Amp",
                       codec: .plainStdout, experimental: true,
                       authProbe: .environmentKey(names: ["AMP_API_KEY"]),
                       loginCommand: "amp login"),
        KnownCLIEngine(id: "droid", executableName: "droid", displayName: "Factory Droid",
                       codec: .jsonEnvelope, experimental: true,
                       authProbe: .environmentKey(names: ["FACTORY_API_KEY"]),
                       loginCommand: "droid"),
        KnownCLIEngine(id: "qwen", executableName: "qwen", displayName: "Qwen Code",
                       codec: .plainStdout, experimental: true,
                       authProbe: .environmentKey(names: ["OPENAI_API_KEY"]),
                       loginCommand: ""),
        KnownCLIEngine(id: "kimi", executableName: "kimi", displayName: "Kimi Code",
                       codec: .plainStdout, experimental: true,
                       loginCommand: "kimi"),
        KnownCLIEngine(id: "omp", executableName: "omp", displayName: "OMP",
                       codec: .plainStdout, experimental: true,
                       authProbe: .credentialFile(path: ".omp/agent/auth.json"),
                       loginCommand: "omp"),
        KnownCLIEngine(id: "prime-agent", executableName: "prime-agent", displayName: "Prime Agent",
                       codec: .plainStdout, experimental: true,
                       authProbe: .credentialFile(path: ".prime/agent/auth.json"),
                       loginCommand: "prime-agent"),
        KnownCLIEngine(id: "mistral-vibe", executableName: "vibe", displayName: "Mistral Vibe",
                       codec: .plainStdout, experimental: true,
                       authProbe: .environmentKey(names: ["MISTRAL_API_KEY"]),
                       loginCommand: ""),
        KnownCLIEngine(id: "continue", executableName: "cn", displayName: "Continue",
                       codec: .plainStdout, experimental: true,
                       loginCommand: "cn login"),
        KnownCLIEngine(id: "aug", executableName: "auggie", displayName: "Auggie",
                       codec: .plainStdout, experimental: true,
                       authProbe: .credentialFile(path: ".augment/session.json"),
                       loginCommand: "auggie login"),
        KnownCLIEngine(id: "devin", executableName: "devin", displayName: "Devin",
                       codec: .plainStdout, experimental: true,
                       authProbe: .command(arguments: ["auth", "status"]),
                       loginCommand: "devin auth login"),
        KnownCLIEngine(id: "kilo", executableName: "kilo", displayName: "Kilocode",
                       codec: .plainStdout, experimental: true,
                       authProbe: .credentialFile(path: ".local/share/kilo/auth.json"),
                       loginCommand: "kilo auth login"),
        KnownCLIEngine(id: "crush", executableName: "crush", displayName: "Charm Crush",
                       codec: .plainStdout, experimental: true,
                       loginCommand: ""),
        KnownCLIEngine(id: "command-code", executableName: "command-code", displayName: "Command Code",
                       codec: .plainStdout, experimental: true,
                       loginCommand: ""),
        KnownCLIEngine(id: "kiro", executableName: "kiro-cli", displayName: "Kiro",
                       codec: .plainStdout, experimental: true,
                       authProbe: .command(arguments: ["whoami"]),
                       loginCommand: "kiro-cli login"),
        KnownCLIEngine(id: "openclaude", executableName: "openclaude", displayName: "OpenClaude",
                       codec: .jsonEnvelope, experimental: true,
                       loginCommand: ""),
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
        NSHomeDirectory() + "/.hermes/bin",
        NSHomeDirectory() + "/.factory/bin",
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

}

// MARK: - 探測

/// 執行探測（`--version`）的結果。
public enum CLIProbeState: Equatable, Sendable {
    /// 還在跑（掃描剛開始）。
    case pending
    /// 期限內結束＝跑得起來；退出碼 0 才有版本字串。
    case ready(version: String?)
    /// 跑不起來或逾時：不列進可用清單。
    case failed
}

/// 登入狀態。沒有 `authProbe` 的引擎恆為 `.unknown`，照常可選。
public enum CLIAuthState: Equatable, Sendable {
    case unknown
    case loggedIn
    case notLoggedIn
}

/// 「檔案在」只是第一關：同一台機器上常有半裝好的 CLI（npm 裝了但 runtime 不在、
/// wrapper 指向已刪的版本），列出它們只會讓使用者選到一個一按翻譯就失敗的引擎。
/// 這裡的兩種探測都只是狀態查詢，會阻塞，呼叫端請丟到背景。
public enum CLIEngineProbe {

    /// 探測（`--version`、auth command）的期限。兩者都該是毫秒級的本機查詢，
    /// 拖過這個時間就當它壞了——設定頁不該為了一支半裝好的 CLI 卡住。
    public static let timeout: TimeInterval = 5

    /// 跑 `--version`：這同時是「跑不跑得起來」的判準，版本字串只是附帶收穫。
    public static func probeExecutable(at url: URL, extraEnvironment: [String: String] = [:]) -> CLIProbeState {
        guard let result = run(at: url, arguments: ["--version"], extraEnvironment: extraEnvironment) else {
            return .failed
        }
        guard result.status == 0 else { return .ready(version: nil) }
        let version = result.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first
        return .ready(version: (version?.isEmpty ?? true) ? nil : version)
    }

    /// 單一 auth probe 的判定。失敗（跑不起來、逾時）一律 `.unknown`：
    /// 探測本身不該變成「不能用這家」的理由。`home` 與 `environment` 可注入供測試。
    public static func evaluateAuth(
        _ probe: KnownCLIEngine.AuthProbe,
        executable: URL,
        extraEnvironment: [String: String] = [:],
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CLIAuthState {
        switch probe {
        case let .command(arguments):
            guard let result = run(at: executable, arguments: arguments, extraEnvironment: extraEnvironment) else {
                return .unknown
            }
            return result.status == 0 ? .loggedIn : .notLoggedIn

        case let .credentialFile(path):
            let full = URL(fileURLWithPath: home).appendingPathComponent(path).path
            return FileManager.default.fileExists(atPath: full) ? .loggedIn : .notLoggedIn

        case let .environmentKey(names):
            // App 是 GUI 啟動的，通常拿不到 shell 裡 export 的金鑰；
            // 拿不到就報未登入，設定頁會提示到終端跑登入指令。
            let present = names.contains { environment[$0]?.isEmpty == false }
            return present ? .loggedIn : .notLoggedIn
        }
    }

    /// 狀態查詢用的同步 spawn：`timeout` 內沒結束就 terminate 並回 nil。
    private static func run(
        at url: URL, arguments: [String], extraEnvironment: [String: String]
    ) -> (status: Int32, stdout: String)? {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        var environment = CLIProcessRunner.whitelistedEnvironment(
            executableDirectory: url.deletingLastPathComponent().path)
        environment.merge(extraEnvironment) { _, new in new }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate(); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
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
        timeout: Duration,
        extraEnvironment: [String: String] = [:]
    ) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = whitelistedEnvironment(
            executableDirectory: executable.deletingLastPathComponent().path)
        // 引擎自己聲明的變數蓋在白名單之上（goose 的 GOOSE_MODE 之類）
        environment.merge(extraEnvironment) { _, new in new }
        process.environment = environment

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
                stdin: invocation.stdin, timeout: run.timeout,
                extraEnvironment: engine.extraEnvironment)
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
