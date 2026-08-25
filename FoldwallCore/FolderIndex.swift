//  FolderIndex.swift
//  資料夾索引的快取層：**問了立刻答，掃描在背景跑。**
//
//  為什麼需要這層：MediaIndexer.scan 是全量走訪，在大型 SMB 相簿上要幾分鐘
//  （實測 90 萬檔約 4.2 分鐘）。舊做法是每輪 refresh 都 await 它跑完，
//  結果一個慢資料夾把整條管線鎖死——連幾秒就能備好的網路／相簿來源都出不了圖。
//
//  這裡的策略跟 RemoteSourcePool／PhotosPool 一致：**快取就是池**，
//  重掃只在「根目錄變了」或「距上次夠久」時於背景啟動，呼叫端永遠不等。

import Foundation

public actor FolderIndex {

    public struct Snapshot: Sendable, Equatable {
        public var images: [URL] = []
        public var videos: [URL] = []
        /// 目前的清單是否涵蓋了所有根目錄。
        ///
        /// 影片差異同步**必須**等這個為 true：清單不完整時同步會把還在來源裡的影片
        /// 當成「已移除」清掉（見 VideoLibrary.sync）。
        public var isComplete = false
        public var isScanning = false

        public init() {}
    }

    /// 兩次背景重掃的最短間隔。桌布最快 5 分鐘換一次，沒必要每輪重走磁碟。
    public static let rescanInterval: TimeInterval = 15 * 60

    private let indexer: any MediaIndexing
    private let now: @Sendable () -> Date
    private let onScanCompleted: (@Sendable () -> Void)?

    private var snapshot = Snapshot()
    private var scannedRoots: [URL] = []
    private var lastScan: Date?
    private var scanTask: Task<Void, Never>?

    /// - Parameter onScanCompleted: 背景掃描落地時回呼，讓上層立刻補一輪合成，
    ///   而不是乾等到下一個間隔。
    public init(
        indexer: any MediaIndexing = MediaIndexer(),
        now: @escaping @Sendable () -> Date = { .now },
        onScanCompleted: (@Sendable () -> Void)? = nil
    ) {
        self.indexer = indexer
        self.now = now
        self.onScanCompleted = onScanCompleted
    }

    /// 回傳當下快取，必要時在背景啟動重掃。**不等掃描。**
    public func current(roots: [URL]) -> Snapshot {
        applyRootChange(roots)

        let stale = lastScan.map { now().timeIntervalSince($0) > Self.rescanInterval } ?? true
        if stale || !snapshot.isComplete {
            startScan(roots: roots)
        }
        return snapshot
    }

    /// 使用者按「下一張」或改了來源時強制重掃，同樣不阻塞。
    public func invalidate(roots: [URL]) {
        applyRootChange(roots)
        lastScan = nil
        startScan(roots: roots)
    }

    /// 測試用：等背景掃描跑完。正式流程不該呼叫這個。
    public func waitForScan() async {
        await scanTask?.value
    }

    // MARK: - 私有

    /// 根目錄變動時先就地修正快取，別讓已移除的資料夾還留在池裡。
    private func applyRootChange(_ roots: [URL]) {
        guard roots != scannedRoots else { return }

        let removedOnly = Set(roots).isSubset(of: Set(scannedRoots))
        snapshot.images = snapshot.images.filter { isUnder(roots, $0) }
        snapshot.videos = snapshot.videos.filter { isUnder(roots, $0) }

        // 只移除的話，篩過的清單仍然是完整的——影片同步可以立刻把該刪的刪掉。
        // 只要新增了根目錄，清單就不完整，同步得等重掃。
        snapshot.isComplete = removedOnly && snapshot.isComplete
        scannedRoots = roots
        lastScan = nil
    }

    private func isUnder(_ roots: [URL], _ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return roots.contains { root in
            let base = root.standardizedFileURL.path
            // 比到路徑分隔為止：/Volumes/Arch 不該吃掉 /Volumes/Archive
            return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }

    private func startScan(roots: [URL]) {
        guard scanTask == nil else { return }   // 上一輪還在走就別疊上去

        guard !roots.isEmpty else {
            // 零資料夾不必開 task：清單就是空的，而且是完整的空。
            snapshot.images = []
            snapshot.videos = []
            snapshot.isComplete = true
            snapshot.isScanning = false
            lastScan = now()
            return
        }

        snapshot.isScanning = true
        scanTask = Task { [indexer] in
            let items = await indexer.scan(roots: roots)
            await self.commit(items: items, roots: roots)
        }
    }

    private func commit(items: [IndexedItem], roots: [URL]) {
        scanTask = nil
        snapshot.isScanning = false
        lastScan = now()

        // 掃到一半使用者又改了來源 → 這批結果不算數，直接重來。
        guard roots == scannedRoots else {
            startScan(roots: scannedRoots)
            return
        }

        snapshot.images = items.filter { $0.kind == .image }.map(\.url)
        snapshot.videos = items.filter { $0.kind == .video }.map(\.url)
        snapshot.isComplete = true
        onScanCompleted?()
    }
}
