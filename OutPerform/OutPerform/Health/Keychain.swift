//
//  Keychain.swift
//  OutPerform
//
//  Minimal Keychain wrapper for Google OAuth tokens and AI provider keys.
//

import Foundation
import Security

enum Keychain {
    private static let service = "mamilles.OutPerform.google"

    /// Call once at app launch. iOS Keychain survives app deletion, so stale
    /// OAuth tokens from a previous install remain on disk. If UserDefaults was
    /// wiped (fresh install) but tokens exist, silently purge them so the first-
    /// launch experience is clean and no infinite-retry loop can form.
    static func clearIfFreshInstall() {
        let marker = "OutPerform.hasLaunchedBefore"
        if UserDefaults.standard.bool(forKey: marker) { return }
        // First launch after install (or after a wipe) — clear any leftover tokens.
        delete("access_token")
        delete("refresh_token")
        delete("ai.key.anthropic")
        delete("ai.key.openai")
        UserDefaults.standard.set(true, forKey: marker)
    }

    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
