//  ScreenBridge.swift
//  AppKit ↔ FoldwallCore 的轉接層。Core 不認識 NSScreen。

import AppKit
import FoldwallCore

extension NSScreen {
    /// 執行期 display id。重開機／熱插拔可能改變，**不要持久化**。
    var foldwallDisplayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// 穩定識別，持久化用（videoScreens 存這個）。
    var foldwallDisplayUUID: String? {
        guard let id = foldwallDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    var foldwallTarget: DisplayTarget? {
        guard let id = foldwallDisplayID, let uuid = foldwallDisplayUUID else { return nil }
        return DisplayTarget(
            id: id,
            uuid: uuid,
            canvas: DisplayTarget.canvasSize(frame: frame.size, scale: backingScaleFactor)
        )
    }
}

@MainActor
enum ScreenBridge {
    /// 目前接上的螢幕。鏡像時系統只回一台，自然退化成單螢行為。
    static func currentDisplays() -> [DisplayTarget] {
        NSScreen.screens.compactMap(\.foldwallTarget)
    }

    static func displayID(forUUID uuid: String) -> CGDirectDisplayID? {
        NSScreen.screens.first { $0.foldwallDisplayUUID == uuid }?.foldwallDisplayID
    }

    /// 設備名稱（"Built-in Retina Display"、"AG493UCX2"…）。
    /// 現拔現查而不是存進 DisplayTarget：那個型別在 Core 裡、要能被純邏輯測試建構，
    /// 而名稱只有 AppKit 拿得到，且螢幕被拔掉後就查不到了。
    static func localizedName(forUUID uuid: String) -> String? {
        NSScreen.screens.first { $0.foldwallDisplayUUID == uuid }?.localizedName
    }
}

/// 公開 API，不碰私有 framework：私有 API 掛了蒙太奇還能用。
struct WorkspaceDesktopSetting: DesktopSetting {
    func setDesktopImageURL(_ url: URL, for screenID: CGDirectDisplayID) async throws {
        try await MainActor.run {
            guard let screen = NSScreen.screens.first(where: { $0.foldwallDisplayID == screenID })
            else { return }   // 螢幕在合成期間被拔掉：靜靜跳過，下輪重讀清單
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
    }
}
