//  SourceRule.swift
//  依系統狀態調整來源：電池時別打網路、工作模式時暫停影片，諸如此類。
//
//  規則是「條件 → 效果」的扁平清單，多條同時成立就把效果聯集起來。
//  刻意不做優先序或互斥——那會需要一整套衝突解決 UI，而聯集的語意
//  （「任一條說要停，就停」）對這個用途既夠用又好預測。

import Foundation

public enum RuleCondition: Codable, Sendable, Equatable, Hashable {
    /// 靠電池（沒接電源）。
    case onBattery
    /// 指定的專注模式啟用中。空字串代表「任何專注模式」。
    case focusMode(String)

    /// 「任何專注模式」的哨兵值。
    public static let anyFocus = RuleCondition.focusMode("")

    // 手寫編碼：Swift 預設會把關聯值序列化成 `{"focusMode":{"_0":"..."}}`，
    // 那個形狀既不可讀也綁在編譯器實作上。設定要長期躺在 UserDefaults 裡，
    // 格式得是自己說得清楚的。
    private enum CodingKeys: String, CodingKey { case type, mode }
    private enum Kind: String, Codable { case onBattery, focusMode }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .onBattery:
            self = .onBattery
        case .focusMode:
            self = .focusMode(try container.decodeIfPresent(String.self, forKey: .mode) ?? "")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .onBattery:
            try container.encode(Kind.onBattery, forKey: .type)
        case .focusMode(let identifier):
            try container.encode(Kind.focusMode, forKey: .type)
            try container.encode(identifier, forKey: .mode)
        }
    }
}

public struct RuleEffect: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// 影片螢幕改回蒙太奇（不再跳過那些螢幕，也不輪替影片）。
    public static let pauseVideo       = RuleEffect(rawValue: 1 << 0)
    /// 不打網路 API、不下載。已快取的圖仍可用。
    public static let disableRemote    = RuleEffect(rawValue: 1 << 1)
    /// 不用資料夾來源（SMB／雲端在電池上很耗）。
    public static let disableFolders   = RuleEffect(rawValue: 1 << 2)
    /// 不用照片相簿。
    public static let disablePhotos    = RuleEffect(rawValue: 1 << 3)
    /// 完全停止換桌布，保留現狀。
    public static let pauseRotation    = RuleEffect(rawValue: 1 << 4)

    public static let allCases: [(effect: RuleEffect, label: String)] = [
        (.pauseVideo, "暫停影片桌布"),
        (.disableRemote, "停用網路來源"),
        (.disableFolders, "停用資料夾來源"),
        (.disablePhotos, "停用照片相簿"),
        (.pauseRotation, "完全暫停輪換"),
    ]
}

public struct SourceRule: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var condition: RuleCondition
    public var effects: RuleEffect
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        condition: RuleCondition,
        effects: RuleEffect = [],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.condition = condition
        self.effects = effects
        self.isEnabled = isEnabled
    }
}

/// 規則求值時的系統狀態快照。
public struct RuleContext: Sendable, Equatable {
    public var onBattery: Bool
    /// 目前啟用中的專注模式識別碼；沒開就是 nil。
    public var activeFocusModeID: String?

    public init(onBattery: Bool = false, activeFocusModeID: String? = nil) {
        self.onBattery = onBattery
        self.activeFocusModeID = activeFocusModeID
    }
}

public enum SourceRuleEngine {

    /// 把所有成立的規則效果聯集起來。
    public static func effects(rules: [SourceRule], context: RuleContext) -> RuleEffect {
        rules.reduce(into: RuleEffect()) { result, rule in
            guard rule.isEnabled, matches(rule.condition, context) else { return }
            result.formUnion(rule.effects)
        }
    }

    /// 哪些規則正在生效。UI 拿它標示「這條現在成立」。
    public static func activeRules(rules: [SourceRule], context: RuleContext) -> [SourceRule] {
        rules.filter { $0.isEnabled && matches($0.condition, context) }
    }

    static func matches(_ condition: RuleCondition, _ context: RuleContext) -> Bool {
        switch condition {
        case .onBattery:
            return context.onBattery
        case .focusMode(let identifier):
            guard let active = context.activeFocusModeID else { return false }
            // 空字串＝任何專注模式都算
            return identifier.isEmpty || identifier == active
        }
    }
}
