//  VideoSyncPolicy.swift
//  影片同步的節流：跟桌布輪換頻率**脫鉤**。
//
//  桌布可以 5 分鐘換一張——那只是從既有的池抽圖合成，成本很低。
//  影片同步完全是另一回事：掃 container、比帳本、走 SMB 拷幾百 MB。
//  綁在同一個節奏上等於每 5 分鐘就重跑一次這些工，沒有意義。

import Foundation

public enum VideoSyncPolicy {

    /// 兩次影片同步的最短間隔。**不隨桌布間隔變動。**
    public static let minimumInterval: TimeInterval = 30 * 60

    /// - Parameter force: 使用者動作（改來源、開關切換）要立刻生效，不等節流。
    ///   規格要求「移除資料夾 → 該來源的影片同步刪除」，那不能等 30 分鐘。
    public static func shouldSync(
        lastSync: Date?,
        now: Date,
        force: Bool,
        minimumInterval: TimeInterval = minimumInterval
    ) -> Bool {
        if force { return true }
        guard let lastSync else { return true }   // 還沒同步過
        return now.timeIntervalSince(lastSync) >= minimumInterval
    }
}
