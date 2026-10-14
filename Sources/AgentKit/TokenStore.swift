import Foundation
import Security

/// Where the platform session is kept between launches.
public protocol TokenStore: Sendable {
    func load() async throws -> PlatformSession?
    func save(_ session: PlatformSession) async throws
    func clear() async throws
}

/// Keeps the session in memory only. For tests and previews.
public actor InMemoryTokenStore: TokenStore {
    private var session: PlatformSession?
    public init(_ session: PlatformSession? = nil) { self.session = session }
    public func load() -> PlatformSession? { session }
    public func save(_ session: PlatformSession) { self.session = session }
    public func clear() { session = nil }
}

/// Keeps the session in the Keychain, readable after first unlock and never
/// synced or restored to another device.
public struct KeychainTokenStore: TokenStore {
    public struct KeychainError: Error, Sendable, Hashable {
        public var status: OSStatus
    }

    public let service: String
    public let account: String

    public init(service: String = "AgentKit.session", account: String) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func load() async throws -> PlatformSession? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return try? JSONDecoder().decode(PlatformSession.self, from: data)
    }

    public func save(_ session: PlatformSession) async throws {
        let data = try JSONEncoder().encode(session)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(update) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func clear() async throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
