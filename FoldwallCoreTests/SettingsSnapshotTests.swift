import XCTest
@testable import FoldwallCore

final class SettingsSnapshotTests: XCTestCase {

    private func sample(
        savedAt: Date = Date(timeIntervalSince1970: 1_000_000),
        deviceName: String = "MacBook"
    ) -> SettingsSnapshot {
        SettingsSnapshot(
            savedAt: savedAt,
            deviceName: deviceName,
            folders: ["/Volumes/Archive/Tablescape"],
            folderUsage: ["/Volumes/Archive/Tablescape": .both],
            albums: [SettingsSnapshot.Album(id: "AE9F/L0/260", title: "Holo1")],
            remoteSources: [],
            sourceRules: [],
            intervalMinutes: 5,
            effect: PostProcess.random.rawValue,
            montagePieceCount: nil,
            videoWallpaperEnabled: true,
            videoEngine: .desktopWindow,
            desktopVideoLayer: .belowIcons,
            videoPlaybackMode: .shuffle,
            videoScreens: ["UUID-A"],
            launchAtLogin: true
        )
    }

    func testRoundTrip() throws {
        let original = sample()
        let decoded = try SettingsSnapshotCodec.decode(SettingsSnapshotCodec.encode(original))
        XCTAssertEqual(decoded, original)
    }

    /// 備份檔就躺在 iCloud Drive 裡，出事時使用者要能自己打開看。
    func testEncodedFormIsReadableJSON() throws {
        let text = String(decoding: try SettingsSnapshotCodec.encode(sample()), as: UTF8.self)
        XCTAssertTrue(text.contains("\"folders\""))
        XCTAssertTrue(text.contains("/Volumes/Archive/Tablescape"), "路徑不該被跳脫成 \\/")
        XCTAssertTrue(text.contains("\n"), "prettyPrinted：人要看得懂")
    }

    /// 存的是路徑不是 bookmark——bookmark 綁機器，另一台解不開。
    func testFoldersArePlainPaths() throws {
        let text = String(decoding: try SettingsSnapshotCodec.encode(sample()), as: UTF8.self)
        XCTAssertFalse(text.contains("book"), "不該出現 bookmark 的二進位標頭")
    }

    func testMontagePieceCountSurvivesNil() throws {
        var snapshot = sample()
        snapshot.montagePieceCount = 12
        let decoded = try SettingsSnapshotCodec.decode(SettingsSnapshotCodec.encode(snapshot))
        XCTAssertEqual(decoded.montagePieceCount, 12)

        snapshot.montagePieceCount = nil
        let auto = try SettingsSnapshotCodec.decode(SettingsSnapshotCodec.encode(snapshot))
        XCTAssertNil(auto.montagePieceCount, "自動不能在往返後變成某個數字")
    }

    /// 舊版寫下的備份沒有 `videoPlaybackMode`。那不是損壞——套新安裝的預設值。
    func testOlderBackupWithoutPlaybackModeStillDecodes() throws {
        let encoded = try SettingsSnapshotCodec.encode(sample())
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "videoPlaybackMode")
        let stripped = try JSONSerialization.data(withJSONObject: json)

        let decoded = try SettingsSnapshotCodec.decode(stripped)
        XCTAssertEqual(decoded.videoPlaybackMode, .repeatAll)
        XCTAssertEqual(decoded.folders, sample().folders, "其他欄位不受影響")
    }

    /// 比較內容時不看時間戳與機器名，否則自動同步會兩台互相寫檔寫不停。
    func testContentComparisonIgnoresStampAndDevice() {
        let a = sample(savedAt: Date(timeIntervalSince1970: 1), deviceName: "A")
        let b = sample(savedAt: Date(timeIntervalSince1970: 999_999), deviceName: "B")
        XCTAssertTrue(a.hasSameContent(as: b))
        XCTAssertNotEqual(a, b, "整體相等仍該看得出差異")

        var c = a
        c.intervalMinutes = 60
        XCTAssertFalse(a.hasSameContent(as: c))
    }

    /// 版本比這個 build 新就拒絕：硬套會把設定改成半套。
    func testNewerVersionIsRejected() throws {
        var future = sample()
        future.version = SettingsSnapshot.currentVersion + 1
        let data = try SettingsSnapshotCodec.encode(future)
        XCTAssertThrowsError(try SettingsSnapshotCodec.decode(data)) { error in
            XCTAssertEqual(error as? SettingsSnapshotCodec.Failure,
                           .unsupportedVersion(SettingsSnapshot.currentVersion + 1))
        }
    }

    /// 0.5.1 移除了串流網址，但既有備份裡還有那個欄位。
    /// 認不得的欄位要被忽略，不能讓整份備份解不開。
    func testBackupWithRemovedFieldStillDecodes() throws {
        var json = try JSONSerialization.jsonObject(
            with: try SettingsSnapshotCodec.encode(sample())) as! [String: Any]
        json["streamSources"] = [["id": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
                                  "urlString": "https://a.example/live.m3u8",
                                  "title": "", "isEnabled": true]]
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try SettingsSnapshotCodec.decode(data)
        XCTAssertEqual(decoded.intervalMinutes, 5, "其他欄位不受影響")
        XCTAssertEqual(decoded.folders, ["/Volumes/Archive/Tablescape"])
    }

    /// 但 v1 就有的欄位缺了要報錯——真的損壞要看得出來，不能默默套半套設定。
    func testMissingCoreFieldIsAnError() throws {
        var json = try JSONSerialization.jsonObject(
            with: try SettingsSnapshotCodec.encode(sample())) as! [String: Any]
        json.removeValue(forKey: "folders")
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try SettingsSnapshotCodec.decode(data))
    }

    func testOlderVersionIsAccepted() throws {
        var old = sample()
        old.version = 0
        let decoded = try SettingsSnapshotCodec.decode(try SettingsSnapshotCodec.encode(old))
        XCTAssertEqual(decoded.version, 0)
    }
}
