//  SettingsSnapshot.swift
//  一份可以搬到另一台 Mac 的設定。備份／還原與 iCloud 同步都用這個型別。
//
//  **不是 UserDefaults 的鏡像。** 有三個欄位直接複製過去在另一台是廢的：
//
//  1. `folders` 存的是 bookmark，綁著建立它的那台機器。這裡改存**路徑**，
//     另一台用路徑重建。v1 不沙盒、bookmark 也沒有 security scope，做得到。
//  2. `photoAlbums` 存的是 `PHAssetCollection.localIdentifier`，**每台機器不同**，
//     就算兩台連的是同一個 iCloud 圖庫也對不上。這裡連**名稱**一起存，
//     還原時先比 id（同機還原）、比不到再比名稱（跨機）。
//  3. API key 在 Keychain，本來就不在 UserDefaults 裡，也**刻意不收進**這份快照——
//     備份檔是明文 JSON，躺在 iCloud Drive 裡會被 Spotlight 索引。
//     （鑰匙串的 iCloud 同步試過，需要受限 entitlement，見 KeychainStore。）
//
//  沒收錄的還有 `videoRotationCursor`／`videoRemoteCursor`：那是「輪到第幾支了」，
//  是執行狀態不是設定，跨機同步只會讓兩台互相打斷輪替。
//
//  **`videoScreens` 也不收**（0.6.0 移除）。它存的是顯示器 UUID，而內建螢幕的 UUID
//  每台機器都不同——同步它只可能做減法：另一台的快照裡沒有這台內建螢幕的 UUID，
//  套下來就是把「此螢幕改用影片」的勾清掉，影片螢幕被蒙太奇蓋住。
//  而且會自我固化：清空之後下一拍又把「空的」推回 iCloud，永遠出不來。
//  哪台螢幕播影片是**這台機器的硬體設定**，跟輪到第幾支一樣不該跨機。
//  舊的備份檔仍可解——多出來的鍵 JSONDecoder 本來就會忽略。

import Foundation

public struct SettingsSnapshot: Codable, Sendable, Equatable {

    /// 相簿的雙重身分：id 給同機還原，title 給跨機比對。
    public struct Album: Codable, Sendable, Equatable {
        public var id: String
        public var title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public static let currentVersion = 1

    public var version: Int
    public var savedAt: Date
    /// 寫出這份備份的機器名稱，只給 UI 顯示用。
    public var deviceName: String

    /// 來源資料夾的**路徑**（不是 bookmark，理由見檔頭）。
    public var folders: [String]
    public var folderUsage: [String: SourceUsage]
    public var albums: [Album]
    public var remoteSources: [RemoteSourceConfig]
    /// 片單網址。純網址、沒有機密，可以跨機搬（影片本體不搬，另一台自己抓）。
    public var playlistSources: [PlaylistSource]
    public var sourceRules: [SourceRule]

    public var intervalMinutes: Int
    public var effect: String
    /// nil＝自動。
    public var montagePieceCount: Int?

    public var videoWallpaperEnabled: Bool
    public var videoEngine: VideoEngine
    public var desktopVideoLayer: DesktopVideoLayer
    /// 一支播完之後怎麼辦。只影響桌面視窗那條路。
    public var videoPlaybackMode: VideoPlaybackMode
    /// 影片怎麼填進螢幕。兩條引擎都吃，跟硬體無關，可以跨機搬。
    public var videoScaleMode: VideoScaleMode
    /// 片單影片的下載畫質上限。跟硬體無關，是純粹的偏好，可以跨機搬。
    ///
    /// **`videoCookieSource` 刻意不收。** 那是「借哪個瀏覽器的登入狀態」，
    /// 而另一台不見得裝了那個瀏覽器，就算裝了 TCC 與鑰匙串的授權也得重來一次。
    /// 同步它只會讓另一台顯示成「已設定 Chrome」，實際上一個 cookie 都讀不到——
    /// 跟 `videoScreens` 是同一類錯誤：看起來搬過去了，其實是搬了個空殼。
    public var videoDownloadQuality: VideoDownloadQuality

    public var launchAtLogin: Bool

    public init(
        version: Int = SettingsSnapshot.currentVersion,
        savedAt: Date,
        deviceName: String,
        folders: [String],
        folderUsage: [String: SourceUsage],
        albums: [Album],
        remoteSources: [RemoteSourceConfig],
        playlistSources: [PlaylistSource] = [],
        sourceRules: [SourceRule],
        intervalMinutes: Int,
        effect: String,
        montagePieceCount: Int?,
        videoWallpaperEnabled: Bool,
        videoEngine: VideoEngine,
        desktopVideoLayer: DesktopVideoLayer,
        videoPlaybackMode: VideoPlaybackMode = .repeatAll,
        videoScaleMode: VideoScaleMode = .fill,
        videoDownloadQuality: VideoDownloadQuality = .default,
        launchAtLogin: Bool
    ) {
        self.version = version
        self.savedAt = savedAt
        self.deviceName = deviceName
        self.folders = folders
        self.folderUsage = folderUsage
        self.albums = albums
        self.remoteSources = remoteSources
        self.playlistSources = playlistSources
        self.sourceRules = sourceRules
        self.intervalMinutes = intervalMinutes
        self.effect = effect
        self.montagePieceCount = montagePieceCount
        self.videoWallpaperEnabled = videoWallpaperEnabled
        self.videoEngine = videoEngine
        self.desktopVideoLayer = desktopVideoLayer
        self.videoPlaybackMode = videoPlaybackMode
        self.videoScaleMode = videoScaleMode
        self.videoDownloadQuality = videoDownloadQuality
        self.launchAtLogin = launchAtLogin
    }

    // MARK: - 解碼

    private enum CodingKeys: String, CodingKey {
        case version, savedAt, deviceName, folders, folderUsage, albums
        case remoteSources, playlistSources, sourceRules
        case intervalMinutes, effect, montagePieceCount
        case videoWallpaperEnabled, videoEngine, desktopVideoLayer
        case videoPlaybackMode, videoScaleMode, videoDownloadQuality
        case launchAtLogin
    }

    /// 手寫而不是讓編譯器合成：**合成的版本不會用屬性預設值**，欄位缺一個就整份解不開。
    /// 舊版寫下的備份沒有後來才加的欄位，那不是損壞，是正常的。
    /// 只有後加的欄位用 `decodeIfPresent`；v1 就有的照樣必填，真的壞掉要看得出來。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        savedAt = try c.decode(Date.self, forKey: .savedAt)
        deviceName = try c.decode(String.self, forKey: .deviceName)
        folders = try c.decode([String].self, forKey: .folders)
        folderUsage = try c.decode([String: SourceUsage].self, forKey: .folderUsage)
        albums = try c.decode([Album].self, forKey: .albums)
        remoteSources = try c.decode([RemoteSourceConfig].self, forKey: .remoteSources)
        sourceRules = try c.decode([SourceRule].self, forKey: .sourceRules)
        intervalMinutes = try c.decode(Int.self, forKey: .intervalMinutes)
        effect = try c.decode(String.self, forKey: .effect)
        montagePieceCount = try c.decodeIfPresent(Int.self, forKey: .montagePieceCount)
        videoWallpaperEnabled = try c.decode(Bool.self, forKey: .videoWallpaperEnabled)
        videoEngine = try c.decode(VideoEngine.self, forKey: .videoEngine)
        desktopVideoLayer = try c.decode(DesktopVideoLayer.self, forKey: .desktopVideoLayer)
        launchAtLogin = try c.decode(Bool.self, forKey: .launchAtLogin)

        // 後加的欄位用 decodeIfPresent：舊備份沒有它，那不是損壞。
        // （移除的欄位不必處理——JSONDecoder 本來就會忽略不認得的鍵。）
        playlistSources = try c.decodeIfPresent([PlaylistSource].self, forKey: .playlistSources) ?? []
        // 舊備份沒有播放模式：套 .repeatAll 這個預設，與全新安裝一致。
        videoPlaybackMode = try c.decodeIfPresent(
            VideoPlaybackMode.self, forKey: .videoPlaybackMode) ?? .repeatAll
        // 舊備份沒有縮放：.fill 就是 0.6.2 以前寫死的行為，還原後畫面不會變。
        videoScaleMode = try c.decodeIfPresent(
            VideoScaleMode.self, forKey: .videoScaleMode) ?? .fill
        // 舊備份沒有畫質上限：.p1080 就是 0.6.8 以前寫死的值，還原後畫質不會變。
        videoDownloadQuality = try c.decodeIfPresent(
            VideoDownloadQuality.self, forKey: .videoDownloadQuality) ?? .default
    }

    /// 內容是否等價——**不看 `savedAt` 與 `deviceName`**。
    ///
    /// 自動同步靠這個判斷「設定真的變了嗎」。連時間戳一起比的話，
    /// 每次比較都不相等，兩台機器會互相寫檔寫個不停。
    public func hasSameContent(as other: SettingsSnapshot) -> Bool {
        var a = self, b = other
        a.savedAt = .distantPast; b.savedAt = .distantPast
        a.deviceName = ""; b.deviceName = ""
        return a == b
    }
}

/// JSON 往返。人看得懂是刻意的：備份檔就躺在 iCloud Drive 裡，
/// 出事時使用者要能自己打開看發生什麼事。
public enum SettingsSnapshotCodec {

    public static func encode(_ snapshot: SettingsSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    public enum Failure: Error, Equatable {
        /// 版本比這個 build 認得的還新：硬套會把設定改成半套。
        case unsupportedVersion(Int)
    }

    public static func decode(_ data: Data) throws -> SettingsSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(SettingsSnapshot.self, from: data)
        guard snapshot.version <= SettingsSnapshot.currentVersion else {
            throw Failure.unsupportedVersion(snapshot.version)
        }
        return snapshot
    }
}
