//  MediaTypes.swift
//  介面名由 HANDOFF 鎖定，不要改。

import Foundation

public enum MediaKind: Sendable, Equatable {
    case image
    case video
}

public struct IndexedItem: Equatable, Sendable {
    public var url: URL
    public var kind: MediaKind

    public init(url: URL, kind: MediaKind) {
        self.url = url
        self.kind = kind
    }
}

public enum PostProcess: String, CaseIterable, Sendable {
    case none, grayscale, sepia, desaturate, random

    /// 去飽和固定比例：v1 無設定項。
    public static let desaturationFactor: Double = 0.4

    /// 選單與設定視窗共用。
    public var displayName: String {
        switch self {
        case .none: "無"
        case .grayscale: "灰階"
        case .sepia: "棕褐"
        case .desaturate: "去飽和"
        case .random: "隨機"
        }
    }

    /// `random` 解析成一個具體效果（含 `none`），用傳入 RNG 以便測試穩定。
    public func resolved(using rng: inout some RandomNumberGenerator) -> PostProcess {
        guard self == .random else { return self }
        let concrete: [PostProcess] = [.none, .grayscale, .sepia, .desaturate]
        return concrete.randomElement(using: &rng) ?? .none
    }
}

public struct MontageRecipe: Sendable, Equatable {
    /// 合法範圍見 `MontageComposer.pieceCountRange`，超出由 Composer clamp。
    public var pieceCount: Int
    public var seed: UInt64
    /// 要不要把來源與作者印上去。
    ///
    /// **關掉是使用者的選擇，不是預設。** Unsplash 與 Pexels 的授權都要求標註作者，
    /// 所以預設開；關掉之後那些來源就只剩使用者自己看得到，責任在使用者身上。
    public var showCredits: Bool

    public init(pieceCount: Int, seed: UInt64, showCredits: Bool = true) {
        self.pieceCount = pieceCount
        self.seed = seed
        self.showCredits = showCredits
    }
}

public enum PowerTier: Sendable, Equatable {
    case full, reduced, paused
}
