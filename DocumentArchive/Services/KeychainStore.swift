import Foundation
import Security

/// Speichert Geheimnisse (API-Schlüssel) im Schlüsselbund.
/// Wenn möglich im iCloud-Schlüsselbund, damit der Schlüssel auch auf iPhone und iPad bereitsteht.
/// Unsignierte Entwicklungs-Builds haben dafür keine Berechtigung – dann wird lokal gespeichert.
enum KeychainStore {
    static let service = "de.patrickklein.DocumentArchive"

    /// Varianten in absteigender Präferenz: (synchronisieren, Data-Protection-Schlüsselbund)
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
