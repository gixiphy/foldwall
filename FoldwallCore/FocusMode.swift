//  FocusMode.swift
//  讀 macOS「專注模式」的目前狀態。
//
//  **沒有公開 API 能拿到模式名稱。** `INFocusStatusCenter` 只回答「有沒有開啟」，
//  而且要 `com.apple.developer.focus-status` entitlement。使用者要的是
//  「工作模式時暫停影片」——那需要知道是**哪個**模式。
//
//  折衷：讀使用者自己家目錄下的 `~/Library/DoNotDisturb/DB/*.json`。
//  這不是私有 API 呼叫，是讀檔；Foldwall 不沙盒，讀得到。代價是格式沒有保證，
//  macOS 大版本可能改。所以這裡**所有解析都是寬容的**：解不出來就回 nil，
//  當成「沒有啟用專注模式」，規則不生效——絕不因此讓桌布壞掉。

import Foundation

public struct FocusMode: Sendable, Equatable, Identifiable, Hashable {
    /// 例：`com.apple.focus.work`
    public var id: String
    /// 使用者看到的名稱（已在地化），例：`工作`
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum FocusModeParser {

    /// 從 `ModeConfigurations.json` 取出所有模式（識別碼 → 名稱）。
    public static func modes(configurations data: Data) -> [FocusMode] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]]
        else { return [] }

        var found: [FocusMode] = []
        for entry in entries {
            guard let configs = entry["modeConfigurations"] as? [String: Any] else { continue }
            for (identifier, value) in configs {
                let mode = (value as? [String: Any])?["mode"] as? [String: Any]
                let name = mode?["name"] as? String
                found.append(FocusMode(id: identifier, name: name ?? identifier))
            }
        }
        // 固定順序：設定視窗的清單不該每次開都跳動
        return found.sorted { $0.name < $1.name }
    }

    /// 從 `Assertions.json` 取出**目前啟用中**的模式識別碼。
    ///
    /// 關鍵在 `storeAssertionRecords`：那才是生效中的。同一個檔案裡的
    /// `storeInvalidationRecords` 是**已經結束**的歷史紀錄，讀錯的話會永遠以為
    /// 某個模式還開著。
    public static func activeModeID(assertions data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]]
        else { return nil }

        for entry in entries {
            guard let records = entry["storeAssertionRecords"] as? [[String: Any]] else { continue }
            for record in records {
                let details = record["assertionDetails"] as? [String: Any]
                if let identifier = details?["assertionDetailsModeIdentifier"] as? String {
                    return identifier
                }
            }
        }
        return nil
    }
}
