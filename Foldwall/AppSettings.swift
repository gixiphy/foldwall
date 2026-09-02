//  AppSettings.swift
//  UserDefaults key 由 HANDOFF 設定 schema 鎖定，不要改。

import Foundation
import Observation
import ServiceManagement
import FoldwallCore

@MainActor
@Observable
final class AppSettings {

    enum Key {
        static let intervalMinutes = "intervalMinutes"
        static let effect = "effect"
        static let videoScreens = "videoScreens"
        static let videoWallpaperEnabled = "videoWallpaperEnabled"
        static let videoRotationCursor = "videoRotationCursor"
        static let videoRemoteCursor = "videoRemoteCursor"
        static let launchAtLogin = "launchAtLogin"
        static let remoteSources = "remoteSources"
        static let photoAlbums = "photoAlbums"
        static let sourceRules = "sourceRules"
        static let folderUsage = "folderUsage"
        static let videoEngine = "videoEngine"
        static let desktopVideoLayer = "desktopVideoLayer"
        static let videoPlaybackMode = "videoPlaybackMode"
        static let videoScaleMode = "videoScaleMode"
        static let montagePieceCount = "montagePieceCount"
        static let showCredits = "showCredits"
        static let iCloudSyncEnabled = "iCloudSyncEnabled"
        static let playlistSources = "playlistSources"
        static let videoDownloadQuality = "videoDownloadQuality"
        static let videoCookieSource = "videoCookieSource"
        static let uiTranslationLanguage = "uiTranslationLanguage"
        static let builtinLanguage = "builtinLanguage"
        static let translationEngineID = "translationEngineID"
        static let translationModelIDs = "translationModelIDs"
        static let translationCustomPaths = "translationCustomPaths"
        static let translationModelCache = "translationModelCache"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var intervalMinutes: Int {
        didSet { defaults.set(intervalMinutes, forKey: Key.intervalMinutes) }
    }

    var effect: PostProcess {
        didSet { defaults.set(effect.rawValue, forKey: Key.effect) }
    }

    /// 每輪最多抽幾張（**上限**，實際張數每輪在 1...上限之間抽，見
    /// `StillPipeline.drawnPieceCount`）。`nil`＝自動（依螢幕長邊）。
    /// 存 0 代表自動——UserDefaults 沒有 optional Int，缺 key 讀出來也是 0，兩種情況同義。
    var montagePieceCount: Int? {
        didSet { defaults.set(montagePieceCount ?? 0, forKey: Key.montagePieceCount) }
    }

    /// 要不要把來源與作者印在蒙太奇上。**預設開**：Unsplash 與 Pexels 的授權
    /// 都要求標註，關掉之後責任在使用者身上。
    /// 存的是反向鍵（`hideCredits`）——UserDefaults 缺 key 讀出來是 false，
    /// 反過來存才能讓「沒設定過」自然等於「開著」。
    var showCredits: Bool {
        didSet { defaults.set(!showCredits, forKey: Key.showCredits) }
    }

    /// 每個來源資料夾要餵給哪條管線（蒙太奇／影片）。
    /// 鍵是資料夾路徑；沒設定過的一律 `.both`，與加入資料夾當下的直覺一致。
    var folderUsage: [String: SourceUsage] {
        didSet {
            guard let data = try? JSONEncoder().encode(folderUsage) else { return }
            defaults.set(data, forKey: Key.folderUsage)
        }
    }

    func usage(for folder: URL) -> SourceUsage {
        folderUsage[folder.standardizedFileURL.path] ?? .both
    }

    func setUsage(_ usage: SourceUsage, for folder: URL) {
        folderUsage[folder.standardizedFileURL.path] = usage
    }

    /// 依系統狀態調整來源的規則（電池／專注模式）。預設空＝行為與以前完全相同。
    var sourceRules: [SourceRule] {
        didSet {
            guard let data = try? JSONEncoder().encode(sourceRules) else { return }
            defaults.set(data, forKey: Key.sourceRules)
        }
    }

    /// 影片桌布總開關，**預設關**。
    ///
    /// 關著就一支影片都不拷。開了才把來源資料夾裡的影片送進 extension container——
    /// 那是實體拷貝（沙盒 extension 讀不到 app 的 bookmark），一座 NAS 可以是幾百 GB。
    /// 預設開的話，只想要靜態蒙太奇的人會平白被塞爆磁碟。
    var videoWallpaperEnabled: Bool {
        didSet { defaults.set(videoWallpaperEnabled, forKey: Key.videoWallpaperEnabled) }
    }

    /// 影片桌布用哪條管線。預設桌面視窗：零拷貝、公開 API。
    /// 要鎖屏才切到系統 extension。
    var videoEngine: VideoEngine {
        didSet { defaults.set(videoEngine.rawValue, forKey: Key.videoEngine) }
    }

    /// 桌面視窗壓在圖示上面還是下面。
    var desktopVideoLayer: DesktopVideoLayer {
        didSet { defaults.set(desktopVideoLayer.rawValue, forKey: Key.desktopVideoLayer) }
    }

    /// 一支播完之後怎麼辦：單片循環／全部循環／隨機。只有桌面視窗那條路吃這個設定
    /// （系統 extension 的輪替在「系統設定 → 桌布」裡設，見 ShuffleController）。
    ///
    /// **預設全部循環。** 0.6.0 以前只有「單片循環」一種行為，等於整個片庫只有一支
    /// 在用；缺 key 讀出來的 nil 走這個預設，舊使用者升上來會看到影片開始輪動。
    var videoPlaybackMode: VideoPlaybackMode {
        didSet { defaults.set(videoPlaybackMode.rawValue, forKey: Key.videoPlaybackMode) }
    }

    /// 影片怎麼填進螢幕：填滿／符合／擴充／隨機。**兩條引擎都吃這個設定**。
    ///
    /// **預設填滿螢幕**（`.fill`）：0.6.2 以前是寫死的 `resizeAspectFill`，
    /// 缺 key 走這個預設，升上來的人畫面不會變。
    var videoScaleMode: VideoScaleMode {
        didSet { defaults.set(videoScaleMode.rawValue, forKey: Key.videoScaleMode) }
    }

    /// 影片輪替走到哪了。存起來才能跨重啟繼續輪，不會每次都從頭那幾支開始。
    var videoRotationCursor: Int {
        didSet { defaults.set(videoRotationCursor, forKey: Key.videoRotationCursor) }
    }

    /// 網路影片各自一個游標：兩邊數量差很多（實測 4596 對 6），
    /// 共用游標會讓網路那幾支永遠輪不到。
    var videoRemoteCursor: Int {
        didSet { defaults.set(videoRemoteCursor, forKey: Key.videoRemoteCursor) }
    }

    /// 使用者標記「這台改用影片」的螢幕，存 display UUID。
    /// **不能存 CGDirectDisplayID**：重開機／熱插拔會變，會記錯螢幕。
    var videoScreens: Set<String> {
        didSet { defaults.set(Array(videoScreens), forKey: Key.videoScreens) }
    }

    var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    /// 自動與 iCloud 同步設定。**預設關**：開著代表另一台機器改的設定會自動
    /// 蓋掉這台的，那該由使用者明確選擇，不是預設行為。
    var iCloudSyncEnabled: Bool {
        didSet { defaults.set(iCloudSyncEnabled, forKey: Key.iCloudSyncEnabled) }
    }

    /// 免 OAuth 的網路來源。API key 不在這裡，在 Keychain（以 config.id 為帳號）。
    var remoteSources: [RemoteSourceConfig] {
        didSet {
            guard let data = try? JSONEncoder().encode(remoteSources) else { return }
            defaults.set(data, forKey: Key.remoteSources)
        }
    }

    /// 片單網址。存的是網址，不是影片——抽到哪支才抓哪支（見 PlaylistService）。
    var playlistSources: [PlaylistSource] {
        didSet {
            guard let data = try? JSONEncoder().encode(playlistSources) else { return }
            defaults.set(data, forKey: Key.playlistSources)
        }
    }

    /// 片單影片的下載畫質上限。**0.6.8 以前是寫死的 1080p**，預設維持一樣，
    /// 升上來的人畫質不會突然變（也不會突然把快取撐爆）。
    var videoDownloadQuality: VideoDownloadQuality {
        didSet { defaults.set(videoDownloadQuality.rawValue, forKey: Key.videoDownloadQuality) }
    }

    /// 下載時要不要借某個瀏覽器的登入狀態。**預設不借**——那是把使用者的登入身分
    /// 交給一個子行程去用，要由他明確選擇，不該是預設行為。
    ///
    /// 存的只有瀏覽器名字。cookie 本身 Foldwall 不碰（見 `VideoCookieSource`）。
    var videoCookieSource: VideoCookieSource {
        didSet { defaults.set(videoCookieSource.rawValue, forKey: Key.videoCookieSource) }
    }

    /// 選中的「照片」相簿 localIdentifier。
    var photoAlbums: Set<String> {
        didSet { defaults.set(Array(photoAlbums), forKey: Key.photoAlbums) }
    }

    /// 使用者用本機 AI CLI 自翻的介面語言（見 UITranslationStore）；nil＝用內建語言。
    /// 啟動時由 App.init 讀來裝覆蓋——**不進備份**：翻譯檔本來就只在這台。
    var uiTranslationLanguage: String? {
        didSet { defaults.set(uiTranslationLanguage, forKey: Key.uiTranslationLanguage) }
    }

    /// 使用者指定的內建語言（zh-Hant／zh-Hans／en）；nil＝跟隨系統。
    /// 真正讓語言生效的是 App domain 的 `AppleLanguages`（見 `applyInterfaceLanguage`），
    /// 這個鍵只是記住使用者選了什麼，好在設定頁顯示與判斷要不要重啟。
    var builtinLanguage: String? {
        didSet { defaults.set(builtinLanguage, forKey: Key.builtinLanguage) }
    }

    /// 寫 App 自己 domain 的 `AppleLanguages`；nil＝拿掉，回到系統語言。
    /// **只有下次啟動才生效**——Foundation 在行程啟動時就把語言決定好了，
    /// 這也是設定頁一律提示重啟的原因。
    ///
    /// 寫進 `defaults`（而不是寫死 `.standard`）是為了讓 Preview／測試用自己的 suite 時，
    /// 不會把使用者本尊的介面語言改掉。
    func applyInterfaceLanguage(_ code: String?) {
        if let code {
            defaults.set([code], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }

    /// 翻譯用哪個 CLI（KnownCLIEngine.catalog 的 id）。預設 claude。
    var translationEngineID: String {
        didSet { defaults.set(translationEngineID, forKey: Key.translationEngineID) }
    }

    /// 各引擎的自訂模型（engine id → slug）。缺＝用 CLI 自己的預設。
    var translationModelIDs: [String: String] {
        didSet { defaults.set(translationModelIDs, forKey: Key.translationModelIDs) }
    }

    /// 各引擎的自訂執行檔路徑（engine id → path），PATH 找不到時用。
    var translationCustomPaths: [String: String] {
        didSet { defaults.set(translationCustomPaths, forKey: Key.translationCustomPaths) }
    }

    /// 各引擎回報過的模型清單，鍵是 `<engine id>|<version>`。
    /// 以**版本**當快取鍵：版本沒變就用快取，升版即重抓——列舉會打網路
    /// （實測 grok／opencode 各十餘秒），不該每次打開設定頁都跑一遍。
    var translationModelCache: [String: [String]] {
        didSet { defaults.set(translationModelCache, forKey: Key.translationModelCache) }
    }

    /// Keychain 帳號名：每個來源設定各自一把 key。
    static func keychainAccount(for config: RemoteSourceConfig) -> String {
        "remote-\(config.kind.rawValue)-\(config.id.uuidString)"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedInterval = defaults.integer(forKey: Key.intervalMinutes)
        self.intervalMinutes = Scheduler.intervalOptions.contains(storedInterval)
            ? storedInterval
            : Scheduler.defaultIntervalMinutes

        self.effect = (defaults.string(forKey: Key.effect).flatMap(PostProcess.init(rawValue:))) ?? .none
        let storedPieces = defaults.integer(forKey: Key.montagePieceCount)   // 缺 key = 0 = 自動
        self.montagePieceCount = MontageComposer.pieceCountRange.contains(storedPieces)
            ? storedPieces
            : nil
        self.showCredits = !defaults.bool(forKey: Key.showCredits)   // 缺 key = false = 開著
        self.videoScreens = Set(defaults.stringArray(forKey: Key.videoScreens) ?? [])
        self.videoWallpaperEnabled = defaults.bool(forKey: Key.videoWallpaperEnabled)   // 缺 key = false
        self.iCloudSyncEnabled = defaults.bool(forKey: Key.iCloudSyncEnabled)           // 缺 key = false
        self.videoEngine = (defaults.string(forKey: Key.videoEngine)
            .flatMap(VideoEngine.init(rawValue:))) ?? .desktopWindow
        self.desktopVideoLayer = (defaults.string(forKey: Key.desktopVideoLayer)
            .flatMap(DesktopVideoLayer.init(rawValue:))) ?? .belowIcons
        self.videoPlaybackMode = (defaults.string(forKey: Key.videoPlaybackMode)
            .flatMap(VideoPlaybackMode.init(rawValue:))) ?? .repeatAll
        self.videoScaleMode = (defaults.string(forKey: Key.videoScaleMode)
            .flatMap(VideoScaleMode.init(rawValue:))) ?? .fill
        self.videoDownloadQuality = (defaults.string(forKey: Key.videoDownloadQuality)
            .flatMap(VideoDownloadQuality.init(rawValue:))) ?? .default
        self.videoCookieSource = (defaults.string(forKey: Key.videoCookieSource)
            .flatMap(VideoCookieSource.init(rawValue:))) ?? .none
        self.videoRotationCursor = defaults.integer(forKey: Key.videoRotationCursor)   // 缺 key = 0
        self.videoRemoteCursor = defaults.integer(forKey: Key.videoRemoteCursor)
        // 以系統實際狀態為準，不信 defaults：使用者可能在系統設定裡關掉
        self.launchAtLogin = SMAppService.mainApp.status == .enabled

        // 逐筆解、認不得的丟掉：整包解的話，一筆舊型別就會讓所有來源消失
        self.remoteSources = defaults.data(forKey: Key.remoteSources)
            .map(RemoteSourceConfig.decodeList) ?? []
        self.photoAlbums = Set(defaults.stringArray(forKey: Key.photoAlbums) ?? [])
        self.uiTranslationLanguage = defaults.string(forKey: Key.uiTranslationLanguage)
        self.builtinLanguage = defaults.string(forKey: Key.builtinLanguage)
        self.translationEngineID = defaults.string(forKey: Key.translationEngineID) ?? "claude"
        self.translationModelIDs = (defaults.dictionary(forKey: Key.translationModelIDs) as? [String: String]) ?? [:]
        self.translationCustomPaths = (defaults.dictionary(forKey: Key.translationCustomPaths) as? [String: String]) ?? [:]
        self.translationModelCache = (defaults.dictionary(forKey: Key.translationModelCache) as? [String: [String]]) ?? [:]
        self.playlistSources = (defaults.data(forKey: Key.playlistSources)
            .flatMap { try? JSONDecoder().decode([PlaylistSource].self, from: $0) }) ?? []
        self.sourceRules = (defaults.data(forKey: Key.sourceRules)
            .flatMap { try? JSONDecoder().decode([SourceRule].self, from: $0) }) ?? []
        self.folderUsage = (defaults.data(forKey: Key.folderUsage)
            .flatMap { try? JSONDecoder().decode([String: SourceUsage].self, from: $0) }) ?? [:]
    }

    private func applyLaunchAtLogin() {
        defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("登入時啟動設定失敗：\(error.localizedDescription, privacy: .public)")
        }
    }
}
