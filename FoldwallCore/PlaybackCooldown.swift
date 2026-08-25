//  PlaybackCooldown.swift
//  播不動的影片先冷卻一段時間，不要每輪都重新選中同一支。
//
//  沒有這層的話，一支壞掉的影片會每輪被重新選中、每輪都黑畫面——靜態管線有
//  `attemptsPerPiece` 的重試預算可以換掉爛蘋果，影片這條本來完全沒有對應機制。

import Foundation

/// 播不動的來源先冷卻一段時間。
///
/// 沒有這層的話，一支壞掉的串流會每輪都被重新選中、每輪都黑畫面——
/// 靜態管線有 `attemptsPerPiece` 的重試預算換掉爛蘋果，影片這條本來完全沒有對應機制。
public struct PlaybackCooldown: Sendable, Equatable {

    /// 壞掉之後冷卻多久再試。串流常常只是暫時的（CDN 抽風、網路斷一下），
    /// 所以是冷卻不是永久剔除。
    public static let duration: TimeInterval = 10 * 60

    private var failures: [String: Date] = [:]

    public init() {}

    public mutating func recordFailure(_ url: URL, now: Date) {
        failures[Self.key(url)] = now
    }

    public mutating func clear(_ url: URL) {
        failures.removeValue(forKey: Self.key(url))
    }

    public func isCoolingDown(_ url: URL, now: Date) -> Bool {
        guard let failed = failures[Self.key(url)] else { return false }
        return now.timeIntervalSince(failed) < Self.duration
    }

    /// 濾掉冷卻中的。
    ///
    /// **全部都在冷卻中就原樣放行**：一支會壞的影片也好過空池換來的黑畫面，
    /// 而且冷卻期滿本來就要重試，沒理由在這種時候讓桌布整個消失。
    public func filter(_ urls: [URL], now: Date) -> [URL] {
        let alive = urls.filter { !isCoolingDown($0, now: now) }
        return alive.isEmpty ? urls : alive
    }

    private static func key(_ url: URL) -> String { url.absoluteString }
}
