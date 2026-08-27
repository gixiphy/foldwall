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
    private var unreadable: Set<String> = []
    private var count = 0
    let gate: Gate?

    init(gate: Gate? = nil) { self.gate = gate }

    var scanCount: Int { lock.withLock { count } }

    func put(root: URL, images: [String], videos: [String] = []) {
        let items = images.map { IndexedItem(url: root.appending(path: $0), kind: .image) }
            + videos.map { IndexedItem(url: root.appending(path: $0), kind: .video) }
        lock.withLock { storage[root.path] = items }
    }

    /// 標記成「讀不到」：模擬 NAS 沒掛載。
    func markUnreadable(_ root: URL) {
        lock.withLock { _ = unreadable.insert(root.path) }
    }

    func scan(roots: [URL]) async -> MediaScan {
        lock.withLock { count += 1 }
        await gate?.wait()
        return lock.withLock {
            let dead = roots.filter { unreadable.contains($0.path) }
            let live = roots.filter { !unreadable.contains($0.path) }
            return MediaScan(items: live.flatMap { storage[$0.path] ?? [] },
                             unreadableRoots: dead)
        }
    }
}

private final class FakeStore: FolderIndexPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PersistedFolderIndex?
    private var saves = 0

    init(_ initial: PersistedFolderIndex? = nil) { stored = initial }

    var saveCount: Int { lock.withLock { saves } }
    var current: PersistedFolderIndex? { lock.withLock { stored } }

    func load() -> PersistedFolderIndex? { lock.withLock { stored } }

    func save(_ index: PersistedFolderIndex) {
        lock.withLock {
            stored = index
            saves += 1
        }
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

    // MARK: - 讀不到的根目錄：不能刪

    /// NAS 沒掛載時掃出來是空的。**不能**因此宣稱清單完整——
    /// 上層會據此把 extension container 裡的影片全刪掉，而檔案還好端端在 NAS 上。
    func testUnreadableRootNeverClaimsCompleteness() async {
        let indexer = FakeIndexer()
        indexer.put(root: rootA, images: ["a.jpg"], videos: ["a.mp4"])
        let index = FolderIndex(indexer: indexer)

        _ = await index.current(roots: [rootA])
        await index.waitForScan()
        let good = await index.current(roots: [rootA])
        XCTAssertTrue(good.isComplete)

        // 磁碟被拔掉
        indexer.markUnreadable(rootA)
        await index.invalidate(roots: [rootA])
        await index.waitForScan()

        let offline = await index.current(roots: [rootA])
        XCTAssertFalse(offline.isComplete, "讀不到就不是完整清單——影片同步要據此跳過")
        XCTAssertEqual(offline.videos.map(\.lastPathComponent), ["a.mp4"],
                       "沿用上一輪：檔案還在 NAS 上，只是這一刻讀不到")
        XCTAssertEqual(offline.images.map(\.lastPathComponent), ["a.jpg"])
    }

    /// 目錄真的在、只是裡面沒東西——那才是「空」，清單仍然完整。
    func testEmptyButReadableRootIsStillComplete() async {
        let indexer = FakeIndexer()
        indexer.put(root: rootA, images: [])
        let index = FolderIndex(indexer: indexer)

        _ = await index.current(roots: [rootA])
        await index.waitForScan()

        let snapshot = await index.current(roots: [rootA])
        XCTAssertTrue(snapshot.isComplete, "掃過但沒東西 ≠ 讀不到")
        XCTAssertTrue(snapshot.images.isEmpty)
    }

    /// 一個好、一個壞：好的那個要更新，壞的那個沿用舊清單。
    func testOneUnreadableRootDoesNotDropTheOthers() async {
        let indexer = FakeIndexer()
        indexer.put(root: rootA, images: ["a.jpg"])
        indexer.put(root: rootB, images: ["b.jpg"])
        let index = FolderIndex(indexer: indexer)

        _ = await index.current(roots: [rootA, rootB])
        await index.waitForScan()

        indexer.markUnreadable(rootB)
        indexer.put(root: rootA, images: ["a.jpg", "a2.jpg"])
        await index.invalidate(roots: [rootA, rootB])
        await index.waitForScan()

        let snapshot = await index.current(roots: [rootA, rootB])
        XCTAssertEqual(Set(snapshot.images.map(\.lastPathComponent)), ["a.jpg", "a2.jpg", "b.jpg"])
        XCTAssertFalse(snapshot.isComplete)
    }

    /// 讀不到時那份殘缺清單不准落地，否則下次冷啟動 hydrate 會把它當成完整的。
    func testIncompleteScanIsNotPersisted() async {
        let store = FakeStore()
        let indexer = FakeIndexer()
        indexer.put(root: rootA, images: ["a.jpg"])
        let index = FolderIndex(indexer: indexer, store: store)

        _ = await index.current(roots: [rootA])
        await index.waitForScan()
        for _ in 0..<50 where store.saveCount == 0 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let savesAfterGoodScan = store.saveCount
        XCTAssertGreaterThan(savesAfterGoodScan, 0)

        indexer.markUnreadable(rootA)
        await index.invalidate(roots: [rootA])
        await index.waitForScan()
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(store.saveCount, savesAfterGoodScan, "殘缺的那份不准蓋掉磁碟上完整的索引")
        XCTAssertEqual(store.current?.images, [rootA.appending(path: "a.jpg").path])
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

    /// 有根目錄離線時 isComplete 永遠是 false——不能因此每輪 current 都全量重掃：
    /// 一個離線的 NAS 會把好端端的幾十萬檔本機根目錄也一起拖下水。
    /// 提早重試可以，但要有下限（incompleteRetryInterval）。
    func testIncompleteIndexRetriesWithBackoffNotEveryCall() async {
        let clock = Clock()
        let indexer = FakeIndexer()
        indexer.put(root: rootA, images: ["a.jpg"])
        indexer.markUnreadable(rootB)
        let index = FolderIndex(indexer: indexer, now: clock.now)

        _ = await index.current(roots: [rootA, rootB])
        await index.waitForScan()
        XCTAssertEqual(indexer.scanCount, 1)

        // 下一輪 refresh（間隔內）：清單不完整，但不准立刻又全量重掃
        clock.advance(60)
        _ = await index.current(roots: [rootA, rootB])
        XCTAssertEqual(indexer.scanCount, 1, "離線根目錄不該讓每輪 refresh 都變成全量重掃")

        // 過了重試下限就補一次——NAS 掛回來要在這時候被發現
        clock.advance(FolderIndex.incompleteRetryInterval + 1)
        _ = await index.current(roots: [rootA, rootB])
        await index.waitForScan()
        XCTAssertEqual(indexer.scanCount, 2)
    }

    // MARK: - 落地

    /// 這條是持久化的重點：冷啟動第一次問就要有圖，不必等全量重掃跑完。
    func testHydratedIndexIsUsableBeforeAnyScan() async {
        let clock = Clock()
        let store = FakeStore(PersistedFolderIndex(
            roots: [rootA.path],
            scannedAt: clock.now(),
            images: [rootA.appending(path: "a.jpg").path],
            videos: [rootA.appending(path: "a.mp4").path]
        ))
        let gate = Gate()
        let indexer = FakeIndexer(gate: gate)   // 閘門關著＝這輪掃描不會落地
        let index = FolderIndex(indexer: indexer, now: clock.now, store: store)

        let first = await index.current(roots: [rootA])
        XCTAssertEqual(first.images.map(\.lastPathComponent), ["a.jpg"], "上次存的清單要直接接手")
        XCTAssertEqual(first.videos.map(\.lastPathComponent), ["a.mp4"])
        XCTAssertTrue(first.isComplete, "存下來的是掃完整的清單")
        XCTAssertFalse(first.isScanning, "還在節流間隔內，根本不必開掃描")
        XCTAssertEqual(indexer.scanCount, 0)

        await gate.open()
    }

    /// 存的 lastScan 過期了就照常在背景補一次——但池從第一秒就是滿的。
    func testStaleHydratedIndexStillServesWhileRescanning() async {
        let clock = Clock()
        let store = FakeStore(PersistedFolderIndex(
            roots: [rootA.path],
            scannedAt: clock.now().addingTimeInterval(-FolderIndex.rescanInterval - 1),
            images: [rootA.appending(path: "old.jpg").path],
            videos: []
        ))
        let gate = Gate()
        let indexer = FakeIndexer(gate: gate)
        indexer.put(root: rootA, images: ["new.jpg"])
        let index = FolderIndex(indexer: indexer, now: clock.now, store: store)

        let during = await index.current(roots: [rootA])
        XCTAssertEqual(during.images.map(\.lastPathComponent), ["old.jpg"],
                       "重掃還沒落地，先用舊清單撐著，不要退回空池")
        XCTAssertTrue(during.isScanning, "過期了就在背景補一次")

        await gate.open()
        await index.waitForScan()
        let after = await index.current(roots: [rootA])
        XCTAssertEqual(after.images.map(\.lastPathComponent), ["new.jpg"])
    }

    /// 存下來的根目錄跟現在的對不上，就不能宣稱清單完整——
    /// 否則影片同步會把新資料夾裡還在的影片當成已移除刪掉。
    func testHydratedIndexIsIncompleteWhenRootsChanged() async {
        let clock = Clock()
        let store = FakeStore(PersistedFolderIndex(
            roots: [rootA.path],
            scannedAt: clock.now(),
            images: [rootA.appending(path: "a.jpg").path],
            videos: []
        ))
        let gate = Gate()
        let index = FolderIndex(indexer: FakeIndexer(gate: gate), now: clock.now, store: store)

        let snapshot = await index.current(roots: [rootA, rootB])
        XCTAssertFalse(snapshot.isComplete, "多了一個沒掃過的根目錄，清單就不完整")
        await gate.open()
    }

    func testScanResultIsPersisted() async {
        let store = FakeStore()
        let indexer = FakeIndexer()
        indexer.put(root: rootA, images: ["a.jpg"], videos: ["a.mp4"])
        let index = FolderIndex(indexer: indexer, store: store)

        _ = await index.current(roots: [rootA])
        await index.waitForScan()

        // 寫檔是 detached 的，給它一點時間落地
        for _ in 0..<50 where store.saveCount == 0 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let saved = store.current
        XCTAssertEqual(saved?.roots, [rootA.path])
        XCTAssertEqual(saved?.images, [rootA.appending(path: "a.jpg").path])
        XCTAssertEqual(saved?.videos, [rootA.appending(path: "a.mp4").path])
    }

    /// 沒有 store 就是純記憶體，行為與加這層之前完全相同。
    func testWithoutStoreNothingIsLoaded() async {
        let gate = Gate()
        let index = FolderIndex(indexer: FakeIndexer(gate: gate))
        let snapshot = await index.current(roots: [rootA])
        XCTAssertTrue(snapshot.images.isEmpty)
        XCTAssertFalse(snapshot.isComplete)
        await gate.open()
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
