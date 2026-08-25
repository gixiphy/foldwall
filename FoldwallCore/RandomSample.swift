//  RandomSample.swift
//  從一個很大的集合裡隨機抽少數幾個。
//
//  為什麼需要這個：直覺寫法是 `Array(0..<count).shuffled().prefix(k)`，
//  但那要先配置 count 個元素再整個洗牌——實測使用者的照片相簿有 101,046 張，
//  為了抽 3 張而配置並洗牌十萬個 Int，每次補貨都來一次。
//  這裡是 O(k)，跟集合大小無關。

import Foundation

public enum RandomSample {

    /// 從 `0..<total` 裡抽最多 `count` 個**不重複**的索引。
    ///
    /// - Parameter rng: 傳入以便測試可重現。
    public static func indices(
        count: Int, total: Int, using rng: inout some RandomNumberGenerator
    ) -> [Int] {
        guard total > 0, count > 0 else { return [] }
        let wanted = min(count, total)

        // 要的比例很高時，隨機重試會一直撞號 → 那種情況才用洗牌法。
        // 門檻取一半：k > total/2 時洗牌反而便宜。
        if wanted * 2 > total {
            return Array((0..<total).shuffled(using: &rng).prefix(wanted))
        }

        var chosen = Set<Int>()
        chosen.reserveCapacity(wanted)
        // 撞號上限：wanted 很小時期望嘗試次數接近 wanted，這個上限只是保險
        var attempts = 0
        let budget = wanted * 8 + 16
        while chosen.count < wanted, attempts < budget {
            attempts += 1
            chosen.insert(Int.random(in: 0..<total, using: &rng))
        }
        return Array(chosen)
    }

    /// 用系統亂數的版本。
    public static func indices(count: Int, total: Int) -> [Int] {
        var rng = SystemRandomNumberGenerator()
        return indices(count: count, total: total, using: &rng)
    }
}
