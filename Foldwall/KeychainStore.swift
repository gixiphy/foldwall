//  KeychainStore.swift
//  API key 放 Keychain，不放 UserDefaults——UserDefaults 是明文 plist。
//
//  **不同步到其他裝置。** 試過走 iCloud 鑰匙串（`kSecAttrSynchronizable`），
//  但那要 data protection keychain，而它在 macOS 上需要 `application-identifier`
//  或 `keychain-access-groups` entitlement——兩者都是受限 entitlement，
//  要 provisioning profile 才會被系統接受。實測：只簽上去不帶 profile，
//  SecItemAdd 回 -34018；把 entitlement 硬簽進去則是 binary 一執行就被 SIGKILL。
//
//  所以設定備份（SettingsSnapshot）也不收金鑰——那份是明文 JSON。
//  換機器時 API key 要在「來源」分頁重輸一次。

import Foundation
import Security

enum KeychainStore {

    private static let service = "app.foldwall"

    enum Failure: Error {
        case status(OSStatus)
    }

    static func set(_ value: String?, for account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        guard let value, !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw Failure.status(status)
            }
            return
        }

        let data = Data(value.utf8)
        let update = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(base as CFDictionary, update)

        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = base
            insert[kSecValueData as String] = data
            // 只在本機解鎖後可讀，不同步到其他裝置
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Failure.status(addStatus) }
        default:
            throw Failure.status(status)
        }
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasKey(_ account: String) -> Bool {
        get(account)?.isEmpty == false
    }
}
