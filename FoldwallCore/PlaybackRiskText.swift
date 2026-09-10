//  PlaybackRiskText.swift
//  `PlaybackRisk` 的說明文字。
//
//  **為什麼獨立一個檔**：`PlaybackRisk` 本身住在 `VideoSourceProfile.swift`，
//  而那個檔兩個 target 各編一份（appex 不連結 FoldwallCore），所以裡面不能出現
//  `Bundle.foldwallCore` 那份字串表。說明文字是要給人看的、要翻譯，
//  就放在這個只給 FoldwallCore 編的檔裡。
//
//  措辭有一條原則：**每一項都是待查方向，不是結論。** 節奏不匹配那條尤其重要
//  ——那是呈現節奏，跑去改播放器沒有用，說明文字必須講清楚。

import Foundation

public extension PlaybackRisk {

    /// 一句話說明這條線索是什麼、以及它指向哪裡。
    var localizedSummary: String {
        switch self {
        case .refreshCadenceMismatch:
            String(localized: "影片幀率與螢幕更新率不整除，會有規律微頓。這是呈現節奏，不是播放器故障。",
                   bundle: .foldwallCore)
        case .frameRateAboveRefresh:
            String(localized: "影片幀率高於螢幕更新率，必然有畫格被丟棄。", bundle: .foldwallCore)
        case .variableFrameRate:
            String(localized: "可變幀率。畫面本身的節奏就不均勻。", bundle: .foldwallCore)
        case .missingSampleDurations:
            String(localized: "部分畫格沒有長度資訊，循環終點只能推導。", bundle: .foldwallCore)
        case .nonZeroTimelineStart:
            String(localized: "影片軌起點不是 0，循環接縫需要正規化才不會錯位。", bundle: .foldwallCore)
        case .nonMonotonicTimestamps:
            String(localized: "呈現時間戳不單調遞增，片源的時間資訊有問題。", bundle: .foldwallCore)
        case .highDecodeLoad:
            String(localized: "解析度或位元率偏高，解碼與合成負載大。", bundle: .foldwallCore)
        case .remoteSource:
            String(localized: "片源不在本機磁碟上，讀取可能斷續。", bundle: .foldwallCore)
        case .hdrTonemapping:
            String(localized: "HDR 片源，多一道色調映射。", bundle: .foldwallCore)
        case .unknownTiming:
            String(localized: "尚未取得時間資訊，無法判斷呈現節奏。", bundle: .foldwallCore)
        }
    }
}
