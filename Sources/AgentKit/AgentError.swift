import Foundation

/// Errors from the platform API, mapped from the response's `code`.
public enum AgentError: Error, Sendable, Hashable, LocalizedError {
    /// The platform session ended (signed out elsewhere, expired, or an earlier
    /// sign-in). The stored session is cleared; the next call signs in again.
    case staleSession(String)
    case invalidRequest(String)
    case forbidden(String)
    case policyDenied(String)
    case notFound(String)
    case conflict(String)
    /// The app asks users before their data goes to AI providers, and this
    /// user hasn't agreed yet. Show the notice (`AgentConsentGate`) and retry.
    case consentRequired(String)
    /// The service couldn't answer just now; safe to retry.
    case unavailable(String)
    /// A status or code this SDK version doesn't know.
    case http(status: Int, code: String?, message: String)
    /// The response wasn't in the expected shape.
    case decoding(String)
    /// The turn kept asking the device for work past the SDK's bound.
    case turnDidNotFinish(rounds: Int)

    init(status: Int, code: String?, message: String) {
        switch code {
        case "stale_session": self = .staleSession(message)
        case "invalid": self = .invalidRequest(message)
        case "forbidden": self = .forbidden(message)
        case "policy_denied": self = .policyDenied(message)
        case "not_found": self = .notFound(message)
        case "conflict": self = .conflict(message)
        case "unavailable": self = .unavailable(message)
        case "consent_required": self = .consentRequired(message)
        default: self = .http(status: status, code: code, message: message)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .staleSession(let m), .invalidRequest(let m), .forbidden(let m), .policyDenied(let m), .notFound(let m),
            .conflict(let m), .consentRequired(let m), .unavailable(let m), .decoding(let m):
            m
        case .http(_, _, let m): m
        case .turnDidNotFinish: "The assistant couldn't finish this response."
        }
    }
}

/// Errors from registering tools.
public enum RegistrationError: Error, Sendable, Hashable {
    case invalidName(String)
    case reservedName(String)
    case duplicateName(String)
    case invalidDescription(String)
}

/// Throw from an action handler when the device can't tell whether the
/// action took effect. The server marks it uncertain and the app settles it
/// later with its `lookup` handler.
public struct OutcomeUnknown: Error, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}
