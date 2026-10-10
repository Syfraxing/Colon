import Foundation
import Security

/// Stores the user's Jev API key in the login Keychain. Never logged, never written to disk elsewhere.
public enum KeychainStore {
    private static let service = "so.slayer.Emojify"
    private static let account = "jev-api-key"

    /// Environment override for development and tests: `JEV_API_KEY`.
    public static var jevAPIKey: String? {
        if let env = ProcessInfo.processInfo.environment["JEV_API_KEY"], !env.isEmpty { return env }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// Saves (or deletes when empty) the key.
    @discardableResult
    public static func setJevAPIKey(_ key: String?) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return true }
        var query = baseQuery
        query[kSecValueData as String] = Data(trimmed.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
