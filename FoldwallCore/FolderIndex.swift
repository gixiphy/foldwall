//  FolderIndex.swift
//  資料夾索引的快取層：**問了立刻答，掃描在背景跑。**
//
//  為什麼需要這層：MediaIndexer.scan 是全量走訪，在大型 SMB 相簿上要幾分鐘
//  （實測 90 萬檔約 4.2 分鐘）。舊做法是每輪 refresh 都 await 它跑完，
//  結果一個慢資料夾把整條管線鎖死——連幾秒就能備好的網路／相簿來源都出不了圖。
//
//  這裡的策略跟 RemoteSourcePool／PhotosPool 一致：**快取就是池**，
//  重掃只在「根目錄變了」或「距上次夠久」時於背景啟動，呼叫端永遠不等。
//
//  快取還會落地到磁碟（見 FolderIndexStore），否則 App 一關就沒了，
//  每次冷啟動都要付一次全量重掃的錢。

import Foundation
import OSLog

public actor FolderIndex {

    private static let log = Logger(subsystem: "app.foldwall", category: "index")


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
    /// nil＝不落地（測試與純記憶體用法）。
    private let store: (any FolderIndexPersisting)?

    private var snapshot = Snapshot()
    private var scannedRoots: [URL] = []
    private var lastScan: Date?
    private var scanTask: Task<Void, Never>?
    /// 磁碟上的索引只讀一次，而且是**第一次被問到的時候**才讀。
    /// 放在 init 裡的話，解一份 90 萬路徑的 plist 會卡住建立它的那條執行緒（MainActor）。
    private var didHydrate = false

    /// - Parameter onScanCompleted: 背景掃描落地時回呼，讓上層立刻補一輪合成，
    ///   而不是乾等到下一個間隔。
    public init(
        indexer: any MediaIndexing = MediaIndexer(),
        now: @escaping @Sendable () -> Date = { .now },
        store: (any FolderIndexPersisting)? = nil,
        onScanCompleted: (@Sendable () -> Void)? = nil
    ) {
        self.indexer = indexer
        self.now = now
        self.store = store
        self.onScanCompleted = onScanCompleted
    }

    /// 回傳當下快取，必要時在背景啟動重掃。**不等掃描。**
    public func current(roots: [URL]) -> Snapshot {
        hydrate()
        applyRootChange(roots)

        let stale = lastScan.map { now().timeIntervalSince($0) > Self.rescanInterval } ?? true
        if stale || !snapshot.isComplete {
            startScan(roots: roots)
        }
        return snapshot
    }

    /// 使用者按「下一張」或改了來源時強制重掃，同樣不阻塞。
    public func invalidate(roots: [URL]) {
        hydrate()
        applyRootChange(roots)
        lastScan = nil
        startScan(roots: roots)
    }

    /// 測試用：等背景掃描跑完。正式流程不該呼叫這個。
    public func waitForScan() async {
        await scanTask?.value
    }

    // MARK: - 私有

    /// 把上次關掉前存下的索引撈回來當起手式。
    ///
    /// `lastScan` 也照抄：離上次掃描還沒超過 `rescanInterval` 就完全不必重掃，
    /// 超過了就照常在背景補一次——**但池從第一秒就是滿的**，不必等它跑完。
    private func hydrate() {
        guard !didHydrate else { return }
        didHydrate = true

        guard let persisted = store?.load() else { return }
        snapshot.images = persisted.images.map { URL(filePath: $0, directoryHint: .notDirectory) }
        snapshot.videos = persisted.videos.map { URL(filePath: $0, directoryHint: .notDirectory) }
        // 存下來的清單當時是掃完整的；根目錄如果變了，接下來的
        // applyRootChange 會把它降級成不完整。
        snapshot.isComplete = true
        scannedRoots = persisted.roots.map { URL(filePath: $0, directoryHint: .isDirectory) }
        lastScan = persisted.scannedAt
    }

    /// 編碼與寫檔丟到 actor 外面做：一份 90 萬路徑的清單編起來不便宜，
    /// 佔著 actor 會讓下一輪 current 排在後面等。
    private func persist() {
        // 只存掃得完整的那份。有根目錄讀不到時存下去，下次冷啟動 hydrate
        // 會把它當成完整清單——磁碟上留著上一份好的比較安全。
        guard let store, snapshot.isComplete else { return }
        let payload = PersistedFolderIndex(
            roots: scannedRoots.map { $0.path(percentEncoded: false) },
            scannedAt: lastScan ?? now(),
            images: snapshot.images.map { $0.path(percentEncoded: false) },
            videos: snapshot.videos.map { $0.path(percentEncoded: false) }
        )
        Task.detached(priority: .utility) { store.save(payload) }
    }

    /// 根目錄變動時先就地修正快取，別讓已移除的資料夾還留在池裡。
    private func applyRootChange(_ roots: [URL]) {
        guard Self.pathList(roots) != Self.pathList(scannedRoots) else {
            // 路徑一樣但**表示法**可能不同：從磁碟撈回來的根目錄帶結尾斜線，
            // 書籤解出來的沒有，直接比 URL 會判成「換了根目錄」而每次冷啟動都重掃。
            // 統一成呼叫端給的那份，後面 commit 的比對才對得上。
            scannedRoots = roots
            return
        }

        let removedOnly = Set(roots).isSubset(of: Set(scannedRoots))
        snapshot.images = snapshot.images.filter { isUnder(roots, $0) }
        snapshot.videos = snapshot.videos.filter { isUnder(roots, $0) }

        // 只移除的話，篩過的清單仍然是完整的——影片同步可以立刻把該刪的刪掉。
        // 只要新增了根目錄，清單就不完整，同步得等重掃。
        snapshot.isComplete = removedOnly && snapshot.isComplete
        scannedRoots = roots
        lastScan = nil
    }

    /// 比對根目錄只看標準化後的路徑字串，不看 URL 本身。
    ///
    /// 還要自己剝掉結尾斜線：`path(percentEncoded:)` 會**保留**它
    /// （跟已棄用的 `.path` 不同），所以 `/a/` 與 `/a` 會比成兩個不同的根目錄。
    private static func pathList(_ urls: [URL]) -> [String] {
        urls.map { url in
            let path = url.standardizedFileURL.path(percentEncoded: false)
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
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
            persist()
            return
        }

        snapshot.isScanning = true
        scanTask = Task { [indexer] in
            let scan = await indexer.scan(roots: roots)
            await self.commit(scan, roots: roots)
        }
    }

    private func commit(_ scan: MediaScan, roots: [URL]) {
        scanTask = nil
        snapshot.isScanning = false
        lastScan = now()

        // 掃到一半使用者又改了來源 → 這批結果不算數，直接重來。
        guard Self.pathList(roots) == Self.pathList(scannedRoots) else {
            startScan(roots: scannedRoots)
            return
        }

        var images = scan.items.filter { $0.kind == .image }.map(\.url)
        var videos = scan.items.filter { $0.kind == .video }.map(\.url)

        // 有根目錄打不開（NAS 沒掛、磁碟拔掉）：**留著上一輪掃到的東西**，
        // 並且不准宣稱清單完整。
        //
        // 少了這段，把 NAS 拔掉再開 App 就會：掃描回空清單 → isComplete = true
        // → 影片差異同步認定所有影片都被移除 → 把 extension container 裡的全刪掉。
        // 檔案還好端端在 NAS 上，只是這一刻讀不到而已。
        if !scan.unreadableRoots.isEmpty {
            images += snapshot.images.filter { isUnder(scan.unreadableRoots, $0) }
            videos += snapshot.videos.filter { isUnder(scan.unreadableRoots, $0) }
            Self.log.notice(
                "\(scan.unreadableRoots.count) 個根目錄讀不到，沿用上一輪清單、不標記完整")
        }

        snapshot.images = images
        snapshot.videos = videos
        snapshot.isComplete = scan.unreadableRoots.isEmpty
        persist()
        onScanCompleted?()
    }
}
