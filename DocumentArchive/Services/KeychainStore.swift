import Foundation
import Security

/// Stores secrets (API keys) in the Keychain.
/// Preferably in the iCloud Keychain, so the key is also available on iPhone and iPad.
/// Unsigned development builds are not allowed to use it; then the key is stored locally.
enum KeychainStore {
    static let service = "de.patrickklein.DocumentArchive"

    /// Variants in order of preference: (synchronizable, data protection keychain)
    private static let variants: [(sync: Bool, dataProtection: Bool)] = [
        (true, true), (false, true), (false, false),
    ]

    static func read(_ account: String, service: String = service) -> String? {
        for dataProtection in [true, false] {
            var query = baseQuery(account, dataProtection: dataProtection, service: service)
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data, let value = String(data: data, encoding: .utf8) {
                return value
            }
        }
        return nil
    }

    static func save(_ value: String, for account: String, service: String = service) {
        delete(account, service: service)
        guard !value.isEmpty else { return }
        for variant in variants {
            var query = baseQuery(account, dataProtection: variant.dataProtection, service: service)
            query[kSecAttrSynchronizable as String] = variant.sync
            query[kSecValueData as String] = Data(value.utf8)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            if SecItemAdd(query as CFDictionary, nil) == errSecSuccess { return }
        }
    }

    static func delete(_ account: String, service: String = service) {
        for dataProtection in [true, false] {
            var query = baseQuery(account, dataProtection: dataProtection, service: service)
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            SecItemDelete(query as CFDictionary)
        }
    }

    private static func baseQuery(_ account: String, dataProtection: Bool, service: String = service) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return query
    }
}
