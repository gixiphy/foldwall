//  PowerPolicy.swift
//  純函式：輸入訊號 → PowerTier。抄 Phosphene 的 full / reduced / paused。
//
//  v1 靜態管線只接得到 thermal 與 battery：occluded / gameMode 沒有乾淨的公開 API，
//  影片端由 extension 自管。簽名保留四個參數給 v2，app 端目前傳 false。

import Foundation

public enum PowerPolicy {

    public static func tier(
        thermal: ProcessInfo.ThermalState,
        onBattery: Bool,
        occluded: Bool,
        gameMode: Bool
    ) -> PowerTier {
        // 停優先於降：太燙／被蓋住／在打遊戲時，換桌布毫無意義
        if gameMode || occluded || thermal == .critical {
            return .paused
        }
        if onBattery || thermal == .serious {
            return .reduced
        }
        return .full
    }
}
