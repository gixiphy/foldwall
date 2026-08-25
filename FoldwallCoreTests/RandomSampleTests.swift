import XCTest
@testable import FoldwallCore

final class RandomSampleTests: XCTestCase {

    private func rng(_ seed: UInt64 = 1) -> SeededGenerator { SeededGenerator(seed: seed) }

    func testReturnsRequestedCount() {
        var generator = rng()
        XCTAssertEqual(RandomSample.indices(count: 3, total: 101_046, using: &generator).count, 3)
    }

    func testIndicesAreDistinct() {
        var generator = rng()
        let picked = RandomSample.indices(count: 50, total: 200, using: &generator)
        XCTAssertEqual(Set(picked).count, picked.count)
    }

    func testIndicesStayInRange() {
        var generator = rng()
        for index in RandomSample.indices(count: 20, total: 37, using: &generator) {
            XCTAssertTrue((0..<37).contains(index))
        }
    }

    /// 要的比集合還多時，最多就是全部。
    func testCannotPickMoreThanExists() {
        var generator = rng()
        let picked = RandomSample.indices(count: 10, total: 4, using: &generator)
        XCTAssertEqual(Set(picked), [0, 1, 2, 3])
    }

    /// 高比例時走洗牌法，仍要給滿且不重複——這是最容易撞號撞到放棄的路徑。
    func testHighRatioStillReturnsEverythingRequested() {
        var generator = rng()
        let picked = RandomSample.indices(count: 9, total: 10, using: &generator)
        XCTAssertEqual(picked.count, 9)
        XCTAssertEqual(Set(picked).count, 9)
    }

    func testEmptyOrZeroIsSafe() {
        var generator = rng()
        XCTAssertTrue(RandomSample.indices(count: 5, total: 0, using: &generator).isEmpty)
        XCTAssertTrue(RandomSample.indices(count: 0, total: 5, using: &generator).isEmpty)
    }

    /// 同 seed 要抽到同一組，否則測試會隨機紅。
    func testDeterministicForSameSeed() {
        var a = rng(42), b = rng(42)
        XCTAssertEqual(RandomSample.indices(count: 5, total: 1000, using: &a),
                       RandomSample.indices(count: 5, total: 1000, using: &b))
    }

    /// 抽出來的要真的分散在整個範圍，不是永遠前幾張。
    func testSpreadsAcrossTheWholeRange() {
        var generator = rng()
        var seen: Set<Int> = []
        for _ in 0..<200 {
            seen.formUnion(RandomSample.indices(count: 3, total: 100_000, using: &generator))
        }
        XCTAssertGreaterThan(seen.filter { $0 > 50_000 }.count, 100, "後半段也要抽得到")
    }
}
