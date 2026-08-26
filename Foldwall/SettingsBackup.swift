//  SettingsBackup.swift
//  把設定備份到 iCloud Drive，以及從那裡還原。
//
//  為什麼是直接寫 iCloud Drive 而不是 NSUbiquitousKeyValueStore／ubiquity container：
//  那兩條路都要 iCloud entitlement，也就要在開發者網站幫 App ID 開 iCloud、
//  要 provisioning profile。v1 不沙盒，直接寫 `~/Library/Mobile Documents/com~apple~CloudDocs/`
//  一行 entitlement 都不用改，而且檔案就躺在使用者自己的 iCloud Drive 裡看得到。

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

    /// iCloud Drive 沒開時是 nil——這時整個備份功能停用，UI 直接說原因。
    let fileURL: URL?
    private(set) var status: Status = .idle
    /// 遠端那份的時間戳與來源機器，給 UI 顯示「找到 1 個備份」那種資訊。
    private(set) var remoteSummary: String?

    /// 上一次寫出／套用的內容。自動同步靠它判斷「真的變了嗎」，
    /// 沒有它就會變成兩台機器互相寫檔的迴圈。
    private var lastSynced: SettingsSnapshot?
    private var lastRemoteModified: Date?

    init() {
        let drive = URL.homeDirectory
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        // iCloud Drive 沒登入／沒開啟時這個目錄不存在
        guard FileManager.default.fileExists(atPath: drive.path(percentEncoded: false)) else {
            self.fileURL = nil
            return
        }
        self.fileURL = drive.appending(path: "Foldwall/settings.json")
    }

    var isAvailable: Bool { fileURL != nil }

    /// 使用者看得懂的路徑，UI 顯示用。
    var displayPath: String {
        guard let fileURL else { return "iCloud Drive 未啟用" }
        let home = URL.homeDirectory.path
        return fileURL.path.hasPrefix(home)
            ? "~" + fileURL.path.dropFirst(home.count)
            : fileURL.path
    }

    // MARK: - 手動

    @discardableResult
    func export(_ snapshot: SettingsSnapshot) -> Bool {
        guard let fileURL else {
            status = .failed("iCloud Drive 未啟用")
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try SettingsSnapshotCodec.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            lastSynced = snapshot
            lastRemoteModified = modificationDate()
            status = .ok("已備份到 iCloud（\(Self.stamp(snapshot.savedAt))）")
            refreshRemoteSummary()
            Log.app.info("設定已備份到 iCloud")
            return true
        } catch {
            status = .failed("備份失敗：\(error.localizedDescription)")
            Log.app.error("設定備份失敗：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 讀回遠端那份。`nil`＝沒有備份或讀不出來（`status` 會說明）。
    func load() -> SettingsSnapshot? {
        guard let fileURL else {
            status = .failed("iCloud Drive 未啟用")
            return nil
        }
        // iCloud 可能只放了佔位符（.icloud），先請系統下載。
        // 這是非同步的，所以這次可能還是讀不到——下一次心跳會再試。
        if !FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
            status = .failed("iCloud 上還沒有備份")
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try SettingsSnapshotCodec.decode(data)
            return snapshot
        } catch SettingsSnapshotCodec.Failure.unsupportedVersion(let version) {
            status = .failed("備份是較新的格式（v\(version)），請先更新這台的 Foldwall")
            return nil
        } catch {
            status = .failed("讀取備份失敗：\(error.localizedDescription)")
            return nil
        }
    }

    /// 匯入成功後由呼叫端回報，讓自動同步知道「這份已經套用了，不要再寫回去」。
    ///
    /// - Parameter quietly: 只記下基準、不改狀態訊息。啟動時遠端內容跟本機一樣，
    ///   那不是一次「匯入」，不該在 UI 上宣稱剛匯入過。
    func didApply(_ snapshot: SettingsSnapshot, quietly: Bool = false) {
        lastSynced = snapshot
        lastRemoteModified = modificationDate()
        if !quietly {
            status = .ok("已從 iCloud 匯入（\(snapshot.deviceName)・\(Self.stamp(snapshot.savedAt))）")
        }
        refreshRemoteSummary()
    }

    /// 遠端那份的內容，不動狀態訊息。自動同步用來判斷「真的有差別嗎」。
    func peekRemote() -> SettingsSnapshot? { peek() }

    // MARK: - 自動同步

    /// 遠端有沒有比我們上次套用的更新的版本。
    ///
    /// 比檔案的修改時間而不是內容：內容比對要每次解 JSON，而這個問題
    /// 每 15 秒的心跳都會問一次。
    func hasNewerRemote() -> Bool {
        guard fileURL != nil, let modified = modificationDate() else { return false }
        guard let last = lastRemoteModified else { return true }
        return modified > last
    }

    /// 本機設定跟上次同步的那份不一樣了。
    func hasLocalChanges(comparedTo snapshot: SettingsSnapshot) -> Bool {
        guard let lastSynced else { return true }
        return !lastSynced.hasSameContent(as: snapshot)
    }

    func revealInFinder() {
        guard let fileURL else { return }
        if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            NSWorkspace.shared.open(fileURL.deletingLastPathComponent())
        }
    }

    func refreshRemoteSummary() {
        guard let snapshot = peek() else {
            remoteSummary = nil
            return
        }
        remoteSummary = "\(snapshot.deviceName)・\(Self.stamp(snapshot.savedAt))"
            + "・\(snapshot.folders.count) 個資料夾・\(snapshot.albums.count) 個相簿"
    }

    // MARK: - 私有

    /// 只讀不改 status——`refreshRemoteSummary` 在心跳上跑，
    /// 不該因為「還沒有備份」就把使用者剛按完按鈕的訊息蓋掉。
    private func peek() -> SettingsSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? SettingsSnapshotCodec.decode(data)
    }

    private func modificationDate() -> Date? {
        guard let fileURL else { return nil }
        return (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
