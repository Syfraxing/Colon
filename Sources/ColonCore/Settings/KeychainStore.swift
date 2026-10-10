import Foundation
import Security

/// Stores the user's Jev API key in the login Keychain. Never logged, never written to disk elsewhere.
/// Callers should read it once off the main thread and cache it (`SuggestionEngine.reloadAPIKey()`),
/// because a Keychain read can block on an access prompt.
public enum KeychainStore {
    private static let service = "so.slayer.Colon"
    private static let account = "jev-api-key"

    public static var jevAPIKey: String? {
        #if DEBUG
        // Development/test override; not honoured in release builds.
        if let env = ProcessInfo.processInfo.environment["JEV_API_KEY"], !env.isEmpty { return env }
        #endif
        var query = baseQuery
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
    public static func setJevAPIKey(_ key: String?) -> Bool {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(trimmed.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
