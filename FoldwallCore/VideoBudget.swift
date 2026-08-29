//  VideoBudget.swift
//  決定「這批影片裡，哪幾支值得拷進 extension container」。
//
//  為什麼需要上限：沙盒 extension 讀不到 app 的 bookmark，影片只能實體拷貝過去
//  （fork 自 Phosphene 的既有契約）。來源資料夾若是一座 NAS，那就是幾百 GB 的複製。
//  實測一個影音相簿在 12 分鐘內拷了 17 GB／9 支就把 228 GB 的機器逼到只剩 5.5 GB。
//
//  純函式、不碰磁碟（檔案大小由呼叫端餵），所以測得到。

import Foundation

public enum VideoBudget {

    /// 一輪最多帶幾支——**不設支數上限**，由 `rotationBytes` 決定帶幾支。
    ///
    /// 影片仍是**輪替**的（每次螢幕重新亮起換一批，不是一次囤滿），只是「一批」
    /// 有多少支交給額度算：全是 40 MB 短片就是幾十支，全是 500 MB 長片就是四支。
    /// 支數固定成 3 的時候，短片庫每輪只帶得走 120 MB，額度形同虛設。
    ///
    /// 仍是可傳入的參數：網路來源要的是「保留 1 個名額」，見 `remoteSlots`。
    public static let rotationCount = Int.max
    /// 一輪的總量上限，也是這條管線唯一的煞車。
    public static let rotationBytes: Int64 = 2 * 1024 * 1024 * 1024
    /// **單檔上限**。這道關卡最有效：桌布循環素材是幾十 MB，不是幾 GB。
    ///
    /// 實測（2026-08-25）沒有這道關卡時，路徑排序最前面的 5 支完整長片
    /// （1.3–2.4 GB）就吃掉 10 GB 額度的 9.7 GB，而真正像桌布的 13 支短片
    /// 加起來只有 300 MB。擋掉巨檔，額度才會花在對的東西上。
    ///
    /// 訂在 1 GB：2 GB 額度下最少仍收得到 2 支，不會一支長片獨佔整輪。
    public static let maxFileBytes: Int64 = 1024 * 1024 * 1024

    public struct Rotation: Sendable, Equatable {
        /// 這一輪要放進 container 的（其餘一律移除）。
        public var selected: [URL] = []
        /// 下一輪從這個索引接著走，達成循環。
        public var nextCursor: Int = 0
        /// 這一輪已用掉的位元組。混合來源時要拿它算剩餘額度。
        public var usedBytes: Int64 = 0

        public init(selected: [URL] = [], nextCursor: Int = 0, usedBytes: Int64 = 0) {
            self.selected = selected
            self.nextCursor = nextCursor
            self.usedBytes = usedBytes
        }
    }

    /// 從 `cursor` 位置往後挑到額度用完為止，挑完把游標推到下一輪的起點（會繞回開頭）。
    ///
    /// 為什麼要輪替而不是囤滿：container 是實體拷貝，一座 NAS 全拷過去就是幾百 GB。
    /// 額度花完就收手，下次螢幕亮起再換一批，整個片庫照樣輪得到。
    /// 片庫總量小於額度時整庫都會帶進去，游標繞回原點——那本來就該是全部。
    public static func rotate(
        _ videos: [URL],
        cursor: Int,
        count: Int = rotationCount,
        totalBytes: Int64 = rotationBytes,
        maxFileBytes: Int64 = maxFileBytes,
        size: (URL) -> Int64?
    ) -> Rotation {
        let ordered = videos.sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
        guard !ordered.isEmpty else { return Rotation() }

        let start = ordered.indices.contains(cursor) ? cursor : 0
        var rotation = Rotation(nextCursor: start)
        var usedBytes: Int64 = 0

        // 最多繞一圈：整批都超過單檔上限時才不會空轉
        for step in 0..<ordered.count {
            let index = (start + step) % ordered.count

            // 讀不到大小（離線／壞檔）或超過單檔上限：這支永遠進不來，游標推過去。
            guard let bytes = size(ordered[index]), bytes <= maxFileBytes else {
                rotation.nextCursor = (index + 1) % ordered.count
                continue
            }
            // 第一支一定收（否則遇到接近上限的檔會整輪空手）
            guard rotation.selected.isEmpty || usedBytes + bytes <= totalBytes else {
                // 額度不夠這支——不是它的錯。游標**停在它身上**，下一輪從它接著走；
                // 推過去的話它每輪都剛好在額度用完的那個位置被跳過，永遠輪不到。
                rotation.nextCursor = index
                break
            }

            rotation.selected.append(ordered[index])
            usedBytes += bytes
            rotation.usedBytes = usedBytes
            rotation.nextCursor = (index + 1) % ordered.count
            if rotation.selected.count >= count { break }
        }
        return rotation
    }

    /// 網路來源（含片單下載）在這一輪的額度裡分到幾個位元組。
    ///
    /// 為什麼要保留額度：實測資料夾有 4596 支、網路只有 6 支，混在一起排序輪替的話，
    /// 游標要繞完 4602 支才會碰到網路那 6 支——實際上永遠輪不到。
    /// 加了來源卻看不到，等於沒加。
    ///
    /// **為什麼是位元組而不是「幾支」**：支數上限拿掉之後，一輪會帶幾十支資料夾影片，
    /// 而網路仍然固定只有一支——比例上等於沒加。改成分額度，網路帶幾支就跟著
    /// 檔案大小走，跟資料夾同一套規則。
    public static let remoteShareDivisor: Int64 = 4

    public static func remoteBytes(
        remoteCount: Int,
        folderCount: Int,
        totalBytes: Int64 = rotationBytes
    ) -> Int64 {
        guard remoteCount > 0 else { return 0 }
        // 沒有資料夾影片時，整輪都給網路
        guard folderCount > 0 else { return totalBytes }
        return totalBytes / remoteShareDivisor
    }

}
