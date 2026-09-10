//  VideoSourceProfile.swift
//  「這支影片長什麼樣」的共用描述，以及播放事件紀錄。
//
//  **兩個 target 各自編譯這一份**（見 project.yml）。所以這裡只有純資料與
//  純函式：怎麼從 `AVAsset` 把欄位填出來是各引擎自己的事，AVFoundation
//  不出現在這個檔裡。
//
//  為什麼需要它：使用者的回報是「有些片正常、有些會抖」，而現在兩條引擎
//  能講出來的只有「播失敗了」跟「等太久」。抖動至少有四種成因——幀率與
//  螢幕更新率不匹配、讀取或解碼跟不上、循環接縫、政策變速——不先把片源
//  的事實記下來，就只能在這四種之間猜。
//
//  **拿不到的欄位一律留 nil，不要用預設值頂替。** 這裡的重點是分辨
//  「量到是這樣」與「沒量到」；把沒量到的當成 0 或 false，診斷報告就會
//  自信地指向錯的方向。

import Foundation

/// 一支片源的事實。基礎欄位在部署／首次播放時填，`timing` 只在診斷模式或
/// 問題片源才跑（那要把整條軌道的時間戳走一遍，成本不是每支都該付的）。
public struct VideoSourceProfile: Codable, Sendable, Equatable {

    // MARK: 來源

    /// 穩定識別：本機檔用標準化路徑，遠端用 absoluteString。
    public var sourceKey: String
    /// 檔案大小。連同 `contentModified` 一起當「這份分析還算不算數」的依據。
    public var fileSize: Int64?
    public var contentModified: Date?
    /// 這支是不是在本機磁碟上。NAS、雲端掛載點、http 串流都是 false。
    public var isLocal: Bool?

    // MARK: 影像

    /// 編碼的 FourCC，例如 `avc1`、`hvc1`。
    public var codec: String?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// **套過 preferredTransform 之後**的顯示尺寸。直拍的手機影片
    /// naturalSize 是橫的，用原始尺寸算長寬比會反過來。
    public var displayWidth: Double?
    public var displayHeight: Double?
    public var rotationDegrees: Int?
    public var bitDepth: Int?
    public var isHDR: Bool?
    public var colorPrimaries: String?
    public var transferFunction: String?
    /// 位元率（bits/sec）。
    public var estimatedDataRate: Double?

    // MARK: 時間

    /// 容器**宣告**的幀率。實際時間戳間隔在 `timing` 裡，兩者不一定一致。
    public var nominalFrameRate: Double?
    public var minFrameDurationSeconds: Double?
    /// 影片軌的呈現起點。**不保證是 0**，非零起點是循環接縫錯位的常見成因。
    public var trackStartSeconds: Double?
    public var trackDurationSeconds: Double?
    /// 容器宣告的長度。跟 `trackDurationSeconds` 對不上就表示有音軌比影像軌長之類的事。
    public var containerDurationSeconds: Double?

    // MARK: 深入分析

    public var timing: TimingAnalysis?

    /// 走過整條軌道的時間戳之後才知道的事。
    public struct TimingAnalysis: Codable, Sendable, Equatable {
        public var sampleCount: Int
        /// 呈現順序上相鄰兩格的間隔。**不是解碼順序**——有 B-frame 時那個差值沒有意義。
        public var minIntervalSeconds: Double?
        public var medianIntervalSeconds: Double?
        public var maxIntervalSeconds: Double?
        /// 間隔不只一種。
        public var isVariableFrameRate: Bool
        /// 有幾格的 sample 自己沒帶長度。
        public var samplesMissingDuration: Int
        /// 有幾格的 PTS 比前一格小——解碼順序裡這是正常的 B-frame，
        /// 呈現順序裡出現就是壞掉的時間戳。這裡記的是**呈現順序**的。
        public var nonMonotonicPresentationCount: Int
        /// 解碼順序與呈現順序不同（有 B-frame）。
        public var hasBFrames: Bool
        public var firstPresentationSeconds: Double?
        public var lastPresentationEndSeconds: Double?

        public init(
            sampleCount: Int = 0,
            minIntervalSeconds: Double? = nil,
            medianIntervalSeconds: Double? = nil,
            maxIntervalSeconds: Double? = nil,
            isVariableFrameRate: Bool = false,
            samplesMissingDuration: Int = 0,
            nonMonotonicPresentationCount: Int = 0,
            hasBFrames: Bool = false,
            firstPresentationSeconds: Double? = nil,
            lastPresentationEndSeconds: Double? = nil
        ) {
            self.sampleCount = sampleCount
            self.minIntervalSeconds = minIntervalSeconds
            self.medianIntervalSeconds = medianIntervalSeconds
            self.maxIntervalSeconds = maxIntervalSeconds
            self.isVariableFrameRate = isVariableFrameRate
            self.samplesMissingDuration = samplesMissingDuration
            self.nonMonotonicPresentationCount = nonMonotonicPresentationCount
            self.hasBFrames = hasBFrames
            self.firstPresentationSeconds = firstPresentationSeconds
            self.lastPresentationEndSeconds = lastPresentationEndSeconds
        }
    }

    /// 這支已經產過的最佳化版本。沒有就是 nil——**預設不轉碼**。
    public var optimizedVariant: OptimizedVariant?

    public struct OptimizedVariant: Codable, Sendable, Equatable {
        /// 相對於片源目錄的檔名。
        public var filename: String
        public var reason: OptimizationReason
        public var pixelWidth: Int?
        public var pixelHeight: Int?
        public var fileSize: Int64?
        public var createdAt: Date

        public init(filename: String, reason: OptimizationReason, pixelWidth: Int? = nil,
                    pixelHeight: Int? = nil, fileSize: Int64? = nil, createdAt: Date = .now) {
            self.filename = filename
            self.reason = reason
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.fileSize = fileSize
            self.createdAt = createdAt
        }
    }

    /// 為什麼替這支產最佳化版本。**不插幀、不統一幀率**——那會讓正常片源變差。
    public enum OptimizationReason: String, Codable, Sendable {
        /// 解析度遠超過螢幕，解碼與合成都在做白工。
        case oversizedResolution
        /// 編碼相容性差（軟解、少見的 profile）。
        case codecCompatibility
        /// 時間戳異常，重寫容器把它整平。
        case timestampRepair
    }

    public var analyzedAt: Date?

    public init(sourceKey: String) {
        self.sourceKey = sourceKey
    }

    // MARK: - 衍生

    /// 顯示用的長寬比（寬÷高，已套旋轉）。量不到就 nil。
    public var displayAspect: Double? {
        guard let width = displayWidth, let height = displayHeight,
              width > 0, height > 0, width.isFinite, height.isFinite else { return nil }
        return width / height
    }

    /// 實際量到的幀率。沒跑過深入分析就退回容器宣告的那個。
    public var effectiveFrameRate: Double? {
        if let median = timing?.medianIntervalSeconds, median > 0 { return 1.0 / median }
        if let nominal = nominalFrameRate, nominal > 0 { return nominal }
        return nil
    }

    /// 這份分析還算不算數：檔案大小或修改時間變了就得重跑。
    public func isFresh(fileSize: Int64?, contentModified: Date?) -> Bool {
        guard analyzedAt != nil else { return false }
        if let recorded = self.fileSize, let current = fileSize, recorded != current { return false }
        if let recorded = self.contentModified, let current = contentModified,
           abs(recorded.timeIntervalSince(current)) > 1 { return false }
        return true
    }
}

/// 「這支為什麼可能抖」的分類。**每一項都是待查方向，不是結論。**
public enum PlaybackRisk: String, Codable, Sendable, CaseIterable {
    /// 幀率與螢幕更新率不整除：24 fps 播在 60 Hz 上就是 2-3 pulldown，
    /// 規律微頓，跟播放器沒有關係。
    case refreshCadenceMismatch
    /// 幀率高過螢幕更新率，一定有格被丟掉。
    case frameRateAboveRefresh
    /// 可變幀率。
    case variableFrameRate
    /// 有格沒帶長度，循環終點只能用推導的。
    case missingSampleDurations
    /// 影片軌起點不是 0，循環接縫容易錯位。
    case nonZeroTimelineStart
    /// 呈現順序的時間戳不單調——壞掉的時間戳。
    case nonMonotonicTimestamps
    /// 解碼負載高（解析度、位元率）。
    case highDecodeLoad
    /// 片源不在本機，讀取本身就可能斷續。
    case remoteSource
    /// HDR，多一道色調映射。
    case hdrTonemapping
    /// 時間資訊根本沒量到——**不要把這個當成「沒問題」。**
    case unknownTiming

    // 說明文字在 `PlaybackRiskText.swift`——那個檔只給 FoldwallCore 編，
    // 因為它要用 `Bundle.foldwallCore` 的字串表，而 appex 沒有那份。
    // 這個檔本身兩個 target 各編一份，所以只能有純資料。
}

public extension VideoSourceProfile {

    /// 螢幕更新率與幀率的比值離整數多遠才算不匹配。
    /// 59.94 對 29.97 這種要當成匹配，所以容差不能太小。
    static let cadenceTolerance = 0.05

    /// 解析度超過這個畫素量就算高負載（約 4K）。
    static let highLoadPixelCount = 3840 * 2160
    /// 位元率超過這個就算高負載（40 Mbps）。
    static let highLoadDataRate: Double = 40_000_000

    /// 這支在這台螢幕上有哪些待查方向。
    ///
    /// - Parameter screenRefreshHz: 螢幕更新率。不知道就傳 nil，
    ///   那時不會產生節奏相關的分類（而不是假設 60）。
    func risks(screenRefreshHz: Double?) -> [PlaybackRisk] {
        var found: [PlaybackRisk] = []

        if let fps = effectiveFrameRate, fps > 0, let refresh = screenRefreshHz, refresh > 0 {
            if fps > refresh * (1 + Self.cadenceTolerance) {
                found.append(.frameRateAboveRefresh)
            } else {
                let ratio = refresh / fps
                let nearest = (ratio).rounded()
                if nearest >= 1, abs(ratio - nearest) > Self.cadenceTolerance {
                    found.append(.refreshCadenceMismatch)
                }
            }
        }

        if let timing {
            if timing.isVariableFrameRate { found.append(.variableFrameRate) }
            if timing.samplesMissingDuration > 0 { found.append(.missingSampleDurations) }
            if timing.nonMonotonicPresentationCount > 0 { found.append(.nonMonotonicTimestamps) }
        } else if effectiveFrameRate == nil {
            found.append(.unknownTiming)
        }

        if let start = trackStartSeconds, start > 0 { found.append(.nonZeroTimelineStart) }

        let pixels = (pixelWidth ?? 0) * (pixelHeight ?? 0)
        if pixels > Self.highLoadPixelCount
            || (estimatedDataRate ?? 0) > Self.highLoadDataRate {
            found.append(.highDecodeLoad)
        }

        if isLocal == false { found.append(.remoteSource) }
        if isHDR == true { found.append(.hdrTonemapping) }

        return found
    }
}

// MARK: - 播放事件

/// 一則播放事件。兩條引擎記同一種格式，報告才拼得起來。
public struct PlaybackEvent: Codable, Sendable, Equatable {

    public enum Kind: String, Codable, Sendable {
        /// 開始準備一支片。
        case started
        /// 第一格真的出現在畫面上。
        case firstFrame
        /// 想播但沒資料。
        case stalled
        /// 從 `stalled` 回來。
        case resumed
        /// 換到另一支。
        case switched
        /// 同一支循環一輪。
        case loopBoundary
        /// 省電／遮擋政策改變。
        case policyChanged
        /// 播不動。
        case failed
        /// 從錯誤恢復。
        case recovered
        /// 資源釋放（深度暫停、surface 收掉）。
        case released
    }

    public var kind: Kind
    /// 引擎識別：`VideoEngine` 的 rawValue。**用字串不是列舉**——
    /// appex 不連結 FoldwallCore，拿不到那個型別。
    public var engine: String
    /// 螢幕 UUID（桌面視窗）或 surface key（extension）。
    public var surface: String
    /// 播放 session 序號。過期的回呼帶的是舊序號，報告裡看得出來。
    public var session: Int
    /// 片源識別。
    public var sourceKey: String?
    /// 當下的政策。
    public var policy: String?
    public var at: Date
    /// 補充說明。失敗原因、停頓長度之類。
    public var detail: String?

    public init(kind: Kind, engine: String, surface: String, session: Int,
                sourceKey: String? = nil, policy: String? = nil,
                at: Date = .now, detail: String? = nil) {
        self.kind = kind
        self.engine = engine
        self.surface = surface
        self.session = session
        self.sourceKey = sourceKey
        self.policy = policy
        self.at = at
        self.detail = detail
    }
}

/// 有上限的事件環狀緩衝。
///
/// **有上限**是重點：桌布是跑一整天的東西，無上限的紀錄就是記憶體洩漏
/// 換一份沒人看的日誌。舊的擠掉，報告只涵蓋最近這段。
public struct PlaybackEventLog: Sendable {

    public static let defaultCapacity = 512

    public let capacity: Int
    private var events: [PlaybackEvent] = []
    /// 因為容量上限被擠掉幾則。報告要標出來，不然會誤以為看到的是全部。
    public private(set) var droppedCount = 0

    public init(capacity: Int = defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public mutating func record(_ event: PlaybackEvent) {
        events.append(event)
        if events.count > capacity {
            let excess = events.count - capacity
            events.removeFirst(excess)
            droppedCount += excess
        }
    }

    public var all: [PlaybackEvent] { events }

    public func events(surface: String) -> [PlaybackEvent] {
        events.filter { $0.surface == surface }
    }

    public mutating func clear() {
        events.removeAll(keepingCapacity: true)
        droppedCount = 0
    }

    /// 每種事件各幾則。
    public var counts: [PlaybackEvent.Kind: Int] {
        events.reduce(into: [:]) { $0[$1.kind, default: 0] += 1 }
    }

    /// 停頓總時長：每個 `stalled` 配對到後面第一個 `resumed`（同一個 surface）。
    /// 沒配到的（還在停頓中、或中間換片了）不計入，並回報有幾個沒配到。
    public func stallSummary(surface: String) -> (count: Int, totalSeconds: TimeInterval, unmatched: Int) {
        var total: TimeInterval = 0
        var matched = 0
        var unmatched = 0
        var pending: Date?
        for event in events where event.surface == surface {
            switch event.kind {
            case .stalled:
                if pending != nil { unmatched += 1 }
                pending = event.at
            case .resumed:
                if let start = pending {
                    total += event.at.timeIntervalSince(start)
                    matched += 1
                    pending = nil
                }
            case .switched, .failed, .released:
                if pending != nil { unmatched += 1; pending = nil }
            default:
                break
            }
        }
        if pending != nil { unmatched += 1 }
        return (matched, total, unmatched)
    }
}
