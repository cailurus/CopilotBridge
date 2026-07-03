import Foundation
import Security

/// Minimal Keychain wrapper for the long-lived GitHub OAuth token.
enum Keychain {
    private static let service = "com.copilotbridge.app.github"
    private static let legacyServices = ["com.copilotbridge.github"]
    private static let account = "oauth-token"

    static func save(_ token: String) {
        save(token, service: service)
    }

    private static func save(_ token: String, service: String) {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add.removeValue(forKey: kSecUseAuthenticationUI as String)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(allowUserInteraction: Bool = false) -> String? {
        if let token = load(service: service, allowUserInteraction: allowUserInteraction) {
            return token
        }
        for legacyService in legacyServices {
            if let token = load(service: legacyService, allowUserInteraction: allowUserInteraction) {
                save(token)
                return token
            }
        }
        return nil
    }

    private static func load(service: String, allowUserInteraction: Bool) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowUserInteraction {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    static func clear() {
        ([service] + legacyServices).forEach { service in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}
