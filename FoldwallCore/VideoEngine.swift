//  VideoEngine.swift
//  影片桌布有兩條路，各有取捨。
//
//  **桌面視窗**（預設）：一個 borderless NSWindow 壓在桌面圖示層附近，裡面放
//  AVPlayerLayer。全公開 API，直接播來源檔——不必拷進沙盒 container
//  （實測那條路一輪要從 SMB 拉 470MB，曾佔掉 17GB），整個片庫都能播，
//  遠端 URL 也能直接串流。缺點是**鎖屏不會播**：鎖屏畫面不歸 app 管。
//
//  **系統 extension**：fork 自 Phosphene，dlopen 私有 WallpaperExtensionKit。
//  唯一能讓影片出現在**鎖屏**的路。代價是私有 API 隨時可能斷、要實體拷貝、
//  而且設定要兩步（系統設定選片 ＋ 選單勾此螢幕）。

import Foundation

public enum VideoEngine: String, Codable, Sendable, CaseIterable {
    /// 桌面層級視窗。零拷貝、公開 API、不支援鎖屏。
    case desktopWindow
    /// 系統桌布 extension。支援鎖屏，需拷貝，依賴私有 API。
    case systemExtension

    public var displayName: String {
        switch self {
        case .desktopWindow: "桌面視窗"
        case .systemExtension: "系統桌布 extension"
        }
    }

    public var summary: String {
        switch self {
        case .desktopWindow:
            "直接播來源檔，不拷貝、不佔額外磁碟，整個片庫都能播。全公開 API。**鎖屏不會播。**"
        case .systemExtension:
            "唯一能讓影片出現在**鎖屏**的做法。影片需拷進 extension（受輪替上限管制），"
                + "且要在「系統設定 → 桌布」選片。依賴私有 API，macOS 大版本可能失效。"
        }
    }

    /// 需要把影片實體拷進 extension 的 container 嗎。
    public var needsDeployment: Bool { self == .systemExtension }
    public var supportsLockScreen: Bool { self == .systemExtension }
}

/// 桌面視窗要壓在圖示的上面還是下面。
public enum DesktopVideoLayer: String, Codable, Sendable, CaseIterable {
    /// 桌面圖示仍在影片之上（多數人要的）。
    case belowIcons
    /// 蓋住桌面圖示。
    case aboveIcons

    public var displayName: String {
        switch self {
        case .belowIcons: "在桌面圖示之下"
        case .aboveIcons: "蓋住桌面圖示"
        }
    }
}

/// 一支播完之後怎麼辦。
///
/// 預設 `repeatAll`：**桌布是無人看管的東西**，一支影片放三十秒就把它循環一整天，
/// 整個片庫等於只有一支在用。播完接下一支才是「片庫」該有的行為。
/// 要盯著同一支看的人選 `repeatOne`，那是舊版唯一的行為。
///
/// 只對**桌面視窗**那條路有意義。系統 extension 的輪替由「系統設定 → 桌布」裡
/// Shuffle All 的頻率選單決定（那份 UI 不歸我們畫），見 ShuffleController。
public enum VideoPlaybackMode: String, Codable, Sendable, CaseIterable {
    /// 單片循環：播完接回開頭，永遠是同一支（AVPlayerLooper，無縫）。
    case repeatOne
    /// 全部循環：播完接下一支，走到底回到第一支。
    case repeatAll
    /// 隨機播放：播完隨機挑下一支，不會連著挑到同一支。
    case shuffle

    public var displayName: String {
        switch self {
        case .repeatOne: "單片循環"
        case .repeatAll: "全部循環"
        case .shuffle: "隨機播放"
        }
    }

    public var summary: String {
        switch self {
        case .repeatOne: "一支放到底再接回開頭，永遠是同一支。接回開頭是無縫的。"
        case .repeatAll: "播完接下一支，走到底回到第一支。"
        case .shuffle: "播完隨機挑下一支。下一支不會是剛播完的那支。"
        }
    }

    /// 播完要不要換下一支。
    ///
    /// 這個旗標決定引擎怎麼建 player：`false` 走 AVPlayerLooper（無縫接回開頭、
    /// 收不到播畢通知），`true` 則停在最後一格等上層排下一支。所以**改模式必須重建**
    /// 正在播的那個 player，改旗標對已經在跑的沒有作用。
    public var advancesAtEnd: Bool { self != .repeatOne }
}

/// 哪台螢幕要播哪一支。純邏輯，跟 AppKit 無關，所以測得到。
public enum VideoPlaybackPlan {

    /// - Parameters:
    ///   - screens: 要播影片的螢幕識別碼（已由上層過濾掉沒勾的）。
    ///   - videos: 可用的影片。
    ///   - cycle: 用來決定這一輪從哪一支開始，讓每次喚醒換一批。
    /// - Returns: 螢幕 → 影片。影片不夠時會重複使用，不留空螢幕。
    public static func assign(
        screens: [String], videos: [URL], cycle: Int = 0
    ) -> [String: URL] {
        guard !screens.isEmpty, !videos.isEmpty else { return [:] }
        // 用 absoluteString 排：池裡混著 file:// 與 http(s)://，
        // 而 standardizedFileURL 對遠端 URL 沒有意義。
        let ordered = videos.sorted { $0.absoluteString < $1.absoluteString }

        var plan: [String: URL] = [:]
        for (index, screen) in screens.sorted().enumerated() {
            // 每台螢幕錯開一支，兩螢時不會播到同一部
            plan[screen] = ordered[(cycle + index) % ordered.count]
        }
        return plan
    }

    /// 正在播而且還在池裡的**繼續播**，只補該補的螢幕。
    ///
    /// 為什麼需要這個：`assign` 是 `ordered[(cycle + index) % count]`，位置由池的
    /// **內容**決定。而池每輪都在變——網路影片下載落地、快取淘汰、資料夾索引重掃、
    /// 播放失敗進冷卻——所以就算 `cycle` 一動也沒動，算出來的那支也會變。
    /// 結果是影片跟著蒙太奇每 5 分鐘被換掉重播一次。
    ///
    /// 影片和蒙太奇是**兩條不同節奏**的東西：蒙太奇按間隔輪換，影片只在
    /// 螢幕重新亮起（或使用者動作）時才換一批。要換的時候呼叫端改用 `assign`。
    public static func keeping(
        current: [String: URL], screens: [String], videos: [URL], cycle: Int = 0
    ) -> [String: URL] {
        guard !screens.isEmpty, !videos.isEmpty else { return [:] }
        let available = Set(videos)

        var plan: [String: URL] = [:]
        var used: Set<URL> = []
        var pending: [String] = []

        for screen in screens.sorted() {
            // !used：同一支不能被兩台螢幕同時沿用，那看起來像壞掉
            if let url = current[screen], available.contains(url), !used.contains(url) {
                plan[screen] = url
                used.insert(url)
            } else {
                pending.append(screen)
            }
        }
        guard !pending.isEmpty else { return plan }

        // 沒被沿用的優先分給新螢幕；不夠分時才允許重複。
        let remaining = videos.filter { !used.contains($0) }
        let fresh = assign(screens: pending,
                           videos: remaining.isEmpty ? videos : remaining,
                           cycle: cycle)
        plan.merge(fresh) { _, new in new }
        return plan
    }

    /// 這台螢幕接下來播哪一支：一支播完了，或使用者按了「下一片」。
    ///
    /// 跟 `assign`／`keeping` 是不同的問題。那兩個回答「這一輪整批怎麼分」，
    /// 這個回答「**這一台**要往前一步」——其他螢幕不該被動到，所以只回一支。
    ///
    /// - Parameters:
    ///   - current: 剛播完（或使用者跳過）的那支。`nil`＝這台還沒在播。
    ///   - screen: 螢幕識別碼。隨機模式拿它當 seed 的一部分，兩台同時換片不會撞。
    ///   - videos: 可用的影片。
    ///   - busy: 其他螢幕正在播的。能避就避——兩台播同一支看起來像壞掉。
    ///   - mode: `repeatOne` 走順序（這個模式**不會**因為播完而呼叫這裡，
    ///     只有使用者按「下一片」才會，那時他要的就是往前一步）。
    ///   - nonce: 隨機模式的 seed 來源。同 nonce 同結果，測試才穩。
    /// - Returns: 下一支。池是空的才回 nil，呼叫端維持現狀。
    public static func next(
        after current: URL?,
        screen: String,
        videos: [URL],
        busy: Set<URL> = [],
        mode: VideoPlaybackMode,
        nonce: UInt64 = 0
    ) -> URL? {
        guard !videos.isEmpty else { return nil }
        let ordered = videos.sorted { $0.absoluteString < $1.absoluteString }

        switch mode {
        case .shuffle:
            var generator = SeededGenerator(
                seed: SeededGenerator.seed(cycleNonce: nonce, displayUUID: screen))
            // 不抽剛播完那支（連兩次同一支看起來像卡住），也不抽別台正在播的
            if let pick = ordered.filter({ $0 != current && !busy.contains($0) })
                .randomElement(using: &generator) {
                return pick
            }
            // 池小到沒得挑就退讓：重複好過黑畫面。先讓掉「不撞別台」，
            // 真的只剩一支時連「不重播」也讓掉。
            return ordered.filter { $0 != current }.randomElement(using: &generator)
                ?? current ?? ordered[0]

        case .repeatOne, .repeatAll:
            // 沒在播（或那支已經不在池裡）就從頭；不是 +1，否則第一支永遠被跳過
            let start = current.flatMap { ordered.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            for step in 0..<ordered.count {
                let candidate = ordered[(start + step) % ordered.count]
                if !busy.contains(candidate) { return candidate }
            }
            return ordered[start % ordered.count]
        }
    }
}
