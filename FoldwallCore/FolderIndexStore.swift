//  FolderIndexStore.swift
//  把資料夾索引寫到磁碟，讓冷啟動不必從零重掃。
//
//  為什麼需要：FolderIndex 的快取只活在記憶體裡，App 一關就沒了。下次開啟
//  `lastScan` 是 nil，於是全量重掃——一座 90 萬檔的 SMB 相簿要 4.2 分鐘，
//  這段期間資料夾池是空的，桌布只能靠網路／相簿來源撐著。
//
//  存的是**路徑清單**，不是檔案內容。清單不小——實測 69 萬個檔的相簿，
//  未壓縮的 binary plist 是 127 MB（CJK 目錄名一個字 3 bytes）——所以再壓一層 zlib，
//  落到 6.9 MB。路徑之間共用大量前綴，zlib 吃這種資料特別有效率（實測 18 倍）。
//  路徑失效（檔案被刪、磁碟沒掛）不必在這裡處理——StillPipeline 抽中讀不到就換一張，
//  背景重掃落地後清單自然收斂。

import Foundation

/// 落地格式。欄位對應 `FolderIndex.Snapshot` 加上「這份是掃哪些根目錄、什麼時候掃的」。
public struct PersistedFolderIndex: Codable, Sendable, Equatable {

    /// 格式版本。對不上就當作沒有快取，重掃一次——
    /// 舊格式硬解出半套資料比重掃四分鐘危險得多。
    public var version: Int
    public var roots: [String]
    public var scannedAt: Date
    public var images: [String]
    public var videos: [String]
    /// 這份清單掃到了每一個根，還是有根當時讀不到（NAS 沒掛、磁碟拔掉）。
    ///
    /// **不完整的也要存。** 之前是「只存完整的」，於是有一個來源長期離線的人
    /// 索引就永遠不落地，每次冷啟動都全量重掃——90 萬檔 4.2 分鐘。存了就得記下
    /// 這件事：不然下次 hydrate 會把不完整的清單當成完整的，影片差異同步會把
    /// 那顆碟上已部署的影片全當成「已移除」刪掉。
    public var isComplete: Bool

    public init(
        version: Int = FolderIndexStore.currentVersion,
        roots: [String], scannedAt: Date, images: [String], videos: [String],
        isComplete: Bool = true
    ) {
        self.version = version
        self.roots = roots
        self.scannedAt = scannedAt
        self.images = images
        self.videos = videos
        self.isComplete = isComplete
    }

    /// 舊檔沒有 `isComplete` 這個鍵。當時的規則是「只存完整的那份」，
    /// 所以缺鍵一律當成完整——不必為了加一個欄位讓所有人重掃四分鐘。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        roots = try c.decode([String].self, forKey: .roots)
        scannedAt = try c.decode(Date.self, forKey: .scannedAt)
        images = try c.decode([String].self, forKey: .images)
        videos = try c.decode([String].self, forKey: .videos)
        isComplete = try c.decodeIfPresent(Bool.self, forKey: .isComplete) ?? true
    }
}

public protocol FolderIndexPersisting: Sendable {
    func load() -> PersistedFolderIndex?
    func save(_ index: PersistedFolderIndex)
}

public struct FolderIndexStore: FolderIndexPersisting {

    public static let currentVersion = 1

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public init(paths: AppPaths = .standard()) {
        self.init(url: paths.folderIndexFile)
    }

    public func load() -> PersistedFolderIndex? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // 解壓失敗就當它本來就是未壓縮的 plist：0.5.1 之前寫下的檔案是那種格式，
        // 讓它照樣讀得出來，下次掃描落地時自然換成壓縮版。
        let plist = ((try? (data as NSData).decompressed(using: .zlib)) as Data?) ?? data
        guard let decoded = try? PropertyListDecoder().decode(PersistedFolderIndex.self, from: plist)
        else { return nil }
        return decoded.version == Self.currentVersion ? decoded : nil
    }

    public func save(_ index: PersistedFolderIndex) {
        // 二進位 plist 而不是 JSON：同一份 90 萬路徑的清單小一截也解得快，
        // 而這個檔只有程式讀，不需要人看得懂。
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let plist = try? encoder.encode(index) else { return }
        // 壓不動就寫原樣：檔案大一點總比整份索引寫不出去、下次重掃四分鐘好。
        let data = ((try? (plist as NSData).compressed(using: .zlib)) as Data?) ?? plist

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // .atomic：寫到一半被砍掉的話，寧可留著上一份完整的舊索引，
        // 也不要留半個檔讓下次解碼失敗、白白重掃。
        try? data.write(to: url, options: .atomic)
    }

    /// 使用者清快取時一併清掉。
    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
