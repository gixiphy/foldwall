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

    public func ensureDirectories() throws {
        for dir in [wallpapers, smbCache] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
