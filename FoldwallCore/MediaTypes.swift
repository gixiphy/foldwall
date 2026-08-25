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

    /// `random` 解析成一個具體效果（含 `none`），用傳入 RNG 以便測試穩定。
    public func resolved(using rng: inout some RandomNumberGenerator) -> PostProcess {
        guard self == .random else { return self }
        let concrete: [PostProcess] = [.none, .grayscale, .sepia, .desaturate]
        return concrete.randomElement(using: &rng) ?? .none
    }
}

public struct MontageRecipe: Sendable, Equatable {
    /// 合法範圍 4...12，超出由 Composer clamp。
    public var pieceCount: Int
    public var seed: UInt64

    public init(pieceCount: Int, seed: UInt64) {
        self.pieceCount = pieceCount
        self.seed = seed
    }
}

public enum PowerTier: Sendable, Equatable {
    case full, reduced, paused
}
