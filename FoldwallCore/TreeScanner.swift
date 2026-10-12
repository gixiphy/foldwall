//  TreeScanner.swift
//  全量、增量、限定範圍三種掃描共用同一套演算法：
//
//  對每個目錄先量 mtime → 跟上一輪一樣就沿用舊紀錄、繼續往下驗子目錄；
//  不一樣（或上一輪沒有）才重列。全量掃描＝上一輪是空的樹，或 `relistAll`。
//
//  目錄之間平行：同時最多 `width` 個目錄在讀。阻塞的系統呼叫丟到專用的 queue，
//  不佔 Swift 並行池——SMB 上一次 stat 可能卡上百毫秒，佔著協作執行緒會餓死別的工作。

import Foundation
import UniformTypeIdentifiers

public struct TreeScan: Sendable, Equatable {
    public var tree: DirectoryTree
    /// 這輪讀不完整的根：根本打不開，或底下有目錄這一刻讀不到（逾時、I/O 錯誤）。
    /// 讀不到的那幾棵子樹沿用上一輪的內容，但清單不能宣稱完整。
    public var unreadableRoots: [String]
    /// 實際重列了幾個目錄。0＝檔名清單跟上一輪一模一樣。
    public var listedDirectories: Int
    /// 驗過幾個目錄（重列＋只 stat 的）。
    public var checkedDirectories: Int

    public init(tree: DirectoryTree, unreadableRoots: [String],
                listedDirectories: Int, checkedDirectories: Int) {
        self.tree = tree
        self.unreadableRoots = unreadableRoots
        self.listedDirectories = listedDirectories
        self.checkedDirectories = checkedDirectories
    }
}

public protocol DirectoryTreeScanning: Sendable {
    /// - Parameters:
    ///   - previous: 上一輪的樹。空的就等於全量掃描。
    ///   - roots: 這輪要走的根（`DirectoryTree.key(for:)` 的形式）。離線的根不要放進來。
    ///   - scope: 只驗這些目錄的子樹（FSEvents 回報的）；範圍外的原封沿用。nil＝整棵樹。
    ///     範圍裡**正好點名**的目錄一律重列：FSEvents 說它動了，可能是原地改檔，mtime 不會變。
    ///   - relistAll: 不信任 mtime，每個目錄都重列（定期的全量校正）。
    func scan(previous: DirectoryTree, roots: [String], scope: [String]?,
              relistAll: Bool) async -> TreeScan
}

public struct TreeScanner: DirectoryTreeScanning {

    public typealias Reader = @Sendable (String) throws(DirectoryReadError) -> [DirectoryEntry]
    public typealias Stamper = @Sendable (String) throws(DirectoryReadError) -> TimeInterval
    public typealias DeviceReader = @Sendable (String) throws(DirectoryReadError) -> UInt64

    /// 同時在讀的目錄數。本機 SSD 實測 4 條就飽和（12 萬項：單執行緒 0.82 s → 0.34 s）；
    /// SMB 靠並行把網路往返疊起來，8 是保守的起點——在 NAS 上量過再調（見 ScanBenchmark）。
    public static let defaultWidth = 8

    /// 目錄 mtime 離現在不到這麼久，就當成「還在變」：下一輪一定重列。
    /// 有些伺服器的 mtime 只到秒（FAT 甚至 2 秒），同一秒內再加檔 mtime 不會變。
    static let settleWindow: TimeInterval = 2

    private static let ioQueue = DispatchQueue(
        label: "app.foldwall.tree-scan", qos: .utility, attributes: .concurrent)

    private let width: Int
    private let reader: Reader
    private let stamper: Stamper
    private let deviceReader: DeviceReader
    private let now: @Sendable () -> Date

    public init(
        width: Int = Self.defaultWidth,
        reader: @escaping Reader = BulkDirectoryReader.read,
        stamper: @escaping Stamper = BulkDirectoryReader.modificationTime,
        deviceReader: @escaping DeviceReader = BulkDirectoryReader.device,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.width = max(1, width)
        self.reader = reader
        self.stamper = stamper
        self.deviceReader = deviceReader
        self.now = now
    }

    struct Job: Sendable {
        var path: String
        var root: String
        var previous: IndexedDirectory?
        /// 父目錄剛列出來時順手拿到的 mtime：有它就不必再 stat 一次。
        var knownModified: TimeInterval?
        /// 只是範圍的祖先：不必驗，沿用舊紀錄往下走到範圍就好。
        var passThrough: Bool
        var forceList: Bool
    }

    enum Outcome: Sendable {
        case kept(Job, IndexedDirectory, rootIsMountPoint: Bool?)
        case listed(Job, IndexedDirectory, childModified: [String: TimeInterval], rootIsMountPoint: Bool?)
        /// ENOENT／ENOTDIR：真的不在了。
        case gone(Job)
        /// 其他錯誤：這一刻讀不到，不等於被刪（只還原子樹那一截）。
        case failed(Job)
        /// 根看起來像卸載後的空掛載點（先前是掛載點、這次不是了）：整棵根沿用上一輪。
        case vacated(Job)
    }

    public func scan(previous: DirectoryTree, roots: [String], scope: [String]?,
                     relistAll: Bool) async -> TreeScan {
        var tree = DirectoryTree()
        var unreadable: Set<String> = []
        var listed = 0
        var checked = 0
        // 巢狀的根會從兩條路走到同一個目錄，只排一次
        var planned: Set<String> = []
        var pending: [Job] = []
        let scopes = scope.map(ScanScope.init)

        func plan(_ path: String, root: String, knownModified: TimeInterval?) {
            guard planned.insert(path).inserted else { return }
            let record = previous.directories[path]
            if let scopes, let record, !scopes.covers(path) {
                if scopes.isAncestor(of: path) {
                    pending.append(Job(path: path, root: root, previous: record,
                                       knownModified: nil, passThrough: true, forceList: false))
                } else {
                    tree.copySubtree(of: path, from: previous)
                }
                return
            }
            pending.append(Job(
                path: path, root: root, previous: record, knownModified: knownModified,
                passThrough: false,
                forceList: relistAll || (scopes?.names(path) ?? false)))
        }

        for root in roots { plan(root, root: root, knownModified: nil) }

        await withTaskGroup(of: Outcome.self) { group in
            var inFlight = 0
            func fill() {
                while inFlight < width, let job = pending.popLast() {
                    inFlight += 1
                    group.addTask { await self.perform(job, previous: previous) }
                }
            }
            fill()
            while let outcome = await group.next() {
                inFlight -= 1
                switch outcome {
                case .kept(let job, let record, let rootIsMountPoint):
                    if !job.passThrough { checked += 1 }
                    tree.directories[job.path] = record
                    if let rootIsMountPoint { tree.rootIsMountPoint[job.root] = rootIsMountPoint }
                    for name in record.subdirectories {
                        plan(DirectoryTree.join(job.path, name), root: job.root, knownModified: nil)
                    }
                case .listed(let job, let record, let childModified, let rootIsMountPoint):
                    checked += 1
                    listed += 1
                    tree.directories[job.path] = record
                    if let rootIsMountPoint { tree.rootIsMountPoint[job.root] = rootIsMountPoint }
                    for name in record.subdirectories {
                        plan(DirectoryTree.join(job.path, name), root: job.root,
                             knownModified: childModified[name])
                    }
                case .gone(let job) where job.path != job.root:
                    break   // 被刪了：整棵子樹都不帶過去
                case .vacated(let job):
                    // 空掛載點：整棵根沿用上一輪，不准宣稱完整。
                    unreadable.insert(job.root)
                    tree.copySubtree(of: job.root, from: previous)
                case .gone(let job), .failed(let job):
                    // 根不見了（NAS 沒掛）或子目錄這一刻讀不到：沿用上一輪，不准宣稱完整。
                    unreadable.insert(job.root)
                    tree.copySubtree(of: job.path, from: previous)
                }
                fill()
            }
        }
        return TreeScan(tree: tree, unreadableRoots: unreadable.sorted(),
                        listedDirectories: listed, checkedDirectories: checked)
    }

    private func perform(_ job: Job, previous: DirectoryTree) async -> Outcome {
        await withCheckedContinuation { continuation in
            Self.ioQueue.async { continuation.resume(returning: self.run(job, previous: previous)) }
        }
    }

    private func run(_ job: Job, previous: DirectoryTree) -> Outcome {
        if job.passThrough, let record = job.previous {
            let flag = job.path == job.root ? previous.rootIsMountPoint[job.root] : nil
            return .kept(job, record, rootIsMountPoint: flag)
        }

        var mountFlag: Bool?
        if job.path == job.root {
            mountFlag = mountPointFlag(of: job.path)
            if mountFlag == nil {
                // 根自己的裝置號都讀不到 → 跟 stamp／list 一樣走錯誤路徑。
                do { _ = try deviceReader(job.path) } catch {
                    return outcome(for: error, job, previous: previous)
                }
            }
            if previous.rootIsMountPoint[job.root] == true, mountFlag == false {
                return .vacated(job)
            }
        }

        let modified: TimeInterval
        if let known = job.knownModified {
            modified = known
        } else {
            do { modified = try stamper(job.path) } catch { return outcome(for: error, job, previous: previous) }
        }
        if !job.forceList, let previousRecord = job.previous, previousRecord.modified == modified {
            return .kept(job, previousRecord, rootIsMountPoint: mountFlag)
        }

        let entries: [DirectoryEntry]
        do { entries = try reader(job.path) } catch { return outcome(for: error, job, previous: previous) }

        var files: [IndexedFile] = []
        var subdirectories: [String] = []
        var childModified: [String: TimeInterval] = [:]
        for entry in entries where !entry.isHidden && !entry.name.hasPrefix(".") {
            switch entry.kind {
            case .directory:
                guard !Self.isPackage(entry.name) else { continue }
                subdirectories.append(entry.name)
                childModified[entry.name] = entry.modified
            case .file, .symlink:
                // 符號連結也收：舊的列舉器只看檔名，連到圖檔的連結一直都在池裡
                if let kind = MediaIndexer.kind(ofName: entry.name) {
                    files.append(IndexedFile(name: entry.name, kind: kind,
                                             size: entry.size, modified: entry.modified))
                }
            case .other:
                continue
            }
        }

        let settled = now().timeIntervalSince1970 - modified > Self.settleWindow
        let record = IndexedDirectory(
            modified: settled ? modified : DirectoryTree.unknownModified,
            files: files, subdirectories: subdirectories)
        return .listed(job, record, childModified: childModified, rootIsMountPoint: mountFlag)
    }

    /// ENOENT／ENOTDIR 通常＝真的刪了；但掃到一半整卷卸載時，根目錄驗過後每個子目錄
    /// 也會回 ENOENT——那時要再看根：根也讀不到、或掛載點降級成普通目錄，就沿用上一輪。
    private func outcome(for error: DirectoryReadError, _ job: Job, previous: DirectoryTree) -> Outcome {
        switch error {
        case .unreadable(let code):
            guard code == ENOENT || code == ENOTDIR else { return .failed(job) }
            guard job.path != job.root else { return .gone(job) }
            if rootLooksVacated(job.root, previous: previous) { return .vacated(job) }
            return .gone(job)
        }
    }

    /// 掛載點降級（上次是、這次不是），或根現在根本讀不到（掃到一半整卷沒了）。
    private func rootLooksVacated(_ root: String, previous: DirectoryTree) -> Bool {
        switch mountPointFlag(of: root) {
        case false? where previous.rootIsMountPoint[root] == true:
            return true
        case true?, false?:
            return false
        case nil:
            // 根／父目錄讀不到：不是「子目錄被刪」，沿用上一輪。
            return true
        }
    }

    /// `st_dev(根) != st_dev(父目錄)` → 掛載點。讀不到時回 nil（缺旗標／暫時錯誤，不得誤判降級）。
    private func mountPointFlag(of path: String) -> Bool? {
        guard let parent = Self.parentDirectory(of: path) else { return false }
        do {
            let rootDevice = try deviceReader(path)
            let parentDevice = try deviceReader(parent)
            return rootDevice != parentDevice
        } catch {
            return nil
        }
    }

    static func parentDirectory(of path: String) -> String? {
        if path == "/" { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    /// 比照 `.skipsPackageDescendants`：`.photoslibrary`、`.app` 這類套件不往裡走。
    /// 只看副檔名（查 UTType 不碰磁碟）；舊列舉器還看 Finder 的 bundle bit，那種情況極少見。
    ///
    /// `conformingTo: .directory` 不能省：預設是 `.data`，那樣連 `.app` 都判不成套件（實測）。
    static func isPackage(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext, conformingTo: .directory) else { return false }
        return type.conforms(to: .package)
    }
}

/// FSEvents 回報的範圍。數量是個位數到幾十個，線性比對就夠了。
struct ScanScope: Sendable {
    let paths: Set<String>

    init(_ paths: [String]) {
        self.paths = Set(paths.map {
            $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0
        })
    }

    /// 這個目錄被點名了，或在某個被點名的目錄底下。
    func covers(_ path: String) -> Bool {
        paths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// 這個目錄是某個被點名目錄的祖先：要經過它才走得到範圍。
    func isAncestor(of path: String) -> Bool {
        paths.contains { $0.hasPrefix(path + "/") }
    }

    func names(_ path: String) -> Bool { paths.contains(path) }
}

/// 把只會全量掃描的 `MediaIndexing` 接到樹狀介面上。
///
/// 只給既有測試與舊呼叫端用：它沒有 mtime，所以每一輪都等於全量。
struct LegacyIndexerScanner: DirectoryTreeScanning {
    let indexer: any MediaIndexing

    func scan(previous: DirectoryTree, roots: [String], scope: [String]?,
              relistAll: Bool) async -> TreeScan {
        let result = await indexer.scan(
            roots: roots.map { URL(filePath: $0, directoryHint: .isDirectory) })
        let unreadable = result.unreadableRoots.map(DirectoryTree.key(for:))
        var images: [String] = []
        var videos: [String] = []
        for item in result.items {
            let path = item.url.path(percentEncoded: false)
            switch item.kind {
            case .image: images.append(path)
            case .video: videos.append(path)
            }
        }
        var tree = DirectoryTree(images: images, videos: videos,
                                 roots: roots.filter { !unreadable.contains($0) })
        for root in unreadable { tree.copySubtree(of: root, from: previous) }
        return TreeScan(tree: tree, unreadableRoots: unreadable.sorted(),
                        listedDirectories: tree.directories.count,
                        checkedDirectories: tree.directories.count)
    }
}
