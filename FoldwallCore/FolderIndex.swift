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

    /// 清單不完整、而且**不知道是哪個根出問題**時的重試間隔。
    ///
    /// 呼叫端明講哪幾個根離線時走的不是這條（見 `current(roots:offline:)`）：
    /// 那幾個根要等它掛回來才值得重掃，用計時器輪詢只是對著沒掛載的網路磁碟
    /// 一再撞逾時。這道下限留給「掃到一半才發現讀不到」的情況——
    /// 沒有它就等於**每次 refresh 都全量重走所有根目錄**（含好端端的
    /// 幾十萬檔本機資料夾），而 refresh 的觸發點有二十幾個。
    public static let incompleteRetryInterval: TimeInterval = 5 * 60

    private let indexer: any MediaIndexing
    private let now: @Sendable () -> Date
    private let onScanCompleted: (@Sendable () -> Void)?
    /// nil＝不落地（測試與純記憶體用法）。
    private let store: (any FolderIndexPersisting)?

    private var snapshot = Snapshot()
    private var scannedRoots: [URL] = []
    /// 呼叫端已經確認這一刻讀不到的根（NAS 沒掛、磁碟拔掉、雲端登出）。
    /// 這些根**不送進索引器**，但仍留在 `scannedRoots` 裡——見 `applyOfflineChange`。
    private var offlineRoots: [URL] = []
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
    public func invalidate(roots: [URL], offline: [URL] = []) {
        hydrate()
        applyRootChange(roots)
        applyOfflineChange(offline)
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
        // URL → 路徑字串的轉換（90 萬項就是 90 萬次字串配置）也要移出 actor：
        // [URL] 是 CoW 的 Sendable，capture 本身不拷貝。
        let roots = scannedRoots
        let scannedAt = lastScan ?? now()
        let images = snapshot.images
        let videos = snapshot.videos
        Task.detached(priority: .utility) {
            let payload = PersistedFolderIndex(
                roots: roots.map { $0.path(percentEncoded: false) },
                scannedAt: scannedAt,
                images: images.map { $0.path(percentEncoded: false) },
                videos: videos.map { $0.path(percentEncoded: false) }
            )
            store.save(payload)
        }
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
        // RootMatcher 把根目錄路徑先算好：逐項重新 standardize 的寫法在 68 萬筆上
        // 實測要 4.39 秒，而這裡佔著 actor，會讓下一輪 current 排隊等。
        let matcher = RootMatcher(roots)
        snapshot.images = snapshot.images.filter { matcher.root(of: $0) != nil }
        snapshot.videos = snapshot.videos.filter { matcher.root(of: $0) != nil }

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
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func pathList(_ urls: [URL]) -> [String] {
        urls.map(normalized)
    }

    private func startScan(roots: [URL]) {
        guard scanTask == nil else { return }   // 上一輪還在走就別疊上去

        // 離線的根連問都不要問。呼叫端解析書籤時已經確認過列不出第一層，
        // 再叫索引器走一趟，只是對著沒掛載的網路磁碟再等一次逾時。
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
            }
            snapshot.isScanning = false
            lastScan = now()
            persist()
            return
        }

        snapshot.isScanning = true
        scanTask = Task { [indexer] in
            let scan = await indexer.scan(roots: live)
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

        // 一趟分流，不走兩遍 filter+map——這串在大型來源上是 90 萬項，而且佔著 actor。
        var images: [URL] = []
        var videos: [URL] = []
        images.reserveCapacity(scan.items.count)
        for item in scan.items {
            if item.kind == .image { images.append(item.url) }
            else if item.kind == .video { videos.append(item.url) }
        }

        // 有根目錄打不開（NAS 沒掛、磁碟拔掉）：**留著上一輪掃到的東西**，
        // 並且不准宣稱清單完整。
        //
        // 少了這段，把 NAS 拔掉再開 App 就會：掃描回空清單 → isComplete = true
        // → 影片差異同步認定所有影片都被移除 → 把 extension container 裡的全刪掉。
        // 檔案還好端端在 NAS 上，只是這一刻讀不到而已。
        // 掃到才發現讀不到的，加上一開始就跳過的離線根——對這份清單的意義一樣：
        // 那個根這一輪沒被走過。
        let unreadable = scan.unreadableRoots + offlineRoots
        if !unreadable.isEmpty {
            let matcher = RootMatcher(unreadable)
            images += snapshot.images.filter { matcher.root(of: $0) != nil }
            videos += snapshot.videos.filter { matcher.root(of: $0) != nil }
            Self.log.notice(
                "\(unreadable.count) 個根目錄讀不到，沿用上一輪清單、不標記完整")
        }

        snapshot.images = images
        snapshot.videos = videos
        snapshot.isComplete = unreadable.isEmpty
        persist()
        onScanCompleted?()
    }
}
