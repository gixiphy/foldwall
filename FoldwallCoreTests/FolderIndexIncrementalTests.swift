import Foundation
import Testing
@testable import FoldwallCore

/// 可前進的假時鐘。
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private final class MemoryStore: FolderIndexPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PersistedFolderIndex?
    init(_ initial: PersistedFolderIndex? = nil) { stored = initial }
    var value: PersistedFolderIndex? { lock.withLock { stored } }
    func load() -> PersistedFolderIndex? { lock.withLock { stored } }
    func save(_ index: PersistedFolderIndex) { lock.withLock { stored = index } }
}

@Suite("FolderIndex incremental")
struct FolderIndexIncrementalTests {

    private let root = URL(filePath: "/r", directoryHint: .isDirectory)

    private func sample() -> FakeFileSystem {
        let fs = FakeFileSystem()
        fs.mkdir("/r")
        fs.mkdir("/r/a")
        fs.addFile("/r/1.jpg", dirModified: 100)
        fs.addFile("/r/a/2.mov", dirModified: 100)
        return fs
    }

    /// 先跑完第一輪全量，回傳準備好的索引。
    private func primed(_ fs: FakeFileSystem, clock: TestClock, store: MemoryStore? = nil,
                        completions: Counter = Counter()) async -> FolderIndex {
        let index = FolderIndex(scanner: fs.scanner(), now: { clock.now }, store: store,
                                onScanCompleted: { completions.increment() })
        _ = await index.current(roots: [root])
        await index.waitForScan()
        return index
    }

    @Test("A stale index is re-verified without relisting unchanged directories")
    func staleIndexIsIncremental() async {
        let fs = sample(), clock = TestClock()
        let index = await primed(fs, clock: clock)
        fs.resetCalls()
        clock.advance(FolderIndex.rescanInterval + 1)
        _ = await index.current(roots: [root])
        await index.waitForScan()
        #expect(fs.listCalls.isEmpty)
        let snapshot = await index.current(roots: [root])
        #expect(snapshot.images == ["/r/1.jpg"])
        #expect(snapshot.videos == ["/r/a/2.mov"])
        #expect(snapshot.isComplete)
    }

    @Test("A day later the whole tree is relisted once")
    func dailyFullRescan() async {
        let fs = sample(), clock = TestClock()
        let index = await primed(fs, clock: clock)
        fs.resetCalls()
        clock.advance(FolderIndex.fullRescanInterval + 1)
        _ = await index.current(roots: [root])
        await index.waitForScan()
        #expect(Set(fs.listCalls) == ["/r", "/r/a"])
    }

    @Test("FSEvents changes rescan only the reported subtree and do not trigger a refresh")
    func directoriesChangedIsScopedAndQuiet() async {
        let fs = sample(), clock = TestClock(), completions = Counter()
        let index = await primed(fs, clock: clock, completions: completions)
        #expect(completions.count == 1)
        fs.addFile("/r/a/3.jpg", dirModified: 200)
        fs.resetCalls()
        await index.directoriesChanged(["/r/a"])
        await index.waitForScan()
        #expect(fs.listCalls == ["/r/a"])
        #expect(await index.current(roots: [root]).images == ["/r/1.jpg", "/r/a/3.jpg"])
        #expect(completions.count == 1, "檔案一動桌布就重合成，使用者會覺得桌布亂跳")
    }

    @Test("A transient error during an incremental scan keeps the files and the incompleteness")
    func transientErrorDuringIncrementalKeepsFiles() async {
        let fs = sample(), clock = TestClock()
        let index = await primed(fs, clock: clock)
        fs.fail("/r/a", errno: ETIMEDOUT)
        clock.advance(FolderIndex.rescanInterval + 1)
        _ = await index.current(roots: [root])
        await index.waitForScan()
        let snapshot = await index.current(roots: [root])
        #expect(snapshot.videos == ["/r/a/2.mov"], "逾時不等於被刪")
        #expect(!snapshot.isComplete, "不完整的清單會讓影片同步誤刪")
    }

    @Test("A cold start with a v2 file is incremental, not full")
    func hydratedTreeAvoidsFullRescan() async {
        let fs = sample(), clock = TestClock(), store = MemoryStore()
        _ = await primed(fs, clock: clock, store: store)
        try? await Task.sleep(for: .milliseconds(200))   // persist 在 detached task 裡寫
        #expect(store.value?.tree != nil)

        fs.resetCalls()
        clock.advance(FolderIndex.rescanInterval + 1)
        let reopened = FolderIndex(scanner: fs.scanner(), now: { clock.now }, store: store)
        _ = await reopened.current(roots: [root])
        await reopened.waitForScan()
        #expect(fs.listCalls.isEmpty)
    }

    @Test("Upgrading from a v1 file keeps an offline root's files")
    func version1IndexKeepsOfflineRootFiles() async {
        let fs = sample(), clock = TestClock()
        let nas = URL(filePath: "/nas", directoryHint: .isDirectory)
        let store = MemoryStore(PersistedFolderIndex(
            // 一天前存的：到期了，會真的跑一輪掃描（只掃 /r），才驗得到合併離線根那段
            version: 1, roots: ["/r", "/nas"], scannedAt: clock.now.addingTimeInterval(-86_400),
            images: ["/nas/x.jpg", "/r/1.jpg"], videos: ["/r/a/2.mov"], isComplete: true))
        let index = FolderIndex(scanner: fs.scanner(), now: { clock.now }, store: store)
        _ = await index.current(roots: [root, nas], offline: [nas])
        await index.waitForScan()
        let snapshot = await index.current(roots: [root, nas], offline: [nas])
        #expect(fs.listCalls.contains("/r"), "v1 沒有 mtime，/r 要重列")
        #expect(!fs.listCalls.contains("/nas"), "離線的根不送進掃描器")
        #expect(snapshot.images == ["/nas/x.jpg", "/r/1.jpg"])
        #expect(!snapshot.isComplete)
    }
}
