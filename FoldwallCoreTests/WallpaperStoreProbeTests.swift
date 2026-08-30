import XCTest
@testable import FoldwallCore

/// fixture 的形狀照實機的 Index.plist 排：Displays／Spaces（Default＋Displays）／
/// AllSpacesAndDisplays 三區，選擇是 {Provider, Configuration(Data), Files} 的字典。
final class WallpaperStoreProbeTests: XCTestCase {

    private let marker = "app.foldwall.extension"
    private var storeURL: URL!

    override func setUpWithError() throws {
        storeURL = URL.temporaryDirectory
            .appending(path: "foldwall-store-\(UUID().uuidString).plist")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeURL)
    }

    private func probe() -> WallpaperStoreProbe.ExtensionPresence {
        WallpaperStoreProbe.extensionPresence(marker: marker, storeURL: storeURL)
    }

    private func write(_ root: [String: Any]) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: root, format: .binary, options: 0)
        try data.write(to: storeURL)
    }

    /// 一份桌布設定區。extension 選擇的 bundle id 藏在 Configuration 的 Data 裡
    /// ——探測靠位元組搜尋，不解析格式，所以放哪個欄位都要找得到。
    private func desktop(provider: String, configuration: String = "") -> [String: Any] {
        [
            "Desktop": [
                "Content": [
                    "Choices": [[
                        "Provider": provider,
                        "Configuration": Data(configuration.utf8),
                        "Files": [String](),
                    ]],
                ],
                "LastSet": Date(),
            ],
            "Type": "individual",
        ]
    }

    /// Idle（螢保）用的區：只有 Idle、沒有 Desktop。
    private func idleOnly(provider: String) -> [String: Any] {
        [
            "Idle": [
                "Content": ["Choices": [["Provider": provider]]],
            ],
            "Type": "individual",
        ]
    }

    func testFindsExtensionOnItsDisplayOnly() throws {
        try write([
            "AllSpacesAndDisplays": "$null",
            "Displays": [
                "AAAA": desktop(provider: marker, configuration: "some-video-uuid"),
                "BBBB": desktop(provider: "com.apple.wallpaper.choice.image"),
            ],
        ])
        let presence = probe()
        XCTAssertTrue(presence.covers("AAAA"))
        XCTAssertFalse(presence.covers("BBBB"))
        XCTAssertFalse(presence.everywhere)
    }

    func testMarkerInsideConfigurationDataIsFound() throws {
        // Provider 欄位的格式沒有保證——bundle id 埋在 Configuration blob 裡也要找得到
        try write([
            "Displays": [
                "AAAA": desktop(provider: "com.apple.wallpaper.choice.extension",
                                configuration: "identifier=\(marker);choice=shuffle-all"),
            ],
        ])
        XCTAssertTrue(probe().covers("AAAA"))
    }

    func testAllImageStoreIsEmpty() throws {
        try write([
            "AllSpacesAndDisplays": "$null",
            "Displays": [
                "AAAA": desktop(provider: "com.apple.wallpaper.choice.image"),
            ],
            "Spaces": [
                "5CE3DA89": ["Default": desktop(provider: "com.apple.wallpaper.choice.image")],
            ],
        ])
        XCTAssertTrue(probe().isEmpty)
    }

    func testSpaceScopedDisplayOverrideIsAttributed() throws {
        try write([
            "Displays": ["AAAA": desktop(provider: "com.apple.wallpaper.choice.image")],
            "Spaces": [
                "5CE3DA89": [
                    "Default": desktop(provider: "com.apple.wallpaper.choice.image"),
                    "Displays": ["AAAA": desktop(provider: marker)],
                ],
            ],
        ])
        let presence = probe()
        XCTAssertTrue(presence.covers("AAAA"))
        XCTAssertFalse(presence.everywhere)
    }

    func testSpaceDefaultWithoutDisplayIsEverywhere() throws {
        // Space 的 Default 沒寫是哪台螢幕——保守當成每台都有
        try write([
            "Spaces": ["5CE3DA89": ["Default": desktop(provider: marker)]],
        ])
        XCTAssertTrue(probe().everywhere)
        XCTAssertTrue(probe().covers("ANY"))
    }

    func testAllSpacesAndDisplaysConfigIsEverywhere() throws {
        try write(["AllSpacesAndDisplays": desktop(provider: marker)])
        XCTAssertTrue(probe().everywhere)
    }

    func testIdleOnlySelectionDoesNotCoverDesktop() throws {
        // 只選了 Phosphene 當螢幕保護程式：桌面照樣歸蒙太奇管
        try write(["Displays": ["AAAA": idleOnly(provider: marker)]])
        XCTAssertTrue(probe().isEmpty)
    }

    func testMissingOrGarbledStoreIsEmpty() throws {
        XCTAssertTrue(probe().isEmpty, "檔案不存在 → 視同都沒有（退回修正前行為）")
        try Data("not a plist".utf8).write(to: storeURL)
        XCTAssertTrue(probe().isEmpty)
    }

    // MARK: - 這輪要跳過哪些螢幕

    private func target(_ uuid: String, id: CGDirectDisplayID) -> DisplayTarget {
        DisplayTarget(id: id, uuid: uuid, canvas: CGSize(width: 100, height: 100))
    }

    /// 換一批影片時 container 會短暫空著。那個空窗裡照樣不准寫蒙太奇——
    /// 用「備妥幾支」當門就是 0.6.6 那次把使用者的影片桌布擠掉的成因。
    func testSkipsChosenDisplayWhileTheLibraryIsBeingRedeployed() {
        let displays = [target("AAAA", id: 1), target("BBBB", id: 2)]
        let skipped = WallpaperStoreProbe.extensionSkipIDs(
            displays: displays,
            videoWallpaperEnabled: true,
            presence: .init(displayUUIDs: ["AAAA"]),
        )
        XCTAssertEqual(skipped, [1])
    }

    func testEverywhereSkipsAllDisplays() {
        let displays = [target("AAAA", id: 1), target("BBBB", id: 2)]
        let skipped = WallpaperStoreProbe.extensionSkipIDs(
            displays: displays, videoWallpaperEnabled: true, presence: .init(everywhere: true),
        )
        XCTAssertEqual(skipped, [1, 2])
    }

    /// 關掉總開關＝把螢幕交回蒙太奇：container 會被清空，殘留的選擇播不出東西。
    func testTurningTheVideoWallpaperOffReclaimsTheDisplay() {
        let displays = [target("AAAA", id: 1)]
        let skipped = WallpaperStoreProbe.extensionSkipIDs(
            displays: displays,
            videoWallpaperEnabled: false,
            presence: .init(displayUUIDs: ["AAAA"]),
        )
        XCTAssertTrue(skipped.isEmpty)
    }

    /// 沒選我們的螢幕不受影響。
    func testDisplaysWithoutOurChoiceAreNotSkipped() {
        let displays = [target("AAAA", id: 1), target("BBBB", id: 2)]
        let skipped = WallpaperStoreProbe.extensionSkipIDs(
            displays: displays, videoWallpaperEnabled: true, presence: .init(),
        )
        XCTAssertTrue(skipped.isEmpty)
    }

    /// 真機的 Store 讀得動、且目前（全 image）不會誤報。
    /// 在別的環境（CI、沙盒）讀不到檔就跳過，不當失敗。
    func testRealStoreParsesWithoutFalsePositive() throws {
        let real = WallpaperStoreProbe.defaultStoreURL()
        try XCTSkipUnless(FileManager.default.isReadableFile(atPath: real.path))
        _ = WallpaperStoreProbe.extensionPresence(
            marker: "definitely-not-a-real-bundle-id-zzz", storeURL: real)
    }
}
