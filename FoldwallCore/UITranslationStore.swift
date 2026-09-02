//  UITranslationStore.swift
//  使用者用本機 AI CLI 翻出來的介面語言：落地格式與執行期覆蓋。
//
//  Foldwall 內建繁中、簡中與英文。系統語言不在這三種時，使用者可以在設定 → 介面語言
//  讓本機的 CLI 把全部介面文字翻成他的語言。翻好的檔存在這台 Mac 上，重啟後生效；
//  升版多出來的字串可以「補翻」，未翻的自動退回英文。
//
//  一個語言一個**真的 bundle**：`<dir>/<lang>.bundle/Contents/Resources/<lang>.lproj/`
//  底下放 `Localizable.strings` 與 `.stringsdict`，複數形交給 Foundation 解析，
//  我們不自己實作 CLDR 規則。旁邊一份 `<lang>.json` manifest 記錄來源 build、引擎與條數。
//
//  Foldwall 的字串表有兩份（app 與 FoldwallCore），key 都是繁中原文、彼此不衝突，
//  所以翻譯 bundle 只有一份、兩個 bundle 都覆蓋到同一個 overlay。

import Foundation
import ObjectiveC

public final class UITranslationStore: Sendable {
    /// App 內建的語言；系統語言在這裡面就不需要自翻。
    public static let builtinLanguages = ["zh-Hant", "zh-Hans", "en"]

    public struct Manifest: Codable, Equatable, Sendable {
        public var language: String
        public var engineID: String
        public var model: String?
        public var date: Date
        /// 翻譯時 App 的 CFBundleVersion；升版後用來提示「有新字串」。
        public var sourceBuild: String
        public var translated: Int
        /// 模型沒翻好（specifier 不符、空白）而退回英文的 key。
        public var skipped: [String]

        public init(language: String, engineID: String, model: String?, date: Date,
                    sourceBuild: String, translated: Int, skipped: [String]) {
            self.language = language
            self.engineID = engineID
            self.model = model
            self.date = date
            self.sourceBuild = sourceBuild
            self.translated = translated
            self.skipped = skipped
        }
    }

    /// 內建的翻譯來源：英文字串與英文複數形（key 都是繁中原文）。
    public struct BuiltinSource: Sendable {
        public var strings: [String: String] = [:]
        public var plurals: [String: [String: String]] = [:]
        /// 複數形的 `NSStringFormatValueTypeKey`（幾乎都是 lld），寫回 stringsdict 要原樣帶。
        public var pluralValueTypes: [String: String] = [:]

        public init() {}
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: - 路徑

    public func bundleURL(for language: String) -> URL {
        directory.appendingPathComponent("\(language).bundle", isDirectory: true)
    }

    public func manifestURL(for language: String) -> URL {
        directory.appendingPathComponent("\(language).json")
    }

    private func lprojURL(for language: String) -> URL {
        bundleURL(for: language).appendingPathComponent("Contents/Resources/\(language).lproj", isDirectory: true)
    }

    // MARK: - 讀

    public func manifest(for language: String) -> Manifest? {
        guard let data = try? Data(contentsOf: manifestURL(for: language)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Manifest.self, from: data)
    }

    /// 已安裝翻譯的語言清單（有 manifest 又有 bundle 的）。
    public func installedLanguages() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.compactMap { name -> String? in
            guard name.hasSuffix(".json") else { return nil }
            let language = String(name.dropLast(5))
            return FileManager.default.fileExists(atPath: bundleURL(for: language).path) ? language : nil
        }.sorted()
    }

    /// 已翻好的字串（補翻時只送缺的）。
    public func existingTranslations(for language: String) -> (strings: [String: String], plurals: [String: [String: String]]) {
        let lproj = lprojURL(for: language)
        let strings = NSDictionary(contentsOf: lproj.appendingPathComponent("Localizable.strings"))
            as? [String: String] ?? [:]
        var plurals: [String: [String: String]] = [:]
        if let dict = NSDictionary(contentsOf: lproj.appendingPathComponent("Localizable.stringsdict")) as? [String: Any] {
            for (key, value) in dict {
                if let forms = Self.pluralForms(from: value) { plurals[key] = forms.forms }
            }
        }
        return (strings, plurals)
    }

    /// 內建英文：唯一的翻譯來源。把每個 bundle 的 en.lproj 併成一份；
    /// 讀不到（理論上不會）就回空。
    public static func builtinSource(bundles: [Bundle]) -> BuiltinSource {
        var source = BuiltinSource()
        for bundle in bundles {
            if let url = bundle.url(forResource: "Localizable", withExtension: "strings",
                                    subdirectory: nil, localization: "en"),
               let dict = NSDictionary(contentsOf: url) as? [String: String] {
                source.strings.merge(dict, uniquingKeysWith: { first, _ in first })
            }
            if let url = bundle.url(forResource: "Localizable", withExtension: "stringsdict",
                                    subdirectory: nil, localization: "en"),
               let dict = NSDictionary(contentsOf: url) as? [String: Any] {
                for (key, value) in dict where source.plurals[key] == nil {
                    if let parsed = pluralForms(from: value) {
                        source.plurals[key] = parsed.forms
                        source.pluralValueTypes[key] = parsed.valueType
                    }
                }
            }
        }
        return source
    }

    /// stringsdict 一條的形狀：`{NSStringLocalizedFormatKey: "%#@value@", value: {…, one:, other:}}`。
    private static func pluralForms(from value: Any) -> (forms: [String: String], valueType: String)? {
        guard let entry = value as? [String: Any],
              let variable = entry["value"] as? [String: Any]
        else { return nil }
        var forms: [String: String] = [:]
        for (form, text) in variable where !form.hasPrefix("NSStringFormat") {
            if let text = text as? String { forms[form] = text }
        }
        guard !forms.isEmpty else { return nil }
        return (forms, variable["NSStringFormatValueTypeKey"] as? String ?? "lld")
    }

    // MARK: - 寫

    /// 整包覆寫：呼叫端先合併舊譯文再交進來。原子性靠先寫暫存目錄再換名。
    public func write(
        language: String,
        strings: [String: String],
        plurals: [String: [String: String]],
        pluralValueTypes: [String: String],
        manifest: Manifest
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".\(language).bundle.tmp", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        let lproj = staging.appendingPathComponent("Contents/Resources/\(language).lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)

        // Info.plist：CFBundleDevelopmentRegion 設成目標語言，Bundle 找不到與使用者偏好
        // 相交的語言時會退到這裡——這個 bundle 只有一種語言，一定要退得到。
        let info: [String: Any] = [
            "CFBundleDevelopmentRegion": language,
            "CFBundleIdentifier": "app.foldwall.UITranslation.\(language)",
            "CFBundleName": "Foldwall UI Translation (\(language))",
            "CFBundlePackageType": "BNDL",
            "CFBundleInfoDictionaryVersion": "6.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: staging.appendingPathComponent("Contents/Info.plist"))

        try PropertyListSerialization.data(fromPropertyList: strings, format: .xml, options: 0)
            .write(to: lproj.appendingPathComponent("Localizable.strings"))

        if !plurals.isEmpty {
            var dict: [String: Any] = [:]
            for (key, forms) in plurals {
                var variable: [String: Any] = [
                    "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                    "NSStringFormatValueTypeKey": pluralValueTypes[key] ?? "lld",
                ]
                for (form, text) in forms { variable[form] = text }
                dict[key] = ["NSStringLocalizedFormatKey": "%#@value@", "value": variable]
            }
            try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
                .write(to: lproj.appendingPathComponent("Localizable.stringsdict"))
        }

        let target = bundleURL(for: language)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: staging, to: target)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL(for: language), options: .atomic)
    }

    public func remove(language: String) throws {
        for url in [bundleURL(for: language), manifestURL(for: language)]
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 執行期覆蓋

    /// 啟動時裝上覆蓋：把每個 bundle 的 class 換成 `TranslatedBundle`，之後所有
    /// `localizedString(forKey:)`（SwiftUI `Text`、`String(localized:)`）先查翻譯 bundle。
    /// **任何 View 建立前呼叫一次**；回傳是否真的裝上了。
    @discardableResult
    public func installOverride(language: String, bundles: [Bundle]) -> Bool {
        guard let overlay = Bundle(url: bundleURL(for: language)),
              manifest(for: language) != nil
        else { return false }
        TranslatedBundle.overlay = overlay
        TranslatedBundle.language = language
        for bundle in bundles {
            object_setClass(bundle, TranslatedBundle.self)
        }
        return true
    }
}

/// `Bundle.main`／`Bundle.foldwallCore` 的替身 class：只覆寫字串查表。查不到的 key
/// 用 sentinel 偵測後交回原本的邏輯（內建 en／zh-Hant／zh-Hans），所以升版新增、
/// 尚未補翻的字串顯示英文，不會變成 key 本身。
///
/// **為什麼不只覆寫 `localizedString(forKey:value:table:)`**：macOS 26 上
/// `String(localized:)`（也就是 SwiftUI `Text` 與 FoldwallCore 全部走的那條）不經公開
/// 方法，而是 `-_localizedStringForKey:value:table:localizations:`（Chorus 2026-09-02
/// 以獨立程式逐一探測）。所以這裡把 NSBundle 上每一個字串查表入口都接住；私有 selector
/// 的原實作用 IMP 呼叫。哪天 Foundation 改名，症狀只是覆蓋失效、退回英文，不會崩。
public final class TranslatedBundle: Bundle, @unchecked Sendable {
    /// 啟動時設一次、之後只讀；Bundle 會從任何執行緒被叫到。
    nonisolated(unsafe) public static var overlay: Bundle?
    nonisolated(unsafe) public static var language: String?

    /// 目前生效的覆蓋語言（nil＝沒有裝）。設定頁靠它判斷「已翻好但要重啟」。
    public static var activeLanguage: String? {
        object_getClass(Bundle.main) == TranslatedBundle.self ? language : nil
    }

    private static let missing = "\u{1}foldwall.missing\u{1}"

    /// 純函式的核心，方便單獨測：overlay 有這個 key 就回譯文，沒有回 nil。
    /// `value:` 非空時 Bundle 找不到會原樣回傳它——拿一個不可能撞到的 sentinel 當探針。
    public static func resolve(key: String, table: String?, overlay: Bundle?) -> String? {
        guard let overlay else { return nil }
        let result = overlay.localizedString(forKey: key, value: missing, table: table)
        return result == missing ? nil : result
    }

    // MARK: 公開入口（NSLocalizedString、AppKit）

    override public func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        Self.resolve(key: key, table: tableName, overlay: Self.overlay)
            ?? super.localizedString(forKey: key, value: value, table: tableName)
    }

    override public func __localizedString(forKey key: String, value: String?, table tableName: String?, localizations: [String]) -> String {
        Self.resolve(key: key, table: tableName, overlay: Self.overlay)
            ?? super.__localizedString(forKey: key, value: value, table: tableName, localizations: localizations)
    }

    override public func __localizedAttributedString(forKey key: String, value: String?, table tableName: String?) -> NSAttributedString {
        if let translated = Self.resolve(key: key, table: tableName, overlay: Self.overlay) {
            return NSAttributedString(string: translated)
        }
        return super.__localizedAttributedString(forKey: key, value: value, table: tableName)
    }

    // MARK: Swift Foundation 實際走的入口（私有 selector）

    private typealias StringLookupIMP = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?, AnyObject?) -> NSString
    private typealias AttributedLookupIMP = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?, AnyObject?) -> NSAttributedString

    private func superString(_ selector: Selector, _ key: String, _ value: String?, _ table: String?, _ extra: AnyObject?) -> String {
        guard let imp = class_getMethodImplementation(Bundle.self, selector) else { return value ?? key }
        let call = unsafeBitCast(imp, to: StringLookupIMP.self)
        return call(self, selector, key as NSString, value as NSString?, table as NSString?, extra) as String
    }

    /// `String(localized:)`／`LocalizedStringResource`：最後一個參數是 localizations 陣列。
    @objc(_localizedStringForKey:value:table:localizations:)
    public func foldwallLocalizedString(forKey key: String, value: String?, table: String?, localizations: [String]?) -> String {
        Self.resolve(key: key, table: table, overlay: Self.overlay)
            ?? superString(#selector(foldwallLocalizedString(forKey:value:table:localizations:)), key, value, table, localizations as NSArray?)
    }

    /// SwiftUI 帶 environment locale 的查表：最後一個參數是單一 localization。
    @objc(localizedStringForKey:value:table:localization:)
    public func foldwallLocalizedString(forKey key: String, value: String?, table: String?, localization: String?) -> String {
        Self.resolve(key: key, table: table, overlay: Self.overlay)
            ?? superString(#selector(foldwallLocalizedString(forKey:value:table:localization:)), key, value, table, localization as NSString?)
    }

    @objc(localizedAttributedStringForKey:value:table:localization:)
    public func foldwallLocalizedAttributedString(forKey key: String, value: String?, table: String?, localization: String?) -> NSAttributedString {
        if let translated = Self.resolve(key: key, table: table, overlay: Self.overlay) {
            return NSAttributedString(string: translated)
        }
        let selector = #selector(foldwallLocalizedAttributedString(forKey:value:table:localization:))
        guard let imp = class_getMethodImplementation(Bundle.self, selector) else {
            return NSAttributedString(string: value ?? key)
        }
        let call = unsafeBitCast(imp, to: AttributedLookupIMP.self)
        return call(self, selector, key as NSString, value as NSString?, table as NSString?, localization as NSString?)
    }
}
