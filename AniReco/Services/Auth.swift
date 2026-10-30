import Foundation
import Security

/// Tiny Keychain wrapper for the AniList access token.
enum Keychain {
    private static let service = "AniReco"

    private static func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    static func set(_ value: String?, for key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = baseQuery(key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum AniListAuth {
    /// Must match the redirect URL registered at https://anilist.co/settings/developer
    static let callbackScheme = "anireco"
    static let redirectURL = "anireco://auth"

    /// Implicit grant: AniList sends the token back in the URL fragment.
    static func authorizeURL(clientId: String) -> URL? {
        let trimmed = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Int(trimmed) != nil else { return nil }
        return URL(string: "https://anilist.co/api/v2/oauth/authorize?client_id=\(trimmed)&response_type=token")
    }

    /// Pulls access_token out of anireco://auth#access_token=...&token_type=Bearer&expires_in=...
    static func token(from url: URL) -> String? {
        let raw = url.fragment ?? url.query ?? ""
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0] == "access_token" {
                return parts[1].removingPercentEncoding ?? parts[1]
            }
        }
        return nil
    }
}
