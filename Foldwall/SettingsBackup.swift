//  SettingsBackup.swift
//  設定在 iCloud Drive 上的兩個檔案：共用的來源目錄，與每台一份的裝置設定。
//
//  ```
//  ~/Library/Mobile Documents/com~apple~CloudDocs/Foldwall/
//    sources.json            ← 三台共讀共寫。自動同步雙向跑這層。
//    devices/
//      工作室 Mac.json        ← 這台的設定。自動同步**只寫不讀**。
//      MacBook Air.json      ← 別台的。要用得在 UI 上明確匯入。
//    settings.json           ← 0.6.x 的舊格式。只讀一次，拆成上面兩份。
//  ```
//
//  **裝置設定為什麼只寫不讀。** 這台的真相在 UserDefaults 裡，iCloud 上那份是備份。
//  每次啟動都拿備份回頭套本機，只會多出一條「拿舊資料蓋新資料」的路徑，
//  而它換來的好處（換新 Mac 時自動接手）本來就要人工介入——新機器的
//  `deviceID` 不一樣，怎麼樣都得使用者自己挑要接哪一台。所以那條路留給按鈕。
//
//  為什麼是直接寫 iCloud Drive 而不是 NSUbiquitousKeyValueStore／ubiquity container：
//  那兩條路都要 iCloud entitlement，也就要在開發者網站幫 App ID 開 iCloud、
//  要 provisioning profile。v1 不沙盒，直接寫 CloudDocs 一行 entitlement 都不用改，
//  而且檔案就躺在使用者自己的 iCloud Drive 裡看得到。

import AppKit
import Foundation
import FoldwallCore

@MainActor
@Observable
final class SettingsBackup {

    enum Status: Equatable {
        case idle
        case ok(String)
        case failed(String)
    }

    /// iCloud Drive 上別台機器留下的一份裝置設定。UI 用它列出「可以匯入誰的」。
    struct DeviceFile: Identifiable, Equatable {
        var id: String { url.path }
        var url: URL
        var deviceName: String
        var deviceID: String
        var savedAt: Date
        /// 是不是這台自己寫的。
        var isSelf: Bool
    }

    /// `Foldwall/` 這層。iCloud Drive 沒開時是 nil——整個備份功能停用，UI 直接說原因。
    private let root: URL?
    private(set) var status: Status = .idle
    /// 遠端目錄的摘要，給 UI 顯示「找到 N 個來源」那種資訊。
    private(set) var catalogSummary: String?
    /// `devices/` 底下有哪些機器。
    private(set) var deviceFiles: [DeviceFile] = []

    /// 這台的身分。名字會被使用者改，所以另外配一個不變的 id 存在本機。
    let deviceName: String
    let deviceID: String

    /// 上一次寫出／套用的來源目錄。自動同步靠它判斷「真的變了嗎」，
    /// 沒有它就會變成三台互相寫檔的迴圈。
    private var lastSyncedCatalog: SourceCatalog?
    private var lastCatalogModified: Date?
    /// 上一次寫出的裝置設定。只用來省掉沒必要的寫檔。
    private var lastSyncedDevice: DeviceSettings?
    /// 這台的檔案叫什麼。撞名時帶 id 後綴，算一次就好。
    private var cachedDeviceFileName: String?

    init(defaults: UserDefaults = .standard) {
        self.deviceName = Host.current().localizedName ?? String(localized: "未命名 Mac")
        self.deviceID = Self.resolveDeviceID(defaults: defaults)

        let drive = URL.homeDirectory
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        // iCloud Drive 沒登入／沒開啟時這個目錄不存在
        guard FileManager.default.fileExists(atPath: drive.path(percentEncoded: false)) else {
            self.root = nil
            return
        }
        self.root = drive.appending(path: "Foldwall")
    }

    /// 這台的長期 id。**不用硬體 UUID**：那要 IOKit、也是個追得到人的識別碼，
    /// 而這裡只需要「同一台機器的兩次啟動認得出彼此」。第一次跑就配一個存下來，
    /// 遷移助理搬過去仍然是同一個 id——那正是我們要的語意（邏輯上還是那台）。
    private static func resolveDeviceID(defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: "deviceID"), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: "deviceID")
        return fresh
    }

    var isAvailable: Bool { root != nil }

    var catalogURL: URL? { root?.appending(path: "sources.json") }
    var devicesDirectory: URL? { root?.appending(path: "devices") }
    /// 0.6.x 的舊備份。只讀不寫。
    var legacyURL: URL? { root?.appending(path: "settings.json") }

    /// 這台的裝置設定檔。
    ///
    /// 檔名用機器名字而不是 id，是因為這些檔案就攤在使用者的 iCloud Drive 裡，
    /// 一排 UUID 檔名等於白放。撞名（兩台都叫 MacBook Pro）時才退回帶 id 後綴——
    /// 判斷依據是檔案裡的 `deviceID`，不是檔名。
    var deviceURL: URL? {
        guard let devicesDirectory else { return nil }
        if let cachedDeviceFileName {
            return devicesDirectory.appending(path: cachedDeviceFileName)
        }
        let plain = Self.sanitize(deviceName) + ".json"
        let candidate = devicesDirectory.appending(path: plain)
        let name: String
        if let occupant = decodeDevice(at: candidate), occupant.deviceID != deviceID,
           !occupant.deviceID.isEmpty {
            name = Self.sanitize(deviceName) + "-" + deviceID.prefix(8) + ".json"
        } else {
            name = plain
        }
        cachedDeviceFileName = name
        return devicesDirectory.appending(path: name)
    }

    /// 檔名裡不能有路徑分隔符；`:` 在 Finder 顯示時會被轉成 `/`，一起擋掉。
    /// 開頭的點會讓檔案在 Finder 裡隱形。
    private static func sanitize(_ name: String) -> String {
        var cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "Mac" : cleaned
    }

    /// 使用者看得懂的路徑，UI 顯示用。
    var displayPath: String {
        guard let root else { return String(localized: "iCloud Drive 未啟用") }
        let home = URL.homeDirectory.path
        return root.path.hasPrefix(home) ? "~" + root.path.dropFirst(home.count) : root.path
    }

    // MARK: - 來源目錄（通用層）

    @discardableResult
    func exportCatalog(_ catalog: SourceCatalog) -> Bool {
        guard let catalogURL else {
            status = .failed(String(localized: "iCloud Drive 未啟用"))
            return false
        }
        do {
            try write(try SyncCodec.encode(catalog), to: catalogURL)
            lastSyncedCatalog = catalog
            lastCatalogModified = modificationDate(of: catalogURL)
            status = .ok(String(localized: "來源已同步到 iCloud（\(Self.stamp(catalog.savedAt))）"))
            refreshSummaries()
            Log.app.info("來源目錄已寫到 iCloud")
            return true
        } catch {
            status = .failed(String(localized: "同步來源失敗：\(error.localizedDescription)"))
            Log.app.error("來源目錄寫入失敗：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 讀回遠端的來源目錄。`nil`＝沒有或讀不出來（`status` 會說明）。
    func loadCatalog() -> SourceCatalog? {
        guard let catalogURL else {
            status = .failed(String(localized: "iCloud Drive 未啟用"))
            return nil
        }
        guard FileManager.default.fileExists(atPath: catalogURL.path(percentEncoded: false)) else {
            // iCloud 可能只放了佔位符（.icloud），先請系統下載。
            // 這是非同步的，所以這次可能還是讀不到——下一次心跳會再試。
            try? FileManager.default.startDownloadingUbiquitousItem(at: catalogURL)
            status = .failed(String(localized: "iCloud 上還沒有來源目錄"))
            return nil
        }
        do {
            return try SyncCodec.decode(
                SourceCatalog.self, from: try Data(contentsOf: catalogURL))
        } catch SyncCodec.Failure.unsupportedVersion(let version) {
            status = .failed(String(localized: "來源目錄是較新的格式（v\(version)），請先更新這台的 Foldwall"))
            return nil
        } catch {
            status = .failed(String(localized: "讀取來源目錄失敗：\(error.localizedDescription)"))
            return nil
        }
    }

    /// 只讀不改 status。自動同步用來判斷「真的有差別嗎」。
    func peekCatalog() -> SourceCatalog? {
        guard let catalogURL, let data = try? Data(contentsOf: catalogURL) else { return nil }
        return try? SyncCodec.decode(SourceCatalog.self, from: data)
    }

    /// 遠端目錄有沒有比我們上次套用的更新的版本。
    ///
    /// 比檔案的修改時間而不是內容：內容比對要每次解 JSON，而這個問題
    /// 每 15 秒的心跳都會問一次。
    func hasNewerCatalog() -> Bool {
        guard let catalogURL, let modified = modificationDate(of: catalogURL) else { return false }
        guard let last = lastCatalogModified else { return true }
        return modified > last
    }

    /// 這台已經跟共用目錄對過帳了嗎。
    ///
    /// 還沒對過的那一次要用「聯集」而不是「以遠端為準」——這台手上的來源
    /// 還沒進過目錄，照減法套下去，打開自動同步的當下來源就被清光了。
    var hasCatalogBaseline: Bool { lastSyncedCatalog != nil }

    func catalogHasLocalChanges(comparedTo catalog: SourceCatalog) -> Bool {
        guard let lastSyncedCatalog else { return true }
        return !lastSyncedCatalog.hasSameContent(as: catalog)
    }

    /// 套用完由呼叫端回報，讓自動同步知道「這份已經套用了，不要再寫回去」。
    ///
    /// - Parameter quietly: 只記下基準、不改狀態訊息。啟動時遠端內容跟本機一樣，
    ///   那不是一次「匯入」，不該在 UI 上宣稱剛匯入過。
    func didApplyCatalog(_ catalog: SourceCatalog, quietly: Bool = false) {
        lastSyncedCatalog = catalog
        lastCatalogModified = catalogURL.flatMap(modificationDate(of:))
        if !quietly {
            status = .ok(String(localized: "已從 iCloud 更新來源（\(catalog.deviceName)・\(Self.stamp(catalog.savedAt))）"))
        }
        refreshSummaries()
    }

    // MARK: - 裝置設定（依設備層）

    @discardableResult
    func exportDevice(_ device: DeviceSettings) -> Bool {
        guard let deviceURL else {
            status = .failed(String(localized: "iCloud Drive 未啟用"))
            return false
        }
        do {
            try write(try SyncCodec.encode(device), to: deviceURL)
            lastSyncedDevice = device
            status = .ok(String(localized: "這台的設定已備份（\(Self.stamp(device.savedAt))）"))
            refreshSummaries()
            return true
        } catch {
            status = .failed(String(localized: "備份這台的設定失敗：\(error.localizedDescription)"))
            Log.app.error("裝置設定寫入失敗：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func deviceHasLocalChanges(comparedTo device: DeviceSettings) -> Bool {
        guard let lastSyncedDevice else { return true }
        return !lastSyncedDevice.hasSameContent(as: device)
    }

    /// 讀某一台的裝置設定。`file` 從 `deviceFiles` 來。
    func loadDevice(_ file: DeviceFile) -> DeviceSettings? {
        guard let decoded = decodeDevice(at: file.url) else {
            status = .failed(String(localized: "讀取「\(file.deviceName)」的設定失敗"))
            return nil
        }
        return decoded
    }

    private func decodeDevice(at url: URL) -> DeviceSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? SyncCodec.decode(DeviceSettings.self, from: data)
    }

    // MARK: - 舊格式

    /// 0.6.x 那份 `settings.json`。拆完就不再看它（`sources.json` 一存在就算拆過了）。
    func loadLegacy() -> SettingsSnapshot? {
        guard let legacyURL,
              FileManager.default.fileExists(atPath: legacyURL.path(percentEncoded: false)),
              let data = try? Data(contentsOf: legacyURL)
        else { return nil }
        return try? SettingsSnapshotCodec.decode(data)
    }

    /// 還沒拆過舊備份：iCloud 上有 0.6.x 的檔，但還沒有新的來源目錄。
    var needsLegacyMigration: Bool {
        guard let catalogURL, let legacyURL else { return false }
        let fm = FileManager.default
        return !fm.fileExists(atPath: catalogURL.path(percentEncoded: false))
            && fm.fileExists(atPath: legacyURL.path(percentEncoded: false))
    }

    // MARK: - UI

    func revealInFinder() {
        guard let root else { return }
        if FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([root])
        } else {
            NSWorkspace.shared.open(root.deletingLastPathComponent())
        }
    }

    func refreshSummaries() {
        if let catalog = peekCatalog() {
            catalogSummary = String(localized: """
                \(catalog.deviceName)・\(Self.stamp(catalog.savedAt))・\
                \(catalog.folders.count) 個資料夾・\
                \(catalog.remoteSources.count + catalog.playlistSources.count) 個網路來源
                """)
        } else {
            catalogSummary = nil
        }
        deviceFiles = scanDeviceFiles()
    }

    /// `devices/` 底下每一份，依時間新到舊。解不開的略過——那可能是使用者
    /// 自己丟進去的東西，不該讓整份清單消失。
    private func scanDeviceFiles() -> [DeviceFile] {
        guard let devicesDirectory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: devicesDirectory, includingPropertiesForKeys: nil)
        else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let device = decodeDevice(at: url) else { return nil }
                return DeviceFile(
                    url: url,
                    deviceName: device.deviceName,
                    deviceID: device.deviceID,
                    savedAt: device.savedAt,
                    // id 為空的是從 0.6.x 拆出來的，那份就是這台寫的
                    isSelf: device.deviceID == deviceID || device.deviceID.isEmpty
                )
            }
            .sorted { $0.savedAt > $1.savedAt }
    }

    // MARK: - 私有

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
