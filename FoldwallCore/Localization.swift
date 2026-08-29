//  Localization.swift
//  Core 是獨立 framework，字串表在自己的 bundle 裡。`String(localized:)` 不指定
//  bundle 的話查的是 Bundle.main（＝Foldwall.app），查不到就把 key 原樣回傳——
//  key 是中文，所以英文系統下會靜默退回中文、看起來像「翻譯漏了」而不是像壞掉。
//  Core 裡每一次查表都要帶 `bundle: .foldwallCore`。

import Foundation

extension Bundle {

    /// FoldwallCore.framework 自己。
    ///
    /// 用 computed 而非 static let：Bundle 在 Swift 6 的嚴格併發下不是 Sendable，
    /// 存成全域常數會是編譯錯誤。`Bundle(for:)` 本身有快取，重複呼叫不貴。
    public static var foldwallCore: Bundle { Bundle(for: FoldwallCoreBundleToken.self) }
}

/// 只為了給 `Bundle(for:)` 定位用的空類別。
final class FoldwallCoreBundleToken {}
