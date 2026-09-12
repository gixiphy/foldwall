//  VideoBufferPolicy.swift
//  片源在哪，就該預讀多少。
//
//  桌面視窗那條路本來對每支影片都設同一個 `preferredForwardBufferDuration = 10`。
//  那個值對三種來源都不對：本機檔預讀 10 秒是拿記憶體換一段不會用到的進度
//  （磁碟隨時讀得到），而 NAS 或串流 10 秒根本擋不住一次網路抽風——那正是
//  「有些片會不定時停一下」最可能的來源。
//
//  純邏輯，磁碟查詢由呼叫端做（`location(for:)` 那個 convenience 除外），所以測得到。

import Foundation

/// 片源在哪。決定預讀多少、以及診斷時該不該把「讀取不穩」列為待查方向。
public enum VideoSourceLocation: String, Sendable, Codable, CaseIterable {

    /// 本機磁碟。隨時讀得到，不必囤。
    case localDisk
    /// 掛載的網路磁碟：SMB、AFP、NFS、雲端硬碟的掛載點。
    /// **看起來是檔案路徑，行為卻是網路**——這是最容易被誤判成本機的一種。
    case networkVolume
    /// http(s) 串流。
    case remoteStream
    /// File Provider（Box／iCloud／Dropbox…）底下的檔，**已經下載到本機**。
    /// 這些項目在本機 APFS 卷上，`volumeIsLocal` 會說它是本機——但它隨時可能
    /// 被 provider 收回成 dataless，所以要分開講。讀起來是本機的速度。
    case cloudMaterialized
    /// File Provider 底下的檔，**還沒下載**（或查不到狀態）。第一次讀會觸發整支下載，
    /// 行為是網路。
    case cloudDataless

    public var displayName: String {
        switch self {
        case .localDisk: String(localized: "本機磁碟", bundle: .foldwallCore)
        case .networkVolume: String(localized: "網路磁碟", bundle: .foldwallCore)
        case .remoteStream: String(localized: "網路串流", bundle: .foldwallCore)
        case .cloudMaterialized: String(localized: "雲端硬碟（已下載到本機）", bundle: .foldwallCore)
        case .cloudDataless: String(localized: "雲端硬碟（尚未下載）", bundle: .foldwallCore)
        }
    }

    /// 讀取本身就可能斷續。診斷時「不定時停一下」要先看這個。
    public var isNetworked: Bool { self != .localDisk && self != .cloudMaterialized }
}

public enum VideoBufferPolicy {

    /// 本機檔：夠撐過一次排程延遲就好。
    ///
    /// **不是愈大愈好**：`AVPlayer` 會真的把這段解出來擺著，多台螢幕同時播的話
    /// 那是好幾倍的記憶體，換來的是本機磁碟本來就不需要的保險。
    public static let localSeconds: Double = 4
    /// 網路磁碟：要擋得住一次 SMB 停頓。走 SMB 的非 faststart MP4 光讀檔尾的
    /// moov 就可能好幾秒，播放中的短暫斷流更是常態。
    public static let networkSeconds: Double = 30
    /// 串流：跟網路磁碟同一個量級。再大就只是把「還沒開始播」拖得更久。
    public static let streamSeconds: Double = 30

    public static func forwardBufferSeconds(for location: VideoSourceLocation) -> Double {
        switch location {
        case .localDisk, .cloudMaterialized: localSeconds
        case .networkVolume, .cloudDataless: networkSeconds
        case .remoteStream: streamSeconds
        }
    }

    /// - Parameters:
    ///   - url: 片源。
    ///   - isLocalVolume: 這個檔案路徑所在的卷是不是本機的（`volumeIsLocalKey`）。
    ///     **查不到就傳 nil**——那時當成網路磁碟：猜錯的代價不對稱，
    ///     把網路當本機是播到一半卡住，把本機當網路只是多預讀一點。
    ///   - isCloudItem: 是不是 File Provider 的項目（`isUbiquitousItemKey`，或路徑在
    ///     `~/Library/CloudStorage` 底下）。Box／iCloud 的檔在本機 APFS 卷上，
    ///     `isLocalVolume` 會說是本機——這個旗標才分得出來。
    ///   - isMaterialized: 雲端項目已經下載到本機了嗎（`ubiquitousItemDownloadingStatus ==
    ///     .current`）。**查不到就傳 nil**，當成還沒下載。
    public static func location(
        for url: URL, isLocalVolume: Bool?, isCloudItem: Bool = false, isMaterialized: Bool? = nil
    ) -> VideoSourceLocation {
        guard url.isFileURL else { return .remoteStream }
        if isCloudItem { return isMaterialized == true ? .cloudMaterialized : .cloudDataless }
        return isLocalVolume == true ? .localDisk : .networkVolume
    }

    /// `~/Library/CloudStorage` 是 macOS 放 File Provider 掛載點的地方。
    /// `isUbiquitousItemKey` 對某些 provider 查不到，路徑是第二道判斷。
    public static func isCloudStoragePath(_ path: String, home: URL = URL.homeDirectory) -> Bool {
        // `.path` 會把尾巴的斜線吃掉，自己補：不然 `CloudStorageX` 也會過。
        path.hasPrefix(home.appending(path: "Library/CloudStorage").path + "/")
    }

    /// 會碰磁碟的版本。查不到卷資訊就走 `location(for:isLocalVolume:)` 的保守分支。
    public static func location(for url: URL) -> VideoSourceLocation {
        guard url.isFileURL else { return .remoteStream }
        let values = try? url.resourceValues(forKeys: [
            .volumeIsLocalKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ])
        let isCloud = values?.isUbiquitousItem == true || isCloudStoragePath(url.path)
        let materialized: Bool? = values?.ubiquitousItemDownloadingStatus.map { $0 == .current }
        return location(for: url, isLocalVolume: values?.volumeIsLocal,
                        isCloudItem: isCloud, isMaterialized: materialized)
    }

    /// 直接給 `AVPlayerItem.preferredForwardBufferDuration` 的值。
    public static func forwardBufferSeconds(for url: URL) -> Double {
        forwardBufferSeconds(for: location(for: url))
    }
}
