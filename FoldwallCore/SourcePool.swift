//  SourcePool.swift
//  抽圖時**依來源分組**，而不是把整池攤平。
//
//  為什麼：攤平之後張數決定一切。實測使用者的池是資料夾 693,210 張、
//  網路快取 538 張、相簿 603 張——隨機抽 10 張，抽到非資料夾來源的機率是 0.16%。
//  「有加網路來源」在畫面上等於看不出來，一張蒙太奇十片全來自同一個資料夾。
//
//  改成輪流：先讓每個來源各出一張，出完一輪再從頭。10 張配 3 個來源就是 4/3/3。
//  同一個 seed 仍然可重現——輪的順序也是 seed 決定的。

import Foundation

public struct SourcePool: Sendable, Equatable {

    public struct Group: Sendable, Equatable {
        /// 診斷與記錄用，不參與抽樣。
        public var id: String
        /// **路徑字串，不是 URL。** 資料夾那組實測 69 萬項，存 URL 比存路徑
        /// 多花一倍以上的記憶體，而其中只有十幾項會真的被抽中組成 URL。
        public var paths: [String]

        public init(id: String, paths: [String]) {
            self.id = id
            self.paths = paths
        }

        /// 幾百項的小來源（相簿、網路快取）直接給 URL 也行。
        public init(id: String, urls: [URL]) {
            self.init(id: id, paths: urls.map { $0.path(percentEncoded: false) })
        }
    }

    /// 只保留非空的組：空的組在輪替時只會被一直跳過。
    public private(set) var groups: [Group]

    public init(groups: [Group]) {
        self.groups = groups.filter { !$0.paths.isEmpty }
    }

    /// 單一來源。測試與「沒有分組資訊」的呼叫端用。
    public init(_ urls: [URL], id: String = "all") {
        self.init(groups: [Group(id: id, urls: urls)])
    }

    public var isEmpty: Bool { groups.isEmpty }
    public var count: Int { groups.reduce(0) { $0 + $1.paths.count } }
    public var all: [URL] { groups.flatMap(\.paths).map(Self.url) }

    /// 路徑 → URL。抽中才呼叫。
    static func url(_ path: String) -> URL {
        URL(filePath: path, directoryHint: .notDirectory)
    }

    /// 把一堆檔案依所屬根目錄拆成多組。**不屬於任何一個根目錄的直接丟掉**，
    /// 所以這個函式同時兼任「只留這些根目錄底下的檔案」的過濾工作——
    /// 呼叫端不必先 filter 一次再 group 一次，那是走兩趟幾十萬筆。
    ///
    /// **走過大量檔案時請在背景執行緒呼叫。**
    public static func groupByRoot(_ paths: [String], roots: [URL]) -> [Group] {
        guard !roots.isEmpty, !paths.isEmpty else { return [] }
        // 單一根目錄：所有檔案都屬於它，不必逐一比對（最常見的情況）
        guard roots.count > 1 else {
            return [Group(id: roots[0].lastPathComponent, paths: paths)]
        }

        let matcher = RootMatcher(roots)
        var byRoot: [String: [String]] = [:]
        for path in paths {
            guard let root = matcher.root(ofPath: path) else { continue }
            byRoot[root.path(percentEncoded: false), default: []].append(path)
        }
        // 固定順序：跟 roots 一致，讓同一 seed 的結果可重現
        return roots.compactMap { root in
            guard let paths = byRoot[root.path(percentEncoded: false)], !paths.isEmpty
            else { return nil }
            return Group(id: root.lastPathComponent, paths: paths)
        }
    }
}

/// 依序輪流從各來源抽。
///
/// 每次 `next()` 換下一組，組內用 seed 隨機挑一張。組的順序也用 seed 洗過，
/// 所以不是每輪都固定從同一個來源開頭——否則第一片永遠來自同一個資料夾。
public struct SourceRotation {

    /// 組內的無放回抽樣。
    ///
    /// 用**稀疏 Fisher-Yates**：只走要用到的那幾步，被換過的位置記在字典裡。
    /// 不能真的洗一次陣列——資料夾那組實測有 69 萬筆，每張蒙太奇洗一次
    /// 是幾 MB 的配置換來十幾個結果。
    ///
    /// 也不能用「隨機抽＋撞到重複就重試」：3 張的池抽 6 次仍有 9% 機率抽不齊，
    /// 小來源會被無聲地少算。這是實作第一版時測試抓到的。
    private struct Draw {
        let total: Int
        private var taken = 0
        private var swapped: [Int: Int] = [:]

        init(total: Int) { self.total = total }

        mutating func next(using rng: inout SeededGenerator) -> Int? {
            guard taken < total else { return nil }
            let pick = Int.random(in: taken..<total, using: &rng)
            let value = swapped[pick] ?? pick
            swapped[pick] = swapped[taken] ?? taken
            taken += 1
            return value
        }
    }

    private let groups: [SourcePool.Group]
    private var draws: [Draw]
    private var rng: SeededGenerator
    private var cursor = 0
    /// 跨組重複的保險：同一個檔案理論上不會同時屬於兩個來源，但真的發生時
    /// 也不該讓它在同一張圖裡出現兩次。
    private var used: Set<String> = []

    public init(pool: SourcePool, seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        let shuffled = pool.groups.shuffled(using: &rng)
        self.groups = shuffled
        self.draws = shuffled.map { Draw(total: $0.paths.count) }
        self.rng = rng
    }

    /// 下一個候選。**同一張蒙太奇裡不會給重複的**——所有來源都抽完才回 nil。
    ///
    /// 抽到壞檔由呼叫端跳過並再要一個——那自然會落到**下一個來源**，
    /// 所以一個離線的資料夾不會把整張圖的名額吃光。
    public mutating func next() -> URL? {
        guard !groups.isEmpty else { return nil }
        // 連續幾組都空了就是真的抽完。每一圈不是消耗掉一個名額、就是讓
        // 計數加一，名額有限所以一定會停。
        var consecutiveEmpty = 0
        while consecutiveEmpty < groups.count {
            let index = cursor % groups.count
            cursor += 1
            guard let pick = draws[index].next(using: &rng) else {
                consecutiveEmpty += 1
                continue
            }
            consecutiveEmpty = 0
            // 抽中的才組 URL：池裡是路徑字串，一輪只會走到十幾項。
            let path = groups[index].paths[pick]
            if used.insert(path).inserted { return SourcePool.url(path) }
        }
        return nil
    }
}
