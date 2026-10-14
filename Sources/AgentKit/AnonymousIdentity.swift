import Foundation
import Security

/// A sign-in for trying the assistant before the app has its own: each install
/// is its own user. Dev environment only; the platform refuses it in prod.
///
/// Register `identity: { "kind": "anonymous" }` in the integration contract, then:
///
/// ```swift
/// let agent = AgentClient(baseURL: apiURL, projectId: "my-app",
///                         tokenStore: KeychainTokenStore(account: "my-app"),
///                         idToken: { try AnonymousIdentity.token() })
/// ```
///
/// The token is a random secret kept in this device's Keychain (never synced);
/// the server derives the user id from it and never stores it. Deleting the app
/// or calling `reset()` starts a new user.
public enum AnonymousIdentity {
    static let service = "AgentKit.anonymous"

    /// This install's token, created on first use.
    public static func token(account: String = "default") throws -> String {
        if let existing = try load(account) { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeychainTokenStore.KeychainError(status: status) }
        let token = "anon." + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try save(token, account)
        return token
    }

    /// Forgets this install's token, so the next sign-in is a new user.
    public static func reset(account: String = "default") throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainTokenStore.KeychainError(status: status) }
    }

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func load(_ account: String) throws -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainTokenStore.KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    private static func save(_ token: String, _ account: String) throws {
        let add = query(account).merging([
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { $1 }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainTokenStore.KeychainError(status: status) }
    }
}
