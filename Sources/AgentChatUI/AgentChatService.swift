import AgentKit
import Foundation

/// What the chat needs from the platform. `AgentClient` provides it; previews
/// and tests use their own.
public protocol AgentChatService: Sendable {
    func stream(_ text: String, context: PageContext, conversationId: String?) -> AsyncThrowingStream<TurnUpdate, Error>
    /// The same, with files the user sent (from `upload(_:)`).
    func stream(_ text: String, context: PageContext, conversationId: String?, attachments: [String]) -> AsyncThrowingStream<TurnUpdate, Error>
    func latestConversation() async throws -> Conversation
    func clearConversation(_ id: String) async throws
    func undo(operationId: String) async throws -> UndoOutcome
    func memories() async throws -> [Memory]
    func remember(_ text: String) async throws -> String
    func correctMemory(_ id: String, text: String) async throws -> String
    func forgetMemory(_ id: String) async throws
    /// Uploads a photo or document the user is about to send.
    func upload(_ file: AgentFile) async throws -> TurnPart.Attachment
    /// An attachment's bytes, to show or share it.
    func attachmentData(_ attachmentId: String) async throws -> Data
    /// How the app's actions that need confirmation ask the user. The chat
    /// sets this to its own confirmation card.
    func setConfirmationPrompt(_ prompt: (@Sendable (ConfirmationRequest) async -> Bool)?) async
    /// The app's views and destinations, so the chat can show views and open screens.
    var chatRegistry: ActionRegistry? { get }
}

extension AgentChatService {
    public func stream(
        _ text: String, context: PageContext, conversationId: String?, attachments: [String]
    ) -> AsyncThrowingStream<TurnUpdate, Error> {
        guard attachments.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: AgentError.invalidRequest("This assistant can't take files.")) }
        }
        return stream(text, context: context, conversationId: conversationId)
    }

    // No defaults for upload, attachmentData or setConfirmationPrompt: AgentClient's
    // own versions are actor-isolated, so a call from outside the actor (as in
    // FoundationAgentService) resolved to a nonisolated default instead. Every
    // confirmation was declined and every file failed, with no compiler warning.

    public var chatRegistry: ActionRegistry? { nil }
}

/// A chat service that can bind a confirmation prompt to one turn.
/// `AgentChatModel` uses it when the service conforms, so each chat answers
/// its own turns' confirmations; otherwise it falls back to
/// `setConfirmationPrompt`. A separate protocol, so `AgentChatService` gains
/// no requirements in a patch release.
public protocol AgentChatTurnConfirming: AgentChatService {
    /// `stream(_:context:conversationId:attachments:)`, asking `confirm` for
    /// this turn's actions that need confirmation.
    func stream(
        _ text: String, context: PageContext, conversationId: String?, attachments: [String],
        confirm: @escaping @Sendable (ConfirmationRequest) async -> Bool
    ) -> AsyncThrowingStream<TurnUpdate, Error>
}

extension AgentClient: AgentChatService {
    public nonisolated var chatRegistry: ActionRegistry? { registry }
}

extension AgentClient: AgentChatTurnConfirming {
    public nonisolated func stream(
        _ text: String, context: PageContext, conversationId: String?, attachments: [String],
        confirm: @escaping @Sendable (ConfirmationRequest) async -> Bool
    ) -> AsyncThrowingStream<TurnUpdate, Error> {
        let prompt: (@Sendable (ConfirmationRequest) async -> Bool)? = confirm
        return stream(text, context: context, conversationId: conversationId, attachments: attachments, confirm: prompt)
    }
}

/// Text for an error that a person can read.
func describe(_ error: Error) -> String {
    switch error {
    case AgentError.staleSession: "Your session ended. Sign in again to keep chatting."
    case let e as AgentError: e.errorDescription ?? "Something went wrong."
    case let e as URLError where e.code == .notConnectedToInternet: "You're offline. Check your connection and try again."
    default: "Something went wrong. Try again."
    }
}
