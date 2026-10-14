import AgentChatUI
import AgentKit
import Foundation
import FoundationModels
import Synchronization

/// The chat service for an app that offers Apple's models alongside ours.
/// Pass it to `AgentChatModel` in place of the `AgentClient`, and set `source`
/// from a picker or your own defaults.
///
/// - `.server` runs the turn on our server, as `AgentClient` does.
/// - `.appleOnDevice` and `.applePrivateCloud` run the model on the phone's
///   Foundation Models session, under instructions our server compiles; every
///   action is still admitted by the server and gets a receipt and Undo.
/// - Offline, any source falls back to the on-device model for chat only:
///   it can't take actions or change memory until the phone is back online.
public final class FoundationAgentService: AgentChatTurnConfirming, Sendable {
    public let client: AgentClient
    private let selected: Mutex<AgentModelSource>
    private let offline: OfflineProfileStore

    /// Whether this app has Apple's managed Private Cloud Compute entitlement
    /// (`com.apple.developer.private-cloud-compute`).
    public let privateCloudComputeEntitled: Bool

    /// - Parameter privateCloudComputeEntitled: Set to true once Apple has granted the app the
    ///   Private Cloud Compute entitlement and it's in the app's entitlements. Without it,
    ///   Foundation Models stops the app when a Private Cloud Compute session runs, so the
    ///   service treats that source as unavailable.
    public init(
        client: AgentClient, source: AgentModelSource = .server, privateCloudComputeEntitled: Bool = false,
        offlineCacheDirectory: URL? = nil
    ) {
        self.client = client
        self.privateCloudComputeEntitled = privateCloudComputeEntitled
        self.selected = Mutex(source)
        self.offline = OfflineProfileStore(directory: offlineCacheDirectory)
    }

    /// The model source for the next message.
    public var source: AgentModelSource {
        get { selected.withLock { $0 } }
        set { selected.withLock { $0 = newValue } }
    }

    /// Whether `source` can answer on this device, in this app, right now.
    public func status(of source: AgentModelSource) -> AgentModelSource.Status {
        if source == .applePrivateCloud, !privateCloudComputeEntitled {
            return .unavailable("This app doesn't have Apple's Private Cloud Compute entitlement yet.")
        }
        return source.status
    }

    /// Removes the instructions kept for offline use. Call it at sign-out.
    public func clearOfflineCache() { offline.clear() }

    public func stream(_ text: String, context: PageContext, conversationId: String?) -> AsyncThrowingStream<TurnUpdate, Error> {
        stream(text, context: context, conversationId: conversationId, confirm: nil)
    }

    private func stream(
        _ text: String, context: PageContext, conversationId: String?, confirm: (@Sendable (ConfirmationRequest) async -> Bool)?
    ) -> AsyncThrowingStream<TurnUpdate, Error> {
        let source = self.source
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // The turn's prompt reaches every device call this turn makes.
                    try await AgentClient.$turnConfirmation.withValue(confirm ?? AgentClient.turnConfirmation) {
                        try await self.run(text, context: context, conversationId: conversationId, source: source, continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Messages with files always go to our server's models, which can see
    /// images; Apple's models here take text only.
    public func stream(
        _ text: String, context: PageContext, conversationId: String?, attachments: [String]
    ) -> AsyncThrowingStream<TurnUpdate, Error> {
        attachments.isEmpty
            ? stream(text, context: context, conversationId: conversationId)
            : client.stream(text, context: context, conversationId: conversationId, attachments: attachments)
    }

    public func stream(
        _ text: String, context: PageContext, conversationId: String?, attachments: [String],
        confirm: @escaping @Sendable (ConfirmationRequest) async -> Bool
    ) -> AsyncThrowingStream<TurnUpdate, Error> {
        attachments.isEmpty
            ? stream(text, context: context, conversationId: conversationId, confirm: confirm)
            : client.stream(text, context: context, conversationId: conversationId, attachments: attachments, confirm: confirm)
    }

    public func upload(_ file: AgentFile) async throws -> TurnPart.Attachment { try await client.upload(file) }
    public func attachmentData(_ attachmentId: String) async throws -> Data { try await client.attachmentData(attachmentId) }
    public func setConfirmationPrompt(_ prompt: (@Sendable (ConfirmationRequest) async -> Bool)?) async {
        await client.setConfirmationPrompt(prompt)
    }
    public var chatRegistry: ActionRegistry? { client.registry }

    private func run(
        _ text: String, context: PageContext, conversationId: String?, source: AgentModelSource,
        _ out: AsyncThrowingStream<TurnUpdate, Error>.Continuation
    ) async throws {
        guard let model = source.languageModel else {
            // Our server models. Falls back to offline chat only if nothing arrived.
            var received = false
            do {
                for try await update in client.stream(text, context: context, conversationId: conversationId) {
                    received = true
                    out.yield(update)
                }
            } catch where !received && Self.isOffline(error) {
                try await runOffline(text, out)
            }
            return
        }
        if case .unavailable(let reason) = status(of: source) { throw AgentError.unavailable(reason) }

        let prepared: PreparedLocalTurn
        do {
            prepared = try await client.prepareLocalTurn(text, context: context, conversationId: conversationId, budget: source.budget)
        } catch where Self.isOffline(error) {
            return try await runOffline(text, out)
        }
        if let userId = try? await client.currentUserId() { offline.save(prepared.instructions, userId: userId) }

        let profile = AgentProfile(prepared: prepared, message: text, client: client) { call in
            out.yield(.runningTools([call]))
        }
        let session = profile.makeSession(model: model)
        let reply: String
        do {
            reply = try await respond(session, to: text, out)
        } catch {
            // Logged on the server so the developer sees on-device failures; a cancelled turn isn't one.
            if !(error is CancellationError) && !Task.isCancelled { await profile.reportFailure(model: source.modelName) }
            throw error
        }
        out.yield(.completed(try await profile.finish(reply: reply, model: source.modelName)))
    }

    /// Chat with the on-device model and the last instructions the server sent.
    /// No tools: nothing changes in the app or in memory while offline.
    private func runOffline(_ text: String, _ out: AsyncThrowingStream<TurnUpdate, Error>.Continuation) async throws {
        guard SystemLanguageModel.default.isAvailable else {
            throw AgentError.unavailable("You're offline, and this device can't run Apple's on-device model.")
        }
        guard let userId = try? await client.currentUserId(), let instructions = offline.load(userId: userId) else {
            throw AgentError.unavailable("You're offline. Connect once so the assistant can load its settings.")
        }
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: instructions + "\n\n" + Self.offlineNote)
        let reply = try await respond(session, to: text, out)
        // Not saved to the conversation on the server: it can't be reached.
        out.yield(.completed(CompletedTurn(turnId: UUID().uuidString, conversationId: "", text: reply, model: "apple/on-device-offline")))
    }

    static let offlineNote = """
        # Offline
        The phone is offline right now. You can talk with the user, but you can't take actions in the app, look up \
        their data, or save or forget memories. If they ask for any of that, say plainly that you'll be able to once \
        they're back online. The "Current page" above may be out of date.
        """

    private func respond(
        _ session: LanguageModelSession, to text: String, _ out: AsyncThrowingStream<TurnUpdate, Error>.Continuation
    ) async throws -> String {
        var reply = ""
        do {
            for try await snapshot in session.streamResponse(to: text) {
                reply = snapshot.content
                out.yield(.text(reply))
            }
        } catch let e as PrivateCloudComputeLanguageModel.Error {
            if case .quotaLimitReached = e { throw AgentError.unavailable("You've reached today's Private Cloud Compute limit.") }
            throw AgentError.unavailable("Private Cloud Compute couldn't answer just now. Try again.")
        } catch let e as LanguageModelError {
            switch e {
            case .contextSizeExceeded:
                throw AgentError.unavailable("That's too long for Apple's on-device model. Start a new chat or switch models.")
            case .guardrailViolation, .refusal:
                throw AgentError.unavailable("Apple's model declined to answer that.")
            case .rateLimited:
                throw AgentError.unavailable("Apple's model is busy. Try again in a moment.")
            default:
                throw AgentError.unavailable("Apple's model couldn't answer just now. Try again.")
            }
        }
        return reply
    }

    static func isOffline(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .timedOut, .dataNotAllowed]
            .contains(e.code)
    }

    // Everything else is the same on every source.
    public func latestConversation() async throws -> Conversation { try await client.latestConversation() }
    public func clearConversation(_ id: String) async throws { try await client.clearConversation(id) }
    public func undo(operationId: String) async throws -> UndoOutcome { try await client.undo(operationId: operationId) }
    public func memories() async throws -> [Memory] { try await client.memories() }
    public func remember(_ text: String) async throws -> String { try await client.remember(text) }
    public func correctMemory(_ id: String, text: String) async throws -> String { try await client.correctMemory(id, text: text) }
    public func forgetMemory(_ id: String) async throws { try await client.forgetMemory(id) }
}

/// The last instructions the server compiled, kept on the device for offline
/// chat. They hold the user's memory profile, so the file is encrypted while
/// the phone is locked and is tied to the user it was written for.
struct OfflineProfileStore: Sendable {
    private let url: URL?

    init(directory: URL?) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        url = dir?.appending(path: "AgentKit/offline-profile.json")
    }

    private struct Stored: Codable { var userId: String; var instructions: String }

    func save(_ instructions: String, userId: String) {
        guard let url, let data = try? JSONEncoder().encode(Stored(userId: userId, instructions: instructions)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    func load(userId: String) -> String? {
        guard let url, let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data),
            stored.userId == userId
        else { return nil }
        return stored.instructions
    }

    func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
