//  KeychainStore.swift
//  API key 放 Keychain，不放 UserDefaults——UserDefaults 是明文 plist。

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
