//  AppPaths.swift
//  活動桌布放 Application Support（Caches 會被系統清 → 重登入黑屏）。
//  只有可重建的東西（SMB 拷貝）才放 Caches。

import Foundation

public struct AppPaths: Sendable {

    public var applicationSupport: URL
    public var caches: URL

    public init(applicationSupport: URL, caches: URL) {
        self.applicationSupport = applicationSupport
        self.caches = caches
    }

    public static func standard(bundleName: String = "Foldwall") -> AppPaths {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                   appropriateFor: nil, create: false))
            ?? URL.homeDirectory.appending(path: "Library/Application Support")
        let caches = (try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                                  appropriateFor: nil, create: false))
            ?? URL.homeDirectory.appending(path: "Library/Caches")
        return AppPaths(applicationSupport: support.appending(path: bundleName),
                        caches: caches.appending(path: bundleName))
    }

    /// 目前掛在桌面上的 JPEG。
    public var wallpapers: URL { applicationSupport.appending(path: "wallpapers") }
    /// SMB 來源的本機拷貝（可重建，可被清）。
    public var smbCache: URL { caches.appending(path: "smb") }
    /// 網路來源下載的原圖。
    public var remoteCache: URL { caches.appending(path: "remote") }
    /// 照片相簿匯出的圖。
    public var photosCache: URL { caches.appending(path: "photos") }
    /// Pexels 影片。
    public var remoteVideoCache: URL { caches.appending(path: "remoteVideos") }

    /// 給設定視窗列表用：使用者常需要知道「東西到底放在哪」，
    /// 尤其是要把系統的螢幕保護程式指到某個資料夾時。
    public var locations: [CacheLocation] {
        [
            CacheLocation(
                id: "wallpapers", name: "合成輸出",
                purpose: "目前掛在桌面上的蒙太奇。只留當前輪＋上一輪，指螢保過去只會有兩張圖。",
                url: wallpapers, isPurgeable: false),
            CacheLocation(
                id: "remote", name: "網路來源原圖",
                purpose: "從 Unsplash／Pexels／Wallhaven 等下載的原圖。想讓螢幕保護程式播這些，來源就指這裡。",
                url: remoteCache, isPurgeable: true),
            CacheLocation(
                id: "photos", name: "照片相簿匯出",
                purpose: "從「照片」選定相簿匯出的圖。",
                url: photosCache, isPurgeable: true),
            CacheLocation(
                id: "smb", name: "SMB 本機副本",
                purpose: "合成前從網路磁碟拷回來的原圖，總量上限 2GB、LRU 淘汰。",
                url: smbCache, isPurgeable: true),
            CacheLocation(
                id: "remoteVideos", name: "網路影片",
                purpose: "Pexels 影片下載，總量上限 2GB。",
                url: remoteVideoCache, isPurgeable: true),
        ]
    }

    public func ensureDirectories() throws {
        for dir in [wallpapers, smbCache] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
