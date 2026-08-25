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

    /// 彙整資料夾：三個快取目錄裡的圖在這裡各有一個硬連結，
    /// 讓系統的螢幕保護程式能一次指到全部。放在 ~/Pictures 是因為使用者找得到。
    public var aggregateFolder: URL {
        URL.homeDirectory.appending(path: "Pictures/Foldwall")
    }

    /// 從網址下載的影片。放 ~/Movies 而不是 Caches：那是使用者主動要的東西，
    /// 不該被系統當快取清掉。
    public var downloadedVideos: URL {
        URL.homeDirectory.appending(path: "Movies/Foldwall")
    }

    /// 要彙整進去的來源目錄。
    public var aggregateSources: [URL] { [remoteCache, photosCache, smbCache] }

    /// 給設定視窗列表用。**只分照片與影片兩組**——使用者心裡只有這兩類，
    /// 不需要知道網路下載、相簿匯出、SMB 副本各自躺在哪個子目錄。
    ///
    /// 合成輸出（wallpapers）刻意不在這裡：那是正掛在桌面上的檔案，不是快取。
    ///
    /// - Parameter videoContainer: extension 的 container 不歸 AppPaths 管，由 app 層傳入。
    public func locations(videoContainer: URL? = nil) -> [CacheLocation] {
        [
            CacheLocation(
                id: "photos", name: "照片",
                purpose: "網路來源下載的原圖、照片相簿匯出，以及合成前從網路磁碟拷回來的副本。"
                    + "想讓螢幕保護程式播這些，來源就指下面這個路徑。",
                // 複製路徑要給**彙整資料夾**：三個快取分開放，螢保只能指一個目錄，
                // 給其中任何一個都會漏掉另外兩個的圖。
                url: aggregateFolder,
                members: [remoteCache, photosCache, smbCache],
                isPurgeable: true),
            CacheLocation(
                id: "videos", name: "影片",
                purpose: "Pexels 下載的影片，以及這一輪輪替中、已拷進影片 extension 的那幾支。",
                url: remoteVideoCache,
                members: [remoteVideoCache] + (videoContainer.map { [$0] } ?? []),
                isPurgeable: true),
        ]
    }

    public func ensureDirectories() throws {
        for dir in [wallpapers, smbCache] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
