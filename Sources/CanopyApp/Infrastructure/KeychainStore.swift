import Foundation
import Security

protocol SecretStoring {
    func read(_ account: String) throws -> String
    func write(_ value: String, account: String) throws
}

struct KeychainStore: SecretStoring {
    // Stable across the rename so existing API keys remain available.
    #if CANOPY_APP_STORE
    private let service = "com.canopy.desktop.appstore.credentials"
    #else
    private let service = "com.canopy.desktop.credentials"
    #endif
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func read(_ account: String) throws -> String {
        var query = query(account)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8)
        else { throw KeychainError(status: status) }
        return value
    }
    func write(_ value: String, account: String) throws {
        let query = query(account)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Keychain could not save or read the key (\(status))." }
}
