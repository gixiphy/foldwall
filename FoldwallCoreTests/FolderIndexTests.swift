import XCTest
@testable import FoldwallCore

/// 可暫停的閘門：讓測試把掃描卡在中途，驗證呼叫端不會跟著卡住。
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private final class FakeIndexer: MediaIndexing, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: [IndexedItem]] = [:]
    private var count = 0
    let gate: Gate?

    init(gate: Gate? = nil) { self.gate = gate }

    var scanCount: Int { lock.withLock { count } }

    func put(root: URL, images: [String], videos: [String] = []) {
        let items = images.map { IndexedItem(url: root.appending(path: $0), kind: .image) }
            + videos.map { IndexedItem(url: root.appending(path: $0), kind: .video) }
        lock.withLock { storage[root.path] = items }
    }

    func scan(roots: [URL]) async -> [IndexedItem] {
        lock.withLock { count += 1 }
        await gate?.wait()
        return lock.withLock { roots.flatMap { storage[$0.path] ?? [] } }
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000_000)
    var now: @Sendable () -> Date { { self.lock.withLock { self.date } } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
}

final class FolderIndexTests: XCTestCase {

    private let rootA = URL(fileURLWithPath: "/tmp/foldwall-a")
    private let rootB = URL(fileURLWithPath: "/tmp/foldwall-b")

    // MARK: - 不阻塞

    /// 這條是整個修法的重點：掃描還卡在中途，current 就得回得來。
    /// 舊做法 await 全量掃描，一個 90 萬檔的 SMB 資料夾會把管線鎖死 27 小時。
    func testCurrentReturnsWhileScanIsStillRunning() async {
        let gate = Gate()
        let indexer = FakeIndexer(gate: gate)
        indexer.put(root: rootA, images: ["a.jpg", "b.jpg"])
        let index = FolderIndex(indexer: indexer)

        // 閘門沒開＝掃描沒跑完。這行若會等，測試就會卡死在這裡。
        let first = await index.current(roots: [rootA])
        XCTAssertTrue(first.images.isEmpty, "還沒掃完就是空的")
        XCTAssertFalse(first.isComplete, "清單尚未涵蓋所有根目錄")
        XCTAssertTrue(first.isScanning)

        await gate.open()
        await index.waitForScan()

        let second = await index.current(roots: [rootA])
        XCTAssertEqual(second.images.count, 2, "掃完就該看得到")
        XCTAssertTrue(second.isComplete)
        XCTAssertFalse(second.isScanning)
    }

    func testScanCompletionFiresCallback() async {
        let done = expectation(description: "掃描落地時回呼")
        let indexer = FakeIndexer()
        indexer.put(root: rootA, images: ["a.jpg"])
        let index = FolderIndex(indexer: indexer, onScanCompleted: { done.fulfill() })

        _ = await index.current(roots: [rootA])
        await fulfillment(of: [done], timeout: 2)
    }

    // MARK: - 影片同步的安全閥

    /// 清單不完整時 isComplete 必須是 false——上層據此跳過影片差異同步。
    /// 少了這道閘，冷啟動第一輪會把 extension container 裡的影片全刪掉。
    func testIncompleteIndexIsFlaggedSoVideoSyncCanWait() async {
        let gate = Gate()
        let indexer = FakeIndexer(gate: gate)
        indexer.put(root: rootA, images: [], videos: ["clip.mp4"])
        let index = FolderIndex(indexer: indexer)

        let mid = await index.current(roots: [rootA])
        XCTAssertFalse(mid.isComplete)
        XCTAssertTrue(mid.videos.isEmpty, "還沒掃到，不能讓上層以為影片被移除了")

        await gate.open()
        await index.waitForScan()
        let done = await index.current(roots: [rootA])
        XCTAssertTrue(done.isComplete)
        XCTAssertEqual(done.videos.count, 1)
    }

    // MARK: - 根目錄變動

    func testRemovingRootDropsItsFilesAndStaysComplete() async {
        let indexer = FakeIndexer()
        indexer.put(root: rootA, images: ["a.jpg"], videos: ["a.mp4"])
        indexer.put(root: rootB, images: ["b.jpg"], videos: ["b.mp4"])
        let index = FolderIndex(indexer: indexer)

        _ = await index.current(roots: [rootA, rootB])
        await index.waitForScan()

        let after = await index.current(roots: [rootA])
        XCTAssertEqual(after.images.map(\.lastPathComponent), ["a.jpg"])
        XCTAssertEqual(after.videos.map(\.lastPathComponent), ["a.mp4"])
        XCTAssertTrue(after.isComplete,
                      "只移除的話，篩過的清單仍完整——影片同步要能立刻把該刪的刪掉")
    }

    func testAddingRootMarksIndexIncompleteUntilRescan() async {
        let gate = Gate()
        let indexer = FakeIndexer(gate: gate)
        indexer.put(root: rootA, images: ["a.jpg"])
        indexer.put(root: rootB, images: ["b.jpg"])
        let index = FolderIndex(indexer: indexer)

        _ = await index.current(roots: [rootA])
        await gate.open()
        await index.waitForScan()

        let afterAdd = await index.current(roots: [rootA, rootB])
        XCTAssertFalse(afterAdd.isComplete, "新增了根目錄，清單就不完整")
        await index.waitForScan()

        let rescanned = await index.current(roots: [rootA, rootB])
        XCTAssertTrue(rescanned.isComplete)
        XCTAssertEqual(Set(rescanned.images.map(\.lastPathComponent)), ["a.jpg", "b.jpg"])
    }

    func testRootPrefixIsMatchedAtPathBoundary() async {
        let archive = URL(fileURLWithPath: "/tmp/foldwall-archive")
        let indexer = FakeIndexer()
        indexer.put(root: rootA, images: ["a.jpg"])
        indexer.put(root: archive, images: ["deep.jpg"])
        let index = FolderIndex(indexer: indexer)

        _ = await index.current(roots: [rootA, archive])
        await index.waitForScan()

        // 只留 /tmp/foldwall-a：/tmp/foldwall-archive 下的檔案不該被當成它的子項
        let after = await index.current(roots: [rootA])
        XCTAssertEqual(after.images.map(\.lastPathComponent), ["a.jpg"])
    }

    // MARK: - 零來源與節流

    func testEmptyRootsIsCompleteWithoutScanning() async {
        let indexer = FakeIndexer()
        let index = FolderIndex(indexer: indexer)

        let snapshot = await index.current(roots: [])
        XCTAssertTrue(snapshot.isComplete, "沒有來源＝完整的空清單")
        XCTAssertFalse(snapshot.isScanning)
        XCTAssertEqual(indexer.scanCount, 0, "零資料夾不必開掃描")
    }

    func testRescanIsThrottled() async {
        let clock = Clock()
        let indexer = FakeIndexer()
        indexer.put(root: rootA, images: ["a.jpg"])
        let index = FolderIndex(indexer: indexer, now: clock.now)

        _ = await index.current(roots: [rootA])
        await index.waitForScan()
        XCTAssertEqual(indexer.scanCount, 1)

        clock.advance(60)
        _ = await index.current(roots: [rootA])
        XCTAssertEqual(indexer.scanCount, 1, "間隔內不重掃：桌布最快 5 分鐘換一次，沒必要每輪重走磁碟")

        clock.advance(FolderIndex.rescanInterval + 1)
        _ = await index.current(roots: [rootA])
        await index.waitForScan()
        XCTAssertEqual(indexer.scanCount, 2, "夠久了就在背景補一次")
    }

    func testInvalidateForcesRescanImmediately() async {
        let clock = Clock()
        let indexer = FakeIndexer()
        indexer.put(root: rootA, images: ["a.jpg"])
        let index = FolderIndex(indexer: indexer, now: clock.now)

        _ = await index.current(roots: [rootA])
        await index.waitForScan()

        await index.invalidate(roots: [rootA])
        await index.waitForScan()
        XCTAssertEqual(indexer.scanCount, 2, "使用者改了來源就該立刻重掃，不等節流")
    }
}
