import Foundation
import Security

/// Where the Claude tokens live. `Keychain` in the app; an in-memory stub in tests.
public protocol SecretStore: Sendable {
    func read(_ account: String) -> Data?
    func write(_ data: Data, for account: String)
    func delete(_ account: String)
}

/// Generic-password items owned by this app. The only place secrets are persisted.
public struct Keychain: SecretStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func read(_ account: String) -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    public func write(_ data: Data, for account: String) {
        let update = [kSecValueData as String: data] as CFDictionary
        if SecItemUpdate(base(account) as CFDictionary, update) == errSecItemNotFound {
            var add = base(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    private func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
