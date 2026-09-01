import XCTest
@testable import FoldwallCore

/// 兩層設定：共用的來源目錄與每台一份的裝置設定。
///
/// 這裡鎖的重點只有一個——**開關不准出現在共用層**。那是整個設計的分界線，
/// 破掉的話三台會互相把對方關掉的來源打開。
final class SyncSnapshotsTests: XCTestCase {

    private let remoteID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let playlistID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func catalog(
        savedAt: Date = Date(timeIntervalSince1970: 1_000_000),
        deviceName: String = "MacBook"
    ) -> SourceCatalog {
        SourceCatalog(
            savedAt: savedAt,
            deviceName: deviceName,
            folders: ["/Volumes/Archive/Tablescape"],
            remoteSources: [
                SourceCatalog.Remote(
                    id: remoteID, kind: .pexels, query: "aurora", endpoint: "")
            ],
            playlistSources: [
                SourceCatalog.Playlist(
                    id: playlistID, title: "夜景", urlString: "https://example.com/list")
            ]
        )
    }

    private func device(
        savedAt: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> DeviceSettings {
        DeviceSettings(
            savedAt: savedAt,
            deviceName: "MacBook",
            deviceID: "ABC-123",
            folderUsage: ["/Volumes/Archive/Tablescape": .montage],
            albums: [DeviceSettings.Album(id: "AE9F/L0/260", title: "Holo1")],
            disabledRemoteSources: [remoteID],
            disabledPlaylists: [],
            sourceRules: [],
            intervalMinutes: 5,
            effect: PostProcess.random.rawValue,
            montagePieceCount: nil,
            showCredits: false,
            videoWallpaperEnabled: true,
            videoEngine: .desktopWindow,
            desktopVideoLayer: .belowIcons,
            videoPlaybackMode: .shuffle,
            videoScaleMode: .fit,
            videoDownloadQuality: .default,
            videoCookieSource: .none,
            videoScreens: ["37D8832A-2D66-02CA-B9F7-8F30A301B230"],
            launchAtLogin: true
        )
    }

    // MARK: - 往返

    func testCatalogRoundTrip() throws {
        let original = catalog()
        let decoded = try SyncCodec.decode(
            SourceCatalog.self, from: try SyncCodec.encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testDeviceRoundTrip() throws {
        let original = device()
        let decoded = try SyncCodec.decode(
            DeviceSettings.self, from: try SyncCodec.encode(original))
        XCTAssertEqual(decoded, original)
    }

    /// 檔案就躺在 iCloud Drive 裡，出事時使用者要能自己打開看。
    func testEncodedFormIsReadableJSON() throws {
        let text = String(decoding: try SyncCodec.encode(catalog()), as: UTF8.self)
        XCTAssertTrue(text.contains("\"folders\""))
        XCTAssertTrue(text.contains("/Volumes/Archive/Tablescape"), "路徑不該被跳脫成 \\/")
        XCTAssertTrue(text.contains("\n"), "prettyPrinted：人要看得懂")
    }

    /// 存的是路徑不是 bookmark——bookmark 綁機器，另一台解不開。
    func testFoldersArePlainPaths() throws {
        let text = String(decoding: try SyncCodec.encode(catalog()), as: UTF8.self)
        XCTAssertFalse(text.contains("book"), "不該出現 bookmark 的二進位標頭")
    }

    /// **這一條是整個兩層設計的分界線。** 共用目錄裡出現 `isEnabled`，
    /// 就等於在一台關掉的來源會讓別台也關掉。
    func testCatalogCarriesNoEnabledFlag() throws {
        let text = String(decoding: try SyncCodec.encode(catalog()), as: UTF8.self)
        XCTAssertFalse(text.contains("isEnabled"), "開關是每台自己的事，不進共用目錄")
        XCTAssertFalse(text.contains("resolvedTitle"), "片單標題是這台的解析快取")
        XCTAssertFalse(text.contains("folderUsage"), "資料夾用途是每台自己的事")
        XCTAssertFalse(text.contains("albums"), "相簿 id 每台不同，整個留在裝置層")
    }

    // MARK: - 內容比對

    /// 自動同步靠這個判斷「真的變了嗎」。連時間戳一起比的話三台會互相寫檔寫個不停。
    func testCatalogContentComparisonIgnoresStamps() {
        let a = catalog(savedAt: Date(timeIntervalSince1970: 1), deviceName: "A")
        let b = catalog(savedAt: Date(timeIntervalSince1970: 9_999), deviceName: "B")
        XCTAssertTrue(a.hasSameContent(as: b))
        XCTAssertNotEqual(a, b)
    }

    func testCatalogContentComparisonSeesRealChange() {
        var changed = catalog()
        changed.folders.append("/Volumes/Archive/Another")
        XCTAssertFalse(catalog().hasSameContent(as: changed))
    }

    func testDeviceContentComparisonIgnoresStamp() {
        let a = device(savedAt: Date(timeIntervalSince1970: 1))
        let b = device(savedAt: Date(timeIntervalSince1970: 9_999))
        XCTAssertTrue(a.hasSameContent(as: b))
    }

    // MARK: - 版本

    /// 版本比這個 build 認得的還新：硬套會把設定改成半套。
    func testRejectsNewerVersion() throws {
        var future = catalog()
        future.version = SourceCatalog.currentVersion + 1
        let data = try SyncCodec.encode(future)
        XCTAssertThrowsError(try SyncCodec.decode(SourceCatalog.self, from: data)) { error in
            XCTAssertEqual(
                error as? SyncCodec.Failure,
                .unsupportedVersion(SourceCatalog.currentVersion + 1))
        }
    }

    /// 舊版寫下的檔案沒有後來才加的欄位，那不是損壞，是正常的。
    func testDeviceDecodesFileMissingLaterFields() throws {
        let minimal = """
        {
          "version": 1,
          "savedAt": "1970-01-12T13:46:40Z",
          "deviceName": "MacBook",
          "folderUsage": {},
          "albums": [],
          "sourceRules": [],
          "intervalMinutes": 5,
          "effect": "none",
          "videoWallpaperEnabled": false,
          "videoEngine": "desktopWindow",
          "desktopVideoLayer": "belowIcons",
          "launchAtLogin": false
        }
        """
        let decoded = try SyncCodec.decode(
            DeviceSettings.self, from: Data(minimal.utf8))
        XCTAssertEqual(decoded.deviceID, "")
        XCTAssertEqual(decoded.videoPlaybackMode, .repeatAll)
        XCTAssertEqual(decoded.videoScaleMode, .fill)
        XCTAssertEqual(decoded.videoCookieSource, .none)
        XCTAssertTrue(decoded.videoScreens.isEmpty)
        XCTAssertTrue(decoded.showCredits, "缺鍵＝開著，與全新安裝一致")
    }

    // MARK: - 從 0.6.x 拆過來

    func testLegacySnapshotSplitsIntoTwoLayers() {
        let legacy = SettingsSnapshot(
            savedAt: Date(timeIntervalSince1970: 1_000_000),
            deviceName: "舊機",
            folders: ["/Volumes/Archive"],
            folderUsage: ["/Volumes/Archive": .video],
            albums: [SettingsSnapshot.Album(id: "A1", title: "Holo1")],
            remoteSources: [
                RemoteSourceConfig(id: remoteID, kind: .pexels, isEnabled: false, query: "aurora")
            ],
            playlistSources: [
                PlaylistSource(
                    id: playlistID, title: "夜景", urlString: "https://example.com/list",
                    isEnabled: true, resolvedTitle: "解析回來的標題")
            ],
            sourceRules: [],
            intervalMinutes: 15,
            effect: PostProcess.none.rawValue,
            montagePieceCount: 6,
            videoWallpaperEnabled: true,
            videoEngine: .desktopWindow,
            desktopVideoLayer: .belowIcons,
            launchAtLogin: true
        )

        let (catalog, device) = legacy.split()

        XCTAssertEqual(catalog.folders, ["/Volumes/Archive"])
        XCTAssertEqual(catalog.remoteSources.map(\.id), [remoteID])
        XCTAssertEqual(catalog.playlistSources.first?.title, "夜景")

        // 舊格式把開關存在來源定義裡；拆出來之後那是這台的事
        XCTAssertEqual(device.disabledRemoteSources, [remoteID])
        XCTAssertTrue(device.disabledPlaylists.isEmpty)
        XCTAssertEqual(device.folderUsage, ["/Volumes/Archive": .video])
        XCTAssertEqual(device.albums.map(\.title), ["Holo1"])
        XCTAssertEqual(device.intervalMinutes, 15)
    }
}
