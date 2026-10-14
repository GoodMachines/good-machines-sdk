import Foundation

/// Whether the user agreed to send their data to AI providers, and the notice
/// they're shown. `required` is false when the developer didn't ask for consent.
public struct ConsentStatus: Codable, Sendable, Hashable {
    public var required: Bool
    public var version: Int
    public var granted: Bool
    public var text: String
    public var recipients: [String]

    public init(required: Bool, version: Int, granted: Bool, text: String, recipients: [String]) {
        self.required = required
        self.version = version
        self.granted = granted
        self.text = text
        self.recipients = recipients
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        required = try c.decode(Bool.self, forKey: .required)
        granted = try c.decode(Bool.self, forKey: .granted)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        recipients = try c.decodeIfPresent([String].self, forKey: .recipients) ?? []
    }
}

/// What deleting the user's assistant data removed.
public struct ErasureReport: Codable, Sendable, Hashable {
    public var memories: [String]
    public var conversations: Int
    public var messages: Int
    public var assistantSettingsReset: Bool
}

extension AgentClient {
    /// The consent notice for the signed-in user and whether they agreed.
    public func consentStatus() async throws -> ConsentStatus {
        try await send("GET", "consent")
    }

    /// Records the user's answer to the notice version they were shown.
    public func setConsent(version: Int, granted: Bool) async throws -> ConsentStatus {
        struct Body: Encodable { var version: Int; var granted: Bool }
        return try await send("POST", "consent", body: Body(version: version, granted: granted))
    }

    /// Everything the platform keeps about the signed-in user, as JSON: memories,
    /// conversations, their assistant settings, action receipts and consent.
    /// The app's own data isn't included.
    public func exportMyData() async throws -> Data {
        let request = try await makeRequest("GET", "me/data", body: Optional<String>.none, authorized: true, accept: "application/json")
        let (data, response) = try await urlSession.data(for: request)
        try await check(response, data, authorized: true)
        return data
    }

    /// Deletes the signed-in user's memories, conversations and assistant
    /// settings. App data, action receipts and the consent answer stay.
    public func deleteMyData() async throws -> ErasureReport {
        struct Response: Decodable { var removed: ErasureReport }
        let r: Response = try await send("DELETE", "me/data")
        return r.removed
    }
}
