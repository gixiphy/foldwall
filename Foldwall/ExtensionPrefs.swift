//  ExtensionPrefs.swift
//  app → extension 的設定通道。
//
//  extension 是沙盒的、也不連 FoldwallCore（fork 自 Phosphene，刻意不共用型別，
//  私有 API 斷版時才 rebase 得動上游），所以它讀不到 app 的 UserDefaults。
//  既有的契約是「app 直接寫進 extension 的 container」——影片是這樣送的
//  （見 VideoLibrary），設定也走同一條路：寫 Documents/phosphene-prefs.json，
//  再發一個 Darwin 通知請它重讀（見 extension 的 WallpaperPrefs）。
//
//  **整個檔一次寫完，不是就地改。** 這個檔案只有這裡一個寫入者，
//  extension 只讀不寫；沒寫的欄位一律給 extension 那邊的預設值，
//  也就是「檔案還不存在」時的行為，寫下去不會動到任何既有行為。

import Foundation
import FoldwallCore

/// `VideoLibrary.documentsURL`（container 路徑）在 MainActor 上，整個型別跟著它走；
/// 呼叫端本來就是 WallpaperCoordinator，全都在主執行緒。
@MainActor
enum ExtensionPrefs {

    /// 欄位名與型別必須跟 extension 的 `WallpaperPrefs.PrefsFile` 一致，改一邊等於斷線。
    /// 那幾個 pause 旗標 app 這邊沒有對應設定，一律給 false（＝沒有這個檔時的預設）。
    private struct PrefsFile: Codable {
        var userPaused = false
        var alwaysPauseDesktop = false
        var pauseWhenOccluded = false
        var desktopOccluded = false
        var videoScaleMode: String
    }

    /// 名稱兩側必須一致（見 extension 的 WallpaperPrefs.observeChanges）。
    private static let changedNotification = "app.foldwall.prefsChanged"

    private static var prefsURL: URL {
        VideoLibrary.documentsURL.appending(path: "phosphene-prefs.json")
    }

    static func write(videoScaleMode: VideoScaleMode) {
        let prefs = PrefsFile(videoScaleMode: videoScaleMode.rawValue)
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        do {
            // extension 還沒被系統跑起來過的話 Documents 不一定存在；建了不會有壞處。
            try FileManager.default.createDirectory(
                at: VideoLibrary.documentsURL, withIntermediateDirectories: true)
            try data.write(to: prefsURL, options: .atomic)
        } catch {
            Log.video.error("寫 extension 設定失敗：\(error.localizedDescription, privacy: .public)")
            return
        }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(changedNotification as CFString), nil, nil, true)
    }
}
