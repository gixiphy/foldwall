//  SyncSnapshots.swift
//  設定的兩層：**來源目錄**三台通用，**裝置設定**每台一份。
//
//  0.6.x 只有一份 `SettingsSnapshot`，整包一起同步。一台機器時那沒問題，
//  三台就是錯的：來源清單當然要一致（在筆電加的資料夾，桌機也該看得到），
//  但「這台開哪幾個來源、多久換一次、用哪條影片引擎」是**這台的事**。
//  同步它只會讓三台互相把對方的偏好蓋掉，而且會來回震盪——
//  跟 `videoScreens` 當初被移出快照是同一個錯誤，只是範圍更大。
//
//  所以拆成兩層：
//
//  | 層 | 檔案 | 誰讀 | 裝什麼 |
//  | --- | --- | --- | --- |
//  | 來源目錄 | `Foldwall/sources.json` | 三台共讀共寫 | 來源的**定義**：資料夾路徑、關鍵字、片單網址 |
//  | 裝置設定 | `Foldwall/devices/<機器>.json` | 只有同一台自動讀回 | 這台**開哪些**來源，以及桌布怎麼播 |
//
//  分界線是**「有什麼」與「用什麼」**：目錄說手上有哪些來源，裝置設定說這台要用哪些。
//  所以 `isEnabled`、`folderUsage`、選中的相簿全在裝置層、**不在目錄裡**——
//  在筆電關掉 Pexels 不該讓桌機也跟著關。
//
//  三件刻意**不放進目錄**的東西：
//
//  1. **相簿**。相簿清單來自「照片」本身；三台連同一個 iCloud 圖庫時本來就看得到
//     同一份，沒有「定義」要搬。而 `localIdentifier` 每台不同，搬過去也對不上。
//     要用哪幾個是這台的選擇，所以整個留在裝置層。
//  2. **`PlaylistSource.resolvedTitle`**。那是這台解析片單的快取，會自己變；
//     放進目錄的話每台解析完都要寫一次共用檔，三台互相蓋個不停。
//  3. **API key**。在 Keychain，本來就不在這裡（見 KeychainStore）。
//
//  裝置層反而收得比舊快照**多**：`videoScreens`（顯示器 UUID）與 `videoCookieSource`
//  當初被排除，是因為它們會跨機蓋掉別台；現在檔案本來就只有同一台會讀回來，
//  那個理由消失了，收進來換到的是「換掉這台 Mac 時能整套還原」。
//  仍然不收的只有影片游標——那是執行狀態，不是設定。

import Foundation

// MARK: - 版本

/// 兩份快照共用的版本檢查。比這個 build 認得的還新就不要硬套，
/// 套下去會把設定改成半套，比不套更難查。
public protocol VersionedSnapshot: Codable, Sendable {
    static var currentVersion: Int { get }
    var version: Int { get }
}

public enum SyncCodec {

    public enum Failure: Error, Equatable {
        case unsupportedVersion(Int)
    }

    /// JSON 往返。人看得懂是刻意的：檔案就躺在 iCloud Drive 裡，
    /// 出事時使用者要能自己打開看發生什麼事。
    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    public static func decode<T: VersionedSnapshot>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(T.self, from: data)
        guard value.version <= T.currentVersion else {
            throw Failure.unsupportedVersion(value.version)
        }
        return value
    }
}

// MARK: - 來源目錄（通用層）

/// 三台共用的來源**定義**。這裡沒有任何「開／關」——那在 `DeviceSettings`。
public struct SourceCatalog: VersionedSnapshot, Equatable {

    /// 網路來源的定義。**不含 `isEnabled`**：開不開是每台自己的事。
    public struct Remote: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var kind: RemoteSourceKind
        /// 搜尋關鍵字（stock 站）或 Immich／RSS 的網址。API key 在 Keychain。
        public var query: String
        public var endpoint: String

        public init(id: UUID, kind: RemoteSourceKind, query: String, endpoint: String) {
            self.id = id
            self.kind = kind
            self.query = query
            self.endpoint = endpoint
        }

        public init(_ config: RemoteSourceConfig) {
            self.init(
                id: config.id, kind: config.kind,
                query: config.query, endpoint: config.endpoint)
        }
    }

    /// 片單的定義。**不含 `isEnabled` 與 `resolvedTitle`**，理由見檔頭。
    public struct Playlist: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        /// 使用者自訂名稱。留白的話各台各自用自己解析回來的標題顯示。
        public var title: String
        public var urlString: String

        public init(id: UUID, title: String, urlString: String) {
            self.id = id
            self.title = title
            self.urlString = urlString
        }

        public init(_ source: PlaylistSource) {
            self.init(id: source.id, title: source.title, urlString: source.urlString)
        }
    }

    public static let currentVersion = 1

    public var version: Int
    public var savedAt: Date
    /// 上一次寫這份目錄的機器，只給 UI 顯示用。
    public var deviceName: String

    /// 來源資料夾的**路徑**（不是 bookmark——bookmark 綁著建立它的那台機器）。
    ///
    /// 這裡要放**全部**的路徑，包含這一刻讀不到的：NAS 沒掛的時候只寫得出讀得到的那些，
    /// 而目錄是會做減法的，等於一次沒掛就把別台的來源刪掉。
    public var folders: [String]
    public var remoteSources: [Remote]
    public var playlistSources: [Playlist]

    public init(
        version: Int = SourceCatalog.currentVersion,
        savedAt: Date,
        deviceName: String,
        folders: [String],
        remoteSources: [Remote],
        playlistSources: [Playlist]
    ) {
        self.version = version
        self.savedAt = savedAt
        self.deviceName = deviceName
        self.folders = folders
        self.remoteSources = remoteSources
        self.playlistSources = playlistSources
    }

    /// 內容是否等價——**不看 `savedAt` 與 `deviceName`**。
    /// 連時間戳一起比的話每次都不相等，三台會互相寫檔寫個不停。
    public func hasSameContent(as other: SourceCatalog) -> Bool {
        var a = self, b = other
        a.savedAt = .distantPast; b.savedAt = .distantPast
        a.deviceName = ""; b.deviceName = ""
        return a == b
    }
}

// MARK: - 裝置設定（依設備層）

/// 一台機器自己的設定：**開哪些來源**，以及桌布怎麼播。
///
/// 檔案在 iCloud 上，但只有同一台會自動讀回來——放上去是為了換機器時
/// 還原得回來，不是為了給別台自動套用。
public struct DeviceSettings: VersionedSnapshot, Equatable {

    /// 相簿的雙重身分：id 給同機還原，title 給使用者手動跨機匯入時比對
    /// （`localIdentifier` 每台機器都不同，就算兩台是同一個 iCloud 圖庫）。
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
    public var deviceName: String
    /// 這台的身分。機器改名之後檔名會變，靠這個認出「那份還是我的」。
    public var deviceID: String

    // MARK: 這台開哪些來源

    /// 每個來源資料夾餵給哪條管線。查不到的一律 `.both`。
    public var folderUsage: [String: SourceUsage]
    /// 這台選中的「照片」相簿。
    public var albums: [Album]
    /// 這台**關掉**的網路來源。存「關掉的」而不是「開著的」，是為了讓
    /// 目錄裡新出現的來源預設是開的——跟使用者手動加一個來源當下的直覺一致。
    /// 反過來存的話，在筆電加的來源會靜悄悄地以「關著」的樣子出現在桌機上。
    public var disabledRemoteSources: [UUID]
    /// 同上，片單。
    public var disabledPlaylists: [UUID]
    /// 依系統狀態調整來源的規則。**依設備**：筆電才有「靠電池」可言，
    /// 而專注模式的用法三台也常不一樣。
    public var sourceRules: [SourceRule]

    // MARK: 桌布怎麼播

    public var intervalMinutes: Int
    public var effect: String
    /// nil＝自動。
    public var montagePieceCount: Int?
    public var showCredits: Bool

    public var videoWallpaperEnabled: Bool
    public var videoEngine: VideoEngine
    public var desktopVideoLayer: DesktopVideoLayer
    public var videoPlaybackMode: VideoPlaybackMode
    public var videoScaleMode: VideoScaleMode
    public var videoDownloadQuality: VideoDownloadQuality
    public var videoCookieSource: VideoCookieSource
    /// 標記「這台改用影片」的螢幕，存 display UUID。
    ///
    /// **只有同一台還原時才該套用。** 內建螢幕的 UUID 每台機器都不同，
    /// 套上別台的清單等於把這台的勾清掉，影片螢幕會被蒙太奇蓋住。
    /// 手動跨機匯入時呼叫端要跳過這個欄位（見 `WallpaperCoordinator.apply`）。
    public var videoScreens: [String]

    public var launchAtLogin: Bool

    public init(
        version: Int = DeviceSettings.currentVersion,
        savedAt: Date,
        deviceName: String,
        deviceID: String,
        folderUsage: [String: SourceUsage],
        albums: [Album],
        disabledRemoteSources: [UUID] = [],
        disabledPlaylists: [UUID] = [],
        sourceRules: [SourceRule],
        intervalMinutes: Int,
        effect: String,
        montagePieceCount: Int?,
        showCredits: Bool = true,
        videoWallpaperEnabled: Bool,
        videoEngine: VideoEngine,
        desktopVideoLayer: DesktopVideoLayer,
        videoPlaybackMode: VideoPlaybackMode = .repeatAll,
        videoScaleMode: VideoScaleMode = .fill,
        videoDownloadQuality: VideoDownloadQuality = .default,
        videoCookieSource: VideoCookieSource = .none,
        videoScreens: [String] = [],
        launchAtLogin: Bool
    ) {
        self.version = version
        self.savedAt = savedAt
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.folderUsage = folderUsage
        self.albums = albums
        self.disabledRemoteSources = disabledRemoteSources
        self.disabledPlaylists = disabledPlaylists
        self.sourceRules = sourceRules
        self.intervalMinutes = intervalMinutes
        self.effect = effect
        self.montagePieceCount = montagePieceCount
        self.showCredits = showCredits
        self.videoWallpaperEnabled = videoWallpaperEnabled
        self.videoEngine = videoEngine
        self.desktopVideoLayer = desktopVideoLayer
        self.videoPlaybackMode = videoPlaybackMode
        self.videoScaleMode = videoScaleMode
        self.videoDownloadQuality = videoDownloadQuality
        self.videoCookieSource = videoCookieSource
        self.videoScreens = videoScreens
        self.launchAtLogin = launchAtLogin
    }

    // MARK: - 解碼

    private enum CodingKeys: String, CodingKey {
        case version, savedAt, deviceName, deviceID
        case folderUsage, albums, disabledRemoteSources, disabledPlaylists, sourceRules
        case intervalMinutes, effect, montagePieceCount, showCredits
        case videoWallpaperEnabled, videoEngine, desktopVideoLayer
        case videoPlaybackMode, videoScaleMode, videoDownloadQuality, videoCookieSource
        case videoScreens, launchAtLogin
    }

    /// 手寫而不是讓編譯器合成：**合成的版本不會用屬性預設值**，欄位缺一個就整份解不開。
    /// 舊版寫下的檔案沒有後來才加的欄位，那不是損壞，是正常的。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        savedAt = try c.decode(Date.self, forKey: .savedAt)
        deviceName = try c.decode(String.self, forKey: .deviceName)
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        folderUsage = try c.decode([String: SourceUsage].self, forKey: .folderUsage)
        albums = try c.decode([Album].self, forKey: .albums)
        disabledRemoteSources = try c.decodeIfPresent(
            [UUID].self, forKey: .disabledRemoteSources) ?? []
        disabledPlaylists = try c.decodeIfPresent([UUID].self, forKey: .disabledPlaylists) ?? []
        sourceRules = try c.decode([SourceRule].self, forKey: .sourceRules)
        intervalMinutes = try c.decode(Int.self, forKey: .intervalMinutes)
        effect = try c.decode(String.self, forKey: .effect)
        montagePieceCount = try c.decodeIfPresent(Int.self, forKey: .montagePieceCount)
        showCredits = try c.decodeIfPresent(Bool.self, forKey: .showCredits) ?? true
        videoWallpaperEnabled = try c.decode(Bool.self, forKey: .videoWallpaperEnabled)
        videoEngine = try c.decode(VideoEngine.self, forKey: .videoEngine)
        desktopVideoLayer = try c.decode(DesktopVideoLayer.self, forKey: .desktopVideoLayer)
        videoPlaybackMode = try c.decodeIfPresent(
            VideoPlaybackMode.self, forKey: .videoPlaybackMode) ?? .repeatAll
        videoScaleMode = try c.decodeIfPresent(
            VideoScaleMode.self, forKey: .videoScaleMode) ?? .fill
        videoDownloadQuality = try c.decodeIfPresent(
            VideoDownloadQuality.self, forKey: .videoDownloadQuality) ?? .default
        videoCookieSource = try c.decodeIfPresent(
            VideoCookieSource.self, forKey: .videoCookieSource) ?? .none
        videoScreens = try c.decodeIfPresent([String].self, forKey: .videoScreens) ?? []
        launchAtLogin = try c.decode(Bool.self, forKey: .launchAtLogin)
    }

    /// 內容是否等價——不看 `savedAt`。理由同 `SourceCatalog.hasSameContent`。
    public func hasSameContent(as other: DeviceSettings) -> Bool {
        var a = self, b = other
        a.savedAt = .distantPast; b.savedAt = .distantPast
        return a == b
    }
}
