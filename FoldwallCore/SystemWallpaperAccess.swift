//  SystemWallpaperAccess.swift
//  系統圖片桌布 extension 替我們產的 BMP 快取在 WallpaperAgent 的 container 裡。macOS 的
//  「App 資料」保護對非沙盒的 Foldwall 一樣生效，而且**不跳授權框**：沒有「完全取用
//  磁碟」時 sandboxd 直接回 denied。WallpaperImageCache 讀不到目錄會靜默當成沒東西可清，
//  所以動手前先問這裡，UI 才講得出為什麼沒清。
//
//  「你的照片」清單（extension.image container 裡的 Preferences plist）另外帶 com.apple.macl：
//  開了完全取用磁碟，sandboxd 仍要一道 App 資料授權框、又不給跳，所以讀不到，也不清它。
//  macOS 27 每輪會取代 Foldwall 那筆紀錄，清單本來就不再累積（2026-09-16 實測）。

import Darwin
import Foundation

public enum SystemWallpaperAccess: Sendable, Equatable {
    /// 讀得到，清理照常跑。
    case granted
    /// 被系統擋下：要去「完全取用磁碟」打開 Foldwall。
    case denied
    /// 系統圖片桌布還沒產過快取，沒有東西要清。
    case notNeeded

    public static func check(home: URL = .homeDirectory) -> SystemWallpaperAccess {
        check(directory: WallpaperImageCache.defaultDirectory(home: home))
    }

    /// 用 opendir 而不是 FileManager：要分得出 EPERM／EACCES 與 ENOENT。
    /// 被擋時 kernel 會記一筆 sandbox violation，那是預期的。
    static func check(directory: URL) -> SystemWallpaperAccess {
        guard let dir = opendir(directory.path) else {
            let code = errno
            return code == ENOENT || code == ENOTDIR ? .notNeeded : .denied
        }
        closedir(dir)
        return .granted
    }
}
