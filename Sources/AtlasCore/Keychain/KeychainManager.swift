import Foundation
import Security

public final class KeychainManager {
    public static let shared = KeychainManager()
    private let service = "com.atlas.app.keychain"

    public init() {}

    private func itemQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    /// Writes a value, replacing any existing one.
    ///
    /// Updates in place rather than deleting first. A delete-then-add leaves a
    /// window where the old value is gone and the new one has not landed, and
    /// if the add fails the original is simply lost — which is fatal when the
    /// value is the only key to an encrypted database.
    @discardableResult
    public func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query = itemQuery(key)

        let updated = SecItemUpdate(query as CFDictionary,
                                    [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }

        var add = query
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Writes a value only when no item exists yet.
    ///
    /// Returns false rather than overwriting, so a newly minted database key
    /// can never displace one that is already protecting real data.
    public func create(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        var query = itemQuery(key)
        query[kSecValueData as String] = data
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// What a read actually found.
    ///
    /// The difference between "there is no key" and "there is one but I was not
    /// allowed to read it" matters enormously: the first means mint a new one,
    /// the second means stop. Collapsing them into `nil` is how an encrypted
    /// database gets locked away from its own key.
    public enum ReadResult: Equatable {
        case found(String)
        case notFound
        /// Present but unreadable — denied, ACL mismatch, locked keychain.
        case unreadable(OSStatus)
    }

    public func read(key: String) -> ReadResult {
        var query = itemQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                return .unreadable(status)
            }
            return .found(value)
        case errSecItemNotFound:
            return .notFound
        default:
            return .unreadable(status)
        }
    }

    /// True when an item exists, whether or not this process can read it.
    ///
    /// Checked without asking for the data, so it never triggers a prompt.
    public func exists(key: String) -> Bool {
        var query = itemQuery(key)
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) != errSecItemNotFound
    }

    public func get(key: String) -> String? {
        var query = itemQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    public func delete(key: String) -> Bool {
        let status = SecItemDelete(itemQuery(key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
