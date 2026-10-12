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
//  重掃是**增量**的（見 TreeScanner）：索引記得每個目錄的 mtime，到期時只 stat 每個目錄，
//  有變的才重列。本機磁碟另有 FSEvents（見 DirectoryChangeMonitor）點名哪幾個目錄動了，
//  只驗那幾棵子樹。一天一次不信 mtime、全部重列，兜住 mtime 語意怪異的伺服器。
//
//  快取還會落地到磁碟（見 FolderIndexStore），否則 App 一關就沒了，
//  每次冷啟動都要付一次全量重掃的錢。

import Foundation
import OSLog

public actor FolderIndex {

    private static let log = Logger(subsystem: "app.foldwall", category: "index")


    public struct Snapshot: Sendable, Equatable {
        /// **存路徑字串，不存 URL。**
        ///
        /// 這份清單是 App 生命週期裡最大的一塊常駐資料（實測 71 萬項），而
        /// Swift 的 URL 一個要 ~691 B（StringStorage 293 ＋ URLParseInfo 224
        /// ＋ _SwiftURL 80 ＋ 三個 32 B 的 box），路徑字串只要 ~309 B。
        /// 抽到要用的那十幾張才組 URL。
        ///
        /// 附帶的好處：落地格式本來就是路徑字串，persist/hydrate 不必再把
        /// 71 萬個 URL 與字串互轉一次；RootMatcher 比對也不必逐項 `.path`。
        public var images: [String] = []
        public var videos: [String] = []
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

    /// 清單不完整、而且**不知道是哪個根出問題**時的重試間隔。
    ///
    /// 呼叫端明講哪幾個根離線時走的不是這條（見 `current(roots:offline:)`）：
    /// 那幾個根要等它掛回來才值得重掃，用計時器輪詢只是對著沒掛載的網路磁碟
    /// 一再撞逾時。這道下限留給「掃到一半才發現讀不到」的情況——
    /// 沒有它就等於**每次 refresh 都全量重走所有根目錄**（含好端端的
    /// 幾十萬檔本機資料夾），而 refresh 的觸發點有二十幾個。
    public static let incompleteRetryInterval: TimeInterval = 5 * 60

    /// 多久做一次不信 mtime 的全量校正。mtime 漏報的情況（同秒變動、怪異的 NAS）
    /// 最晚在這個間隔內補回來。
    public static let fullRescanInterval: TimeInterval = 24 * 60 * 60

    private let scanner: any DirectoryTreeScanning
    private let now: @Sendable () -> Date
    private let onScanCompleted: (@Sendable () -> Void)?
    /// nil＝不落地（測試與純記憶體用法）。
    private let store: (any FolderIndexPersisting)?

    private var snapshot = Snapshot()
    /// 索引的真實來源。`snapshot.images`／`videos` 是它攤平出來的，只在內容變了才重算。
    private var tree = DirectoryTree()
    private var lastFullScan: Date?
    /// 掃描進行中又收到的 FSEvents 範圍：這輪掃完立刻補一輪，不能丟。
    private var pendingScope: Set<String>?
    private var scanStartedAt: Date?
    private var scannedRoots: [URL] = []
    /// 呼叫端已經確認這一刻讀不到的根（NAS 沒掛、磁碟拔掉、雲端登出）。
    /// 這些根**不送進索引器**，但仍留在 `scannedRoots` 裡——見 `applyOfflineChange`。
    private var offlineRoots: [URL] = []
    private var lastScan: Date?
    private var scanTask: Task<Void, Never>?
    /// 磁碟上的索引只讀一次，而且是**第一次被問到的時候**才讀。
    /// 放在 init 裡的話，解一份 90 萬路徑的 plist 會卡住建立它的那條執行緒（MainActor）。
    private var didHydrate = false

    /// - Parameters:
    ///   - indexer: 只會全量掃描的舊介面（既有測試用）。給了它而沒給 `scanner` 時，每輪都是全量。
    ///   - scanner: 正式路徑用 `TreeScanner()`。兩個都沒給也是它。
    ///   - onScanCompleted: 背景掃描落地時回呼，讓上層立刻補一輪合成，
    ///     而不是乾等到下一個間隔。FSEvents 觸發的小掃描不回呼（見 commit）。
    public init(
        indexer: (any MediaIndexing)? = nil,
        scanner: (any DirectoryTreeScanning)? = nil,
        now: @escaping @Sendable () -> Date = { .now },
        store: (any FolderIndexPersisting)? = nil,
        onScanCompleted: (@Sendable () -> Void)? = nil
    ) {
        self.scanner = scanner
            ?? indexer.map { LegacyIndexerScanner(indexer: $0) }
            ?? TreeScanner()
        self.now = now
        self.store = store
        self.onScanCompleted = onScanCompleted
    }

    /// 回傳當下快取，必要時在背景啟動重掃。**不等掃描。**
    ///
    /// - Parameters:
    ///   - roots: **所有**解析得出路徑的根，含這一刻讀不到的那些。少給的話
    ///     索引會把離線的根當成「使用者移除了」——把那顆碟的整份清單刪掉並落地，
    ///     磁碟掛回來就得再付一次全量重掃的錢（實測 90 萬檔 4.2 分鐘）。
    ///   - offline: `roots` 裡這一刻讀不到的那幾個。它們不會被送進索引器。
    public func current(roots: [URL], offline: [URL] = []) -> Snapshot {
        hydrate()
        applyRootChange(roots)
        let cameBack = applyOfflineChange(offline)

        let sinceLast = lastScan.map { now().timeIntervalSince($0) } ?? .infinity
        let stale = sinceLast > Self.rescanInterval
        // 提早重試只對「掃的時候才發現讀不到」有意義。已知離線的根不走這條：
        // 它會讓 isComplete 永遠是 false，每 5 分鐘就把好端端的幾十萬檔本機根目錄
        // 陪著全量重走一遍，而那顆碟仍然沒掛回來。掛回來時 offline 集合會變，
        // cameBack 立刻補一次掃描——比輪詢準也比輪詢早。
        let retryIncomplete = !snapshot.isComplete && offlineRoots.isEmpty
            && sinceLast > Self.incompleteRetryInterval
        if cameBack || stale || retryIncomplete {
            startScan(roots: roots)
        }
        return snapshot
    }

    /// 使用者按「下一張」或改了來源時強制重掃，同樣不阻塞。
    /// 增量的：每個目錄 stat 一次，有變的才重列（以前是全量，SMB 上要四分鐘）。
    public func invalidate(roots: [URL], offline: [URL] = []) {
        hydrate()
        applyRootChange(roots)
        applyOfflineChange(offline)
        lastScan = nil
        startScan(roots: roots)
    }

    /// 本機磁碟的 FSEvents 說這些目錄有動靜（見 DirectoryChangeMonitor）。
    /// 只驗這幾棵子樹，其他根一個都不碰。
    public func directoriesChanged(_ paths: [String]) {
        hydrate()
        guard !paths.isEmpty else { return }
        guard scanTask == nil else {
            pendingScope = (pendingScope ?? []).union(paths)
            return
        }
        startScan(roots: scannedRoots, scope: paths)
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
        snapshot.images = persisted.images
        snapshot.videos = persisted.videos
        // 完整性照抄，不要一律當成完整：磁碟上那份可能是「有根離線時存下的」，
        // 硬當成完整的話影片差異同步會把那顆碟上已部署的影片全當成「已移除」刪掉。
        // 根目錄如果變了，接下來的 applyRootChange 會再把它降級一次。
        snapshot.isComplete = persisted.isComplete
        scannedRoots = persisted.roots.map { URL(filePath: $0, directoryHint: .isDirectory) }
        lastScan = persisted.scannedAt
        lastFullScan = persisted.fullScanAt
        // v1 檔沒有樹：從平面清單重建一棵沒有 mtime 的，下一輪會整棵重列（等於一次全量），
        // 但離線根的檔案從第一秒就在樹裡，不會因為「沒掃到」而被丟掉。
        tree = persisted.tree
            ?? DirectoryTree(images: persisted.images, videos: persisted.videos, roots: persisted.roots)
    }

    /// 編碼與寫檔丟到 actor 外面做：一份 90 萬路徑的清單編起來不便宜，
    /// 佔著 actor 會讓下一輪 current 排在後面等。
    private func persist() {
        // **不完整的也要存**，把完整性一起寫進去。
        //
        // 之前是「只存完整的那份」，理由是 hydrate 會把存下來的當成完整清單。
        // 代價是：只要有一個來源長期離線（NAS 關著、外接碟沒插），索引就永遠
        // 不落地，每次冷啟動都全量重掃——90 萬檔 4.2 分鐘，而那顆碟的內容
        // 明明還在清單裡。hydrate 改成照抄旗標之後，這個理由就不成立了。
        guard let store else { return }
        // 清單本來就是路徑字串，這裡不必再轉一次（以前 90 萬項就是 90 萬次
        // 字串配置）。[String] 是 CoW 的 Sendable，capture 本身不拷貝。
        let roots = scannedRoots
        let scannedAt = lastScan ?? now()
        let images = snapshot.images
        let videos = snapshot.videos
        let isComplete = snapshot.isComplete
        let tree = tree
        let fullScanAt = lastFullScan
        Task.detached(priority: .utility) {
            let payload = PersistedFolderIndex(
                roots: roots.map { $0.path(percentEncoded: false) },
                scannedAt: scannedAt,
                images: images,
                videos: videos,
                isComplete: isComplete,
                tree: tree,
                fullScanAt: fullScanAt
            )
            store.save(payload)
        }
    }

    /// 根目錄變動時先就地修正快取，別讓已移除的資料夾還留在池裡。
    private func applyRootChange(_ roots: [URL]) {
        guard Self.changed(roots, from: scannedRoots) else {
            // 路徑一樣但**表示法**可能不同：從磁碟撈回來的根目錄帶結尾斜線，
            // 書籤解出來的沒有，直接比 URL 會判成「換了根目錄」而每次冷啟動都重掃。
            // 統一成呼叫端給的那份，後面 commit 的比對才對得上。
            scannedRoots = roots
            return
        }

        let removedOnly = Set(roots).isSubset(of: Set(scannedRoots))
        // RootMatcher 把根目錄路徑先算好：逐項重新 standardize 的寫法在 68 萬筆上
        // 實測要 4.39 秒，而這裡佔著 actor，會讓下一輪 current 排隊等。
        let matcher = RootMatcher(roots)
        snapshot.images = snapshot.images.filter { matcher.root(ofPath: $0) != nil }
        snapshot.videos = snapshot.videos.filter { matcher.root(ofPath: $0) != nil }
        tree.removeAll(outside: roots.map(Self.normalized))

        // 只移除的話，篩過的清單仍然是完整的——影片同步可以立刻把該刪的刪掉。
        // 只要新增了根目錄，清單就不完整，同步得等重掃。
        snapshot.isComplete = removedOnly && snapshot.isComplete
        scannedRoots = roots
        lastScan = nil
    }

    /// 記下這一輪哪些根離線。
    ///
    /// 離線**不等於**被移除，兩者不能走同一條路：移除要把檔案從池裡篩掉並落地，
    /// 離線只是這一刻讀不到——檔案還在那顆碟上，清單要留著。
    ///
    /// - Returns: 有沒有根目錄從離線回到線上。那才需要重掃：那顆碟拔掉的期間
    ///   內容可能已經變了，而且掛回來的第一時間就該補，不必等節流到期。
    @discardableResult
    private func applyOfflineChange(_ offline: [URL]) -> Bool {
        let before = Set(Self.pathList(offlineRoots))
        let after = Set(Self.pathList(offline))
        offlineRoots = offline
        // 只要有根離線，這份清單就不涵蓋所有來源。這件事不能等掃描回報——
        // 掃描根本不會去碰離線的根，而 isComplete 留著 true 的話，影片差異同步
        // 會把那顆碟上已部署的影片全當成「已移除」刪掉（見 VideoLibrary.sync）。
        if !offline.isEmpty { snapshot.isComplete = false }
        return !before.subtracting(after).isEmpty
    }

    /// 比對根目錄只看標準化後的路徑字串，不看 URL 本身。
    ///
    /// 還要自己剝掉結尾斜線：`path(percentEncoded:)` 會**保留**它
    /// （跟已棄用的 `.path` 不同），所以 `/a/` 與 `/a` 會比成兩個不同的根目錄。
    private static func normalized(_ url: URL) -> String {
        DirectoryTree.key(for: url)
    }

    private static func pathList(_ urls: [URL]) -> [String] {
        urls.map(normalized)
    }

    /// 這兩份根目錄清單是不是**不同的一組**。
    ///
    /// 比集合而不是比有序陣列。呼叫端給的順序是會變的——`folders + offlineFolders`
    /// 在某個根離線時會把它從原位移到尾巴，同一組根換個順序就被判成「換了根目錄」，
    /// 於是 `lastScan = nil`、70 萬檔全量重掃一次。NAS 每掉一次線就是四分鐘。
    private static func changed(_ lhs: [URL], from rhs: [URL]) -> Bool {
        Set(pathList(lhs)) != Set(pathList(rhs))
    }

    /// - Parameter scope: nil＝整棵樹增量驗一次（到期或使用者要求）；非 nil＝只驗 FSEvents 點名的子樹。
    private func startScan(roots: [URL], scope: [String]? = nil) {
        guard scanTask == nil else { return }   // 上一輪還在走就別疊上去

        // 離線的根連問都不要問。呼叫端解析書籤時已經確認過列不出第一層，
        // 再叫掃描器走一趟，只是對著沒掛載的網路磁碟再等一次逾時。
        let offlinePaths = Set(Self.pathList(offlineRoots))
        let live = roots.filter { !offlinePaths.contains(Self.normalized($0)) }

        guard !live.isEmpty else {
            // 一個都掃不動時**不清空清單**：全部的根都離線的話，檔案還在那些碟上，
            // 只是這一刻讀不到（理由同 commit 裡的沿用那段）。isComplete 已由
            // applyOfflineChange 壓成 false。
            if offlineRoots.isEmpty {
                // 真的零資料夾：清單就是空的，而且是完整的空。
                snapshot.images = []
                snapshot.videos = []
                snapshot.isComplete = true
                tree = DirectoryTree()
            }
            snapshot.isScanning = false
            lastScan = now()
            persist()
            return
        }

        let fullDue = lastFullScan.map { now().timeIntervalSince($0) > Self.fullRescanInterval } ?? true
        let full = scope == nil && fullDue
        let previous = tree
        let liveKeys = live.map(Self.normalized)
        snapshot.isScanning = true
        scanStartedAt = now()
        scanTask = Task { [scanner] in
            let scan = await scanner.scan(previous: previous, roots: liveKeys,
                                          scope: scope, relistAll: full)
            // Task 已在 FolderIndex actor 上跑，commit 是 actor 隔離方法，不必再 await。
            self.commit(scan, roots: roots, scope: scope, full: full)
        }
    }

    private func commit(_ scan: TreeScan, roots: [URL], scope: [String]?, full: Bool) {
        scanTask = nil
        snapshot.isScanning = false
        let finished = now()
        lastScan = finished
        if full { lastFullScan = finished }
        let elapsed = scanStartedAt.map { finished.timeIntervalSince($0) } ?? 0

        // 掃到一半使用者又改了來源 → 這批結果不算數，直接重來。
        // 同樣比集合：順序變了不代表來源變了（見 changed(_:from:)）。
        guard !Self.changed(roots, from: scannedRoots) else {
            startScan(roots: scannedRoots)
            return
        }

        // 有根目錄打不開（NAS 沒掛、磁碟拔掉）或這輪根本沒送去掃（已知離線）：
        // **留著上一輪的子樹**，並且不准宣稱清單完整。
        //
        // 少了這段，把 NAS 拔掉再開 App 就會：掃描回空清單 → isComplete = true
        // → 影片差異同步認定所有影片都被移除 → 把 extension container 裡的全刪掉。
        // TreeScanner 對讀不到的根已經沿用了；這裡補的是已知離線、沒送進去的那些。
        var next = scan.tree
        let unreadable = scan.unreadableRoots + Self.pathList(offlineRoots)
        for root in unreadable where next.directories[root] == nil {
            next.copySubtree(of: root, from: tree)
        }

        // 什麼都沒變（最常見：15 分鐘到期、整棵 stat 過一遍）就不必攤平、排序、落地 90 萬項。
        let contentChanged = full || scan.listedDirectories > 0 || next != tree
        let wasEmpty = snapshot.images.isEmpty && snapshot.videos.isEmpty
        let wasComplete = snapshot.isComplete
        tree = next
        if contentChanged {
            (snapshot.images, snapshot.videos) = tree.flattened()
        }
        // 局部掃描只碰範圍內的根：範圍外（例如逾時的 SMB）是原封沿用，不能據此宣稱完整。
        // isComplete 在有 scope 時只能維持或降低。
        if scope == nil {
            snapshot.isComplete = unreadable.isEmpty
        } else if !unreadable.isEmpty {
            snapshot.isComplete = false
        }
        let becameComplete = scope == nil && !wasComplete && snapshot.isComplete
        let completenessChanged = snapshot.isComplete != wasComplete

        Self.log.info("""
            索引\(full ? "全量" : (scope == nil ? "增量" : "局部"), privacy: .public)掃描：\
            驗 \(scan.checkedDirectories) 個目錄、重列 \(scan.listedDirectories) 個，\
            \(elapsed, format: .fixed(precision: 2)) 秒
            """)
        if !unreadable.isEmpty {
            Self.log.notice(
                "\(unreadable.count) 個根目錄讀不到，沿用上一輪清單、不標記完整")
        }

        // 完整↔不完整也要落地：內容沒變時以前會跳過，冷啟動會 hydrate 成過期的完整旗標。
        if contentChanged || becameComplete || full || completenessChanged { persist() }
        // FSEvents 的局部掃描不回呼：使用者存一張圖、桌布就重合成，看起來像桌布亂跳。
        // 新檔案照樣進了池，下一輪排程自然抽得到。池原本是空的、或清單剛變完整
        // （影片同步在等這個）時例外。
        if scope == nil || wasEmpty || becameComplete { onScanCompleted?() }

        if let pending = pendingScope {
            pendingScope = nil
            startScan(roots: scannedRoots, scope: Array(pending))
        }
    }
}
