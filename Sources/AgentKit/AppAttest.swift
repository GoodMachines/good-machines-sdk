import CryptoKit
import Foundation
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// Proves to the hosted API that requests come from this app on a real
/// device, with Apple's App Attest. When the developer requires attestation,
/// the API opens sessions only with this proof, so a script that copied the
/// app's endpoint and sign-in can't use the assistant.
public protocol AppAttestor: Sendable {
    /// The key this install attested before, if any.
    func storedKeyId() async -> String?
    /// Makes a new key and has Apple attest it for `clientDataHash`.
    func attestNewKey(clientDataHash: Data) async throws -> (keyId: String, attestation: Data)
    /// Signs `clientDataHash` with the attested key.
    func assertion(keyId: String, clientDataHash: Data) async throws -> Data
    /// Remembers the key once the API accepted it, or forgets it (nil) when the API no longer knows it.
    func store(keyId: String?) async
}

struct AttestationProof: Codable, Sendable {
    var keyId: String
    var assertion: String
    var challenge: String
}

#if canImport(DeviceCheck)
/// App Attest through `DCAppAttestService`. Works on a real iPhone or iPad
/// with the App Attest capability; not in the Simulator.
public struct AppAttestService: AppAttestor {
    private let defaultsKey: String

    /// - Parameter account: Keeps keys apart per project; use the project id.
    public init(account: String) {
        defaultsKey = "AgentKit.appAttestKey.\(account)"
    }

    public static var isSupported: Bool { DCAppAttestService.shared.isSupported }

    public func storedKeyId() async -> String? { UserDefaults.standard.string(forKey: defaultsKey) }

    public func attestNewKey(clientDataHash: Data) async throws -> (keyId: String, attestation: Data) {
        guard DCAppAttestService.shared.isSupported else { throw AgentError.invalidRequest("App Attest isn't available on this device.") }
        let keyId = try await DCAppAttestService.shared.generateKey()
        let attestation = try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)
        return (keyId, attestation)
    }

    public func assertion(keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash)
    }

    public func store(keyId: String?) async {
        if let keyId { UserDefaults.standard.set(keyId, forKey: defaultsKey) } else { UserDefaults.standard.removeObject(forKey: defaultsKey) }
    }
}
#endif

extension AgentClient {
    private struct Challenge: Decodable { var challenge: String }
    private struct OKBody: Decodable {}

    private func challenge() async throws -> String {
        struct Body: Encodable { var projectId: String }
        let c: Challenge = try await send("POST", "attest/challenge", body: Body(projectId: projectId), authorized: false)
        return c.challenge
    }

    /// An assertion for a fresh challenge, attesting a key first if this install has none.
    func attestationProof(_ attestor: any AppAttestor) async throws -> AttestationProof {
        let hash = { (s: String) in Data(SHA256.hash(data: Data(s.utf8))) }
        var keyId = await attestor.storedKeyId()
        if keyId == nil {
            struct Body: Encodable { var projectId: String; var keyId: String; var attestation: String; var challenge: String }
            let c = try await challenge()
            let made = try await attestor.attestNewKey(clientDataHash: hash(c))
            let _: OKBody = try await send(
                "POST", "attest/keys",
                body: Body(projectId: projectId, keyId: made.keyId, attestation: made.attestation.base64EncodedString(), challenge: c),
                authorized: false)
            await attestor.store(keyId: made.keyId)
            keyId = made.keyId
        }
        let c = try await challenge()
        do {
            let assertion = try await attestor.assertion(keyId: keyId!, clientDataHash: hash(c))
            return AttestationProof(keyId: keyId!, assertion: assertion.base64EncodedString(), challenge: c)
        } catch {
            // The key is gone (e.g. the app was restored to a new device): attest a new one next time.
            await attestor.store(keyId: nil)
            throw error
        }
    }
}
