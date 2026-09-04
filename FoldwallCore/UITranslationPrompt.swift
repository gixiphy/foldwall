//  UITranslationPrompt.swift
//  「用本機 AI CLI 翻譯介面」的 prompt、回覆型別、驗證與批次執行。
//  純字串組裝、可快照測試；協調（分批、寫檔、進度）在 app 層的 UITranslator。
//
//  來源是**內建英文**而不是繁中：模型對英→X 的品質普遍高於繁中→X。繁中 key 一起
//  附在 prompt 裡當第二參考。詞彙表與 README 的用語同源，人翻的英文與機翻的其他語言
//  要對得上同一組術語。
//
//  **「不要用工具」那條規則是必要的，不是禮貌話**：這些 CLI 都是 coding agent，
//  headless 模式下無法互動式詢問權限，模型一旦決定去讀檔或跑指令就會被自動拒絕，
//  然後整批**沒有輸出**（agy 實測 2026-09-02：不加這條 4 次有 3 次這樣死，加了 4/4 成功）。

import Foundation

/// 一條待翻的介面字串。`key` 是繁中原文（catalog key），`english` 是內建英文。
public struct UITranslationItem: Sendable, Equatable {
    public var id: Int
    public var key: String
    public var english: String?
    /// 複數形（`one`／`other` → 英文）。有就要求模型回複數物件。
    public var plural: [String: String]?

    public init(id: Int, key: String, english: String? = nil, plural: [String: String]? = nil) {
        self.id = id
        self.key = key
        self.english = english
        self.plural = plural
    }
}

/// 模型回的一批翻譯。缺欄位當空、多欄位忽略——一批裡壞一條不該讓整批作廢。
public struct UITranslationBatch: Decodable, Sendable, Equatable {
    public struct Entry: Decodable, Sendable, Equatable {
        public var id: Int
        public var text: String?
        public var plural: [String: String]?

        public init(id: Int, text: String? = nil, plural: [String: String]? = nil) {
            self.id = id
            self.text = text
            self.plural = plural
        }
    }

    public var translations: [Entry]

    public init(translations: [Entry]) {
        self.translations = translations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        translations = try container.decodeIfPresent([Entry].self, forKey: .translations) ?? []
    }

    private enum CodingKeys: String, CodingKey { case translations }
}

public enum UITranslationPrompt {
    /// 產品詞彙表：原文 → 建議譯法／說明。給模型看，不翻詞彙表本身。
    public static let glossary: [(term: String, meaning: String)] = [
        ("Foldwall", "product name, never translate"),
        ("蒙太奇 / montage", "a random collage composed from several images; one is generated per display"),
        ("桌布 / wallpaper", "the desktop wallpaper; use the target OS's official word for System Settings → Wallpaper"),
        ("影片桌布 / video wallpaper", "playing a video as the wallpaper"),
        ("來源 / source", "anything that feeds images or videos: a folder, a Photos album, a web source, a playlist"),
        ("網路來源 / web source", "Unsplash, Pexels, Pixabay, Wallhaven, Flickr, Immich, RSS, 4KWallpapers"),
        ("片單 / playlist", "a URL that stands for a batch of videos, fetched with yt-dlp"),
        ("照片相簿 / Photos album", "an album in Apple's Photos app"),
        ("資料夾 / folder", "a local, SMB or File Provider folder"),
        ("快取 / cache", "downloaded or copied files Foldwall keeps on disk"),
        ("後製 / post-processing", "an effect applied to the finished montage: grayscale, sepia, desaturate"),
        ("切換間隔 / interval", "how often the wallpaper changes"),
        ("張數上限 / piece limit", "maximum number of images in one montage"),
        ("顯示來源與作者 / show credits", "printing the source and author in a corner of the montage"),
        ("狀態規則 / status rules", "rules that adjust sources by battery state or Focus mode"),
        ("專注模式 / Focus", "macOS Focus; use the target OS's official name"),
        ("桌面視窗 / desktop window", "the video engine that plays in a window behind the desktop icons"),
        ("系統桌布 extension / system wallpaper extension", "the sandboxed extension that plays videos, also on the lock screen"),
        ("鎖屏 / lock screen", "the macOS lock screen"),
        ("引擎 / engine", "which pipeline plays video (desktop window vs. system extension), or which AI CLI translates"),
        ("彙整資料夾 / aggregate folder", "a folder of hard links under ~/Pictures/Foldwall for the screen saver"),
        ("螢幕保護程式 / Screen Saver", "use the target OS's official name"),
        ("備份 / backup", "settings backup through iCloud Drive"),
        ("登入時啟動 / Launch at login", "use the target OS's official wording"),
        ("選單列 / menu bar", "the macOS menu bar"),
        ("系統設定 / System Settings", "use the target OS's official name"),
        ("隱私權與安全性 / Privacy & Security", "use the target OS's official name"),
        ("介面語言 / interface language", "the language of Foldwall's own UI"),
        ("AI 引擎 / AI engine", "an external AI CLI such as Claude Code that runs on this Mac"),
    ]

    /// 給 `--json-schema` 類引擎的輸出 schema；與 `UITranslationBatch` 同形。
    public static let schemaJSON = """
    {
      "type": "object",
      "properties": {
        "translations": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "id": { "type": "integer" },
              "text": { "type": "string" },
              "plural": {
                "type": "object",
                "additionalProperties": { "type": "string" }
              }
            },
            "required": ["id"]
          }
        }
      },
      "required": ["translations"]
    }
    """

    /// 一批字串的完整 prompt。`targetLanguage` 用英文語言名（"Japanese"）。
    public static func prompt(items: [UITranslationItem], targetLanguage: String) -> String {
        let glossaryLines = glossary.map { "- \($0.term): \($0.meaning)" }.joined(separator: "\n")
        return """
        You are localizing the user interface of Foldwall, a macOS menu bar app that composes random \
        photo montages as the desktop wallpaper from folders, Photos albums and web sources, and can \
        play videos as the wallpaper. Translate every item into \(targetLanguage).

        Each item has "en" (the English UI text, your primary source) and "zh_Hant" (the original \
        Traditional Chinese, a second reference when the English is ambiguous). Items with "plural_en" \
        are count-based strings: return a "plural" object with the CLDR plural categories \
        \(targetLanguage) needs (at least "other"; add "one", "two", "few", "many", "zero" only when \
        the language distinguishes them).

        Glossary:
        \(glossaryLines)

        Rules:
        - Follow Apple's macOS Human Interface Guidelines conventions for \(targetLanguage): use the \
        official \(targetLanguage) names of macOS features and System Settings panes.
        - Keep it compact: the menu bar popover and the settings window are narrow. Short labels must \
        stay short; never add words that are not in the source.
        - Keep every format specifier exactly (%@, %lld, %d, %02d, %1$@ …), same count and same type. \
        If word order requires reordering arguments, switch ALL specifiers in that string to \
        positional form (%1$@, %2$lld). "%%" is a literal percent sign; keep it.
        - Some strings contain Markdown: keep **bold** markers and `code spans` around the same words, \
        and keep the text inside code spans untranslated.
        - Keep untranslated: Foldwall, macOS, iCloud Drive, Homebrew, brew, yt-dlp, ffmpeg, SMB, \
        HEIC, JPEG, Unsplash, Pexels, Pixabay, Wallhaven, Flickr, Immich, RSS, 4KWallpapers, \
        Phosphene, MIT, GitHub, CLI, engine names, file paths, URLs, and anything that looks like an \
        identifier or a command.
        - Preserve arrows (→), leading markers such as ▲ and ⓘ, and line breaks.
        - Never leave anything in English or Chinese unless the rule above says to keep it.
        - Everything you need is in this prompt. Do not use any tools: do not read or write files, \
        do not run commands, do not search. Answer directly.

        Input:
        \(inputJSON(items))

        \(CLIExecution.outputInstruction)
        \(schemaJSON)
        """
    }

    /// 輸入 JSON：順序固定、不逃逸非 ASCII（模型看原文比看 \\u 序列準）。
    static func inputJSON(_ items: [UITranslationItem]) -> String {
        var lines: [String] = ["["]
        for (index, item) in items.enumerated() {
            var fields = ["\"id\": \(item.id)", "\"zh_Hant\": \(quote(item.key))"]
            if let english = item.english { fields.append("\"en\": \(quote(english))") }
            if let plural = item.plural {
                let forms = plural.keys.sorted().map { "\(quote($0)): \(quote(plural[$0]!))" }
                fields.append("\"plural_en\": {\(forms.joined(separator: ", "))}")
            }
            lines.append("  {\(fields.joined(separator: ", "))}\(index == items.count - 1 ? "" : ",")")
        }
        lines.append("]")
        return lines.joined(separator: "\n")
    }

    private static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// 翻譯結果的最低防線：format specifier 數量與型別要跟來源一致，否則執行期
/// `String(format:)` 會讀錯參數甚至崩潰；不合格的直接丟掉、退回內建英文。
public enum UITranslationValidator {
    /// `%@`、`%lld`、`%1$@`… 去掉位置編號後排序，供多重集合比對。
    /// 不接受空白旗標（"100% passes" 不是 specifier），`%%` 不算。
    public static func normalizedSpecifiers(_ text: String) -> [String] {
        var result: [String] = []
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "%" else { i += 1; continue }
            var j = i + 1
            if j < scalars.count, scalars[j] == "%" { i = j + 1; continue }
            // 位置編號 n$
            var k = j
            while k < scalars.count, ("0"..."9").contains(scalars[k]) { k += 1 }
            if k < scalars.count, scalars[k] == "$", k > j { j = k + 1 }
            // 旗標與寬度／精度
            while j < scalars.count, "-+0#".unicodeScalars.contains(scalars[j]) { j += 1 }
            while j < scalars.count, ("0"..."9").contains(scalars[j]) || scalars[j] == "." { j += 1 }
            // 長度修飾
            for modifier in ["ll", "hh", "l", "h", "q", "z", "t", "j"] {
                let m = Array(modifier.unicodeScalars)
                if j + m.count <= scalars.count, Array(scalars[j..<(j + m.count)]) == m {
                    j += m.count
                    break
                }
            }
            guard j < scalars.count, "@diufsxXeEgGcaAp".unicodeScalars.contains(scalars[j]) else {
                i += 1
                continue
            }
            var spec = "%"
            spec.unicodeScalars.append(contentsOf: scalars[(i + 1)...j])
            // 去掉位置編號：%1$@ → %@
            if let dollar = spec.firstIndex(of: "$") {
                spec = "%" + spec[spec.index(after: dollar)...]
            }
            result.append(spec)
            i = j + 1
        }
        return result.sorted()
    }

    /// 單一字串是否可接受：非空、specifier 一致。
    public static func isAcceptable(candidate: String, source: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return normalizedSpecifiers(candidate) == normalizedSpecifiers(source)
    }
}

// MARK: - 批次執行

/// 一批字串 → 引擎 → 回覆。抽成 protocol 讓測試不用 spawn 真的 CLI。
public protocol UITranslationBatchRunning: Sendable {
    func translate(_ items: [UITranslationItem], targetLanguage: String) async throws -> UITranslationBatch
}

/// 批量策略：起手固定、之後依實測速率調整。純函式，`UITranslator` 照它決定每批送幾條。
///
/// 引擎之間差到兩個數量級（Chorus 2026-09-04 實測：claude 每條 0.2 秒、agy 1.1 秒、
/// grok **12 秒**），寫死任何一個數字都會有人受害——對 grok 來說 40 條一批必定撞逾時，
/// 對 claude 來說 40 條又白白多送十幾次。所以只有起手是固定的。
public enum UITranslationBatchPolicy {
    /// 起始探測量：先用小批量量一下這個引擎多快，再依實測速率決定之後送幾條。
    public static let probeBatchSize = 10
    public static let minBatchSize = 5
    public static let maxBatchSize = 120
    /// 目標批量＝在「逾時 × 這個比例」內回得完；餘裕留給引擎抖動與併發互相拖慢。
    public static let batchTimeBudget = 0.35
    /// 一次最多放大幾倍：一個特別快的樣本不該把批量一口氣拉到上限。
    public static let batchGrowthFactor = 4
    /// 同一條字串被模型漏掉時最多重送幾次，之後就退回英文。
    public static let maxItemAttempts = 2
    /// 整批硬失敗（逾時、decode 壞掉）幾次之後收手。降批量重送救得回截斷，
    /// 救不回卡死的引擎——不設上限就會一直重試下去。
    public static let maxBatchFailures = 2
    /// 同時在跑的批數。批與批之間互不相干（各是一次獨立的 CLI 呼叫），循序送
    /// 十幾批要半小時，開併發把牆鐘時間壓下來。
    public static let maxConcurrentBatches = 4

    /// 一批的預算秒數（與子行程逾時同源）。
    public static var batchBudgetSeconds: TimeInterval {
        Double(CLIUITranslationBatchRunner.defaultTimeout.components.seconds) * batchTimeBudget
    }

    /// 依上一批的實測速率算下一批送幾條。`ceiling` 是截斷或失敗之後壓下來的上限——
    /// 被截斷過就不該再長回去，否則會在「放大→截斷→砍半」之間震盪。
    public static func nextBatchSize(
        previous: Int, elapsed: TimeInterval, budget: TimeInterval, ceiling: Int
    ) -> Int {
        guard previous > 0, elapsed > 0 else { return max(minBatchSize, min(previous, ceiling)) }
        let perItem = elapsed / Double(previous)
        let target = Int(budget / perItem)
        return max(minBatchSize, min(ceiling, min(target, previous * batchGrowthFactor)))
    }
}

/// 正式版：走 `CLIExecution`（重試、錯誤映射、環境白名單同一份）。
public struct CLIUITranslationBatchRunner: UITranslationBatchRunning {
    public let engine: KnownCLIEngine
    public let executable: URL
    public var model: String?
    /// 一批對慢的模型可能要好幾分鐘。批量的目標秒數也是從這裡推的
    /// （`UITranslationBatchPolicy.batchBudgetSeconds`）。
    public static let defaultTimeout: Duration = .seconds(300)
    public var timeout: Duration = CLIUITranslationBatchRunner.defaultTimeout

    public init(engine: KnownCLIEngine, executable: URL, model: String? = nil) {
        self.engine = engine
        self.executable = executable
        self.model = model
    }

    public func translate(_ items: [UITranslationItem], targetLanguage: String) async throws -> UITranslationBatch {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("foldwall-translate-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let run = KnownCLIEngine.RunContext(
            sandbox: sandbox,
            schemaFile: CLIExecution.writeSchema(UITranslationPrompt.schemaJSON, into: sandbox),
            model: engine.supportsModelSelection ? model : nil,
            timeout: timeout)
        return try await CLIExecution.perform(
            engine: engine, executable: executable,
            basePrompt: UITranslationPrompt.prompt(items: items, targetLanguage: targetLanguage),
            run: run, as: UITranslationBatch.self)
    }
}
