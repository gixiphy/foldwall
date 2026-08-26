import XCTest
@testable import FoldwallCore

final class SourcePoolTests: XCTestCase {

    private func urls(_ prefix: String, _ n: Int) -> [URL] {
        (0..<n).map { URL(filePath: "/\(prefix)/\($0).jpg") }
    }

    // MARK: - 分組

    func testEmptyGroupsAreDropped() {
        let pool = SourcePool(groups: [
            .init(id: "a", urls: urls("a", 3)),
            .init(id: "empty", urls: []),
        ])
        XCTAssertEqual(pool.groups.map(\.id), ["a"])
        XCTAssertEqual(pool.count, 3)
    }

    func testSingleRootTakesTheShortcut() {
        let root = URL(filePath: "/Volumes/Archive/Tablescape")
        let files = urls("Volumes/Archive/Tablescape", 5)
        let groups = SourcePool.groupByRoot(files, roots: [root])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].urls.count, 5)
        XCTAssertEqual(groups[0].id, "Tablescape")
    }

    func testMultipleRootsSplitByOwnership() {
        let a = URL(filePath: "/Volumes/A")
        let b = URL(filePath: "/Volumes/B")
        let files = urls("Volumes/A", 3) + urls("Volumes/B", 2)
        let groups = SourcePool.groupByRoot(files, roots: [a, b])
        XCTAssertEqual(groups.map(\.id), ["A", "B"], "順序跟著 roots，讓同 seed 可重現")
        XCTAssertEqual(groups.map(\.urls.count), [3, 2])
    }

    /// `/Volumes/Arch` 不該吃掉 `/Volumes/Archive`。
    func testRootMatchingRespectsPathBoundary() {
        let arch = URL(filePath: "/Volumes/Arch")
        let archive = URL(filePath: "/Volumes/Archive")
        let files = [URL(filePath: "/Volumes/Archive/x.jpg")]
        let groups = SourcePool.groupByRoot(files, roots: [arch, archive])
        XCTAssertEqual(groups.map(\.id), ["Archive"])
    }

    // MARK: - 輪流抽

    /// 這條是整件事的重點：張數懸殊時，攤平隨機抽等於只看得到大的那個來源。
    /// 實測使用者的池是 693,210 對 538，隨機抽 10 張抽到小的機率是 0.16%。
    func testRotationCoversEverySourceDespiteHugeSizeGap() {
        let pool = SourcePool(groups: [
            .init(id: "huge", urls: urls("huge", 100_000)),
            .init(id: "tiny", urls: urls("tiny", 3)),
            .init(id: "small", urls: urls("small", 12)),
        ])
        var rotation = SourceRotation(pool: pool, seed: 42)

        var seen: Set<String> = []
        for _ in 0..<9 {
            let url = try! XCTUnwrap(rotation.next())
            seen.insert(url.deletingLastPathComponent().lastPathComponent)
        }
        XCTAssertEqual(seen, ["huge", "tiny", "small"], "9 抽要涵蓋 3 個來源")
    }

    func testRotationSharesEvenly() {
        let pool = SourcePool(groups: [
            .init(id: "a", urls: urls("a", 1000)),
            .init(id: "b", urls: urls("b", 1000)),
        ])
        var rotation = SourceRotation(pool: pool, seed: 7)
        var counts: [String: Int] = [:]
        for _ in 0..<10 {
            let url = rotation.next()!
            counts[url.deletingLastPathComponent().lastPathComponent, default: 0] += 1
        }
        XCTAssertEqual(counts["a"], 5)
        XCTAssertEqual(counts["b"], 5)
    }

    /// 同一個 seed 要重現同一張蒙太奇——組的順序也是 seed 決定的。
    func testSameSeedIsReproducible() {
        let pool = SourcePool(groups: [
            .init(id: "a", urls: urls("a", 50)),
            .init(id: "b", urls: urls("b", 50)),
        ])
        var first = SourceRotation(pool: pool, seed: 99)
        var second = SourceRotation(pool: pool, seed: 99)
        for _ in 0..<12 {
            XCTAssertEqual(first.next(), second.next())
        }
    }

    /// 不同 seed 不該永遠從同一個來源開頭，否則第一片固定來自同一個資料夾。
    func testDifferentSeedsStartAtDifferentSources() {
        let pool = SourcePool(groups: [
            .init(id: "a", urls: urls("a", 50)),
            .init(id: "b", urls: urls("b", 50)),
            .init(id: "c", urls: urls("c", 50)),
        ])
        var starts: Set<String> = []
        for seed in UInt64(1)...20 {
            var rotation = SourceRotation(pool: pool, seed: seed)
            starts.insert(rotation.next()!.deletingLastPathComponent().lastPathComponent)
        }
        XCTAssertGreaterThan(starts.count, 1, "開頭的來源該隨 seed 變動")
    }

    /// 單一來源照樣運作。抽到底就停——同一張蒙太奇裡不重複，
    /// 池只有 4 張就只給得出 4 張（這條原本寫的是「抽 8 次都要有值」，
    /// 那是還允許重複時的行為）。
    func testSingleSourceStillWorks() {
        var rotation = SourceRotation(pool: SourcePool(urls("only", 4)), seed: 1)
        var got: Set<URL> = []
        for _ in 0..<4 {
            got.insert(try! XCTUnwrap(rotation.next()))
        }
        XCTAssertEqual(got.count, 4)
        XCTAssertNil(rotation.next(), "抽完就沒了，不回重複的")
    }

    func testEmptyPoolYieldsNothing() {
        var rotation = SourceRotation(pool: SourcePool([]), seed: 1)
        XCTAssertNil(rotation.next())
        XCTAssertTrue(SourcePool([]).isEmpty)
    }

    // MARK: - 不重複

    /// 同一張蒙太奇裡不該有重複的片，抽片這一端也要守住。
    func testRotationNeverRepeatsWithinOneMontage() {
        let pool = SourcePool(groups: [
            .init(id: "a", urls: urls("a", 40)),
            .init(id: "b", urls: urls("b", 40)),
            .init(id: "c", urls: urls("c", 40)),
        ])
        for seed in UInt64(1)...20 {
            var rotation = SourceRotation(pool: pool, seed: seed)
            var seen: Set<URL> = []
            for _ in 0..<12 {
                guard let url = rotation.next() else { break }
                XCTAssertTrue(seen.insert(url).inserted, "seed \(seed) 抽到重複的 \(url.lastPathComponent)")
            }
        }
    }

    /// 小來源會先被抽完，這時要讓位給別組，而不是回重複的或卡住。
    func testTinySourceIsExhaustedThenYields() {
        let pool = SourcePool(groups: [
            .init(id: "tiny", urls: urls("tiny", 2)),
            .init(id: "big", urls: urls("big", 500)),
        ])
        var rotation = SourceRotation(pool: pool, seed: 5)
        var seen: Set<URL> = []
        for _ in 0..<10 {
            guard let url = rotation.next() else { break }
            XCTAssertTrue(seen.insert(url).inserted)
        }
        XCTAssertEqual(seen.count, 10, "小來源抽完後要繼續從大的拿")
        XCTAssertEqual(seen.filter { $0.path.contains("/tiny/") }.count, 2, "小來源就是只有兩張")
    }

    /// 整個池的張數少於要求的片數時，只能給得出這麼多。
    func testRotationStopsWhenPoolIsExhausted() {
        var rotation = SourceRotation(pool: SourcePool(urls("only", 3)), seed: 1)
        var got: [URL] = []
        for _ in 0..<10 {
            guard let url = rotation.next() else { break }
            got.append(url)
        }
        XCTAssertEqual(Set(got).count, 3)
        XCTAssertNil(rotation.next())
    }
}
