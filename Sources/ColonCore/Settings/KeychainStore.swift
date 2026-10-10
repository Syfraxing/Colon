import Foundation
import Security

/// Stores the user's API keys (Jev, GIF provider) in the login Keychain. Never logged, never
/// written to disk elsewhere. Callers should read once off the main thread and cache, because a
/// Keychain read can block on an access prompt.
public enum KeychainStore {
    private static let service = "so.slayer.Colon"

    public enum Account: String, Sendable {
        case jev = "jev-api-key"
        case gif = "gif-api-key"
    }

    public static var jevAPIKey: String? {
        #if DEBUG
        // Development/test override; not honoured in release builds.
        if let env = ProcessInfo.processInfo.environment["JEV_API_KEY"], !env.isEmpty { return env }
        #endif
        return key(for: .jev)
    }

    @discardableResult
    public static func setJevAPIKey(_ key: String?) -> Bool {
        setKey(key, for: .jev)
    }

    public static func key(for account: Account) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// Saves the key (update in place, so a failed write never loses the old key). Empty/nil deletes it.
    @discardableResult
    public static func setKey(_ key: String?, for account: Account) -> Bool {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = baseQuery(account)
        guard !trimmed.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(trimmed.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(_ account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }
}
