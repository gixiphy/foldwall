//  WallpaperStoreProbe.swift
//  從系統桌布設定（com.apple.wallpaper 的 Store/Index.plist）找出
//  「桌布選擇指著我們 extension」的螢幕。
//
//  為什麼需要它：extension 引擎下，哪台螢幕播影片是使用者在**系統設定**裡選的，
//  app 的 videoScreens 是空的——蒙太奇因此不知道該跳過誰，每輪 refresh 都把
//  前景 Space 的影片桌布擠成圖片（setDesktopImageURL 會改寫該 Space 的桌布選擇）。
//  這個檔案是系統桌布選擇的真相來源，公開 API 沒有等價的查詢。
//
//  **只認 Desktop 區，不看 Idle。** Idle 是螢幕保護程式的位子，跟桌面上的
//  蒙太奇不衝突——只選了 Phosphene 當螢保的螢幕，桌面照樣歸蒙太奇管。
//
//  比對用位元組搜尋而不是解析 Provider 欄位的格式：選擇的 Configuration 是
//  內嵌的 binary plist blob，系統要能拉起我們的 appex，bundle id 一定得出現在
//  這棵子樹的某處；搜位元組對格式變動最不敏感。讀不到檔（沙盒、路徑變了）
//  就回「都沒有」——行為退回修正前，不會反過來把蒙太奇凍住。

import Foundation

public enum WallpaperStoreProbe {

    /// 哪些螢幕的桌布選擇指著 extension。
    public struct ExtensionPresence: Equatable, Sendable {
        /// 出現在「所有空間與顯示器」或無法歸到特定螢幕的區段（某個 Space 的
        /// Default）——保守當成每台螢幕都有。
        public var everywhere = false
        public var displayUUIDs: Set<String> = []

        public init(everywhere: Bool = false, displayUUIDs: Set<String> = []) {
            self.everywhere = everywhere
            self.displayUUIDs = displayUUIDs
        }

        public func covers(_ displayUUID: String) -> Bool {
            everywhere || displayUUIDs.contains(displayUUID)
        }

        public var isEmpty: Bool { !everywhere && displayUUIDs.isEmpty }
    }

    public static func defaultStoreURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appending(path: "Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    /// 掃 Store，回報 `marker`（extension 的 bundle id）出現在哪些螢幕的 Desktop 選擇裡。
    ///
    /// Store 的形狀（macOS 14+，實機觀察）：
    ///   Displays: [螢幕 UUID: {Desktop, Idle, Type}]           ← 各螢幕的預設
    ///   Spaces:   [Space UUID: {Default: {…}, Displays: […]}]  ← 各 Space 的覆寫
    ///   AllSpacesAndDisplays: "$null" 或一份 {Desktop, Idle}
    public static func extensionPresence(
        marker: String,
        storeURL: URL? = nil
    ) -> ExtensionPresence {
        let url = storeURL ?? defaultStoreURL()
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any]
        else { return ExtensionPresence() }

        var presence = ExtensionPresence()
        let markerBytes = Data(marker.utf8)

        if desktopSection(of: root["AllSpacesAndDisplays"], contains: markerBytes) {
            presence.everywhere = true
        }
        merge(displayMap: root["Displays"], marker: markerBytes, into: &presence)
        for space in ((root["Spaces"] as? [String: Any]) ?? [:]).values {
            guard let space = space as? [String: Any] else { continue }
            // Space 的 Default 沒有寫是哪台螢幕的——保守當成每台都有。
            if desktopSection(of: space["Default"], contains: markerBytes) {
                presence.everywhere = true
            }
            merge(displayMap: space["Displays"], marker: markerBytes, into: &presence)
        }
        return presence
    }

    private static func merge(
        displayMap: Any?, marker: Data, into presence: inout ExtensionPresence
    ) {
        for (uuid, config) in (displayMap as? [String: Any]) ?? [:]
        where desktopSection(of: config, contains: marker) {
            presence.displayUUIDs.insert(uuid)
        }
    }

    /// 這個節點的 Desktop 子樹裡有沒有那串位元組。
    /// 重新序列化成 binary plist 再搜：字串與 Data blob 的內容都會原樣進到位元組流。
    private static func desktopSection(of node: Any?, contains marker: Data) -> Bool {
        guard let node = node as? [String: Any],
              let desktop = node["Desktop"],
              let data = try? PropertyListSerialization.data(
                  fromPropertyList: desktop, format: .binary, options: 0)
        else { return false }
        return data.range(of: marker) != nil
    }
}
