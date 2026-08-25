//  SeededGenerator.swift
//  SplitMix64：同 seed 同序列，蒙太奇才能重現、測試才穩。

import Foundation

public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension SeededGenerator {
    /// 每螢一顆 seed：同一輪不同螢幕構圖不同，且可重現。
    public static func seed(cycleNonce: UInt64, displayUUID: String) -> UInt64 {
        var hash: UInt64 = cycleNonce &* 0x100_0000_01B3
        for byte in displayUUID.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        return hash
    }
}
