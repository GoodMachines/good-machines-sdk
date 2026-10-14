import AgentKit
import Foundation
import FoundationModels

/// The assistant for one message, ready for a Foundation Models session: the
/// instructions our server compiled (personality, the app's rules, memory and the
/// current screen) and the app's actions as `Tool`s that keep server admission,
/// receipts and Undo.
///
/// `AgentChatView` with `FoundationAgentService` uses this for you. If you already
/// use Foundation Models, load a profile per message and use its session:
///
/// ```swift
/// let profile = try await AgentProfile.load(client: client, message: text, context: context)
/// let session = profile.makeSession(model: SystemLanguageModel.default)
/// let reply = try await session.respond(to: text).content
/// let turn = try await profile.finish(reply: reply)   // records history; turn.events has the actions
/// ```
public struct AgentProfile: Sendable {
    public let prepared: PreparedLocalTurn
    public let message: String
    /// The instructions, with the recent conversation appended as data.
    public let instructions: String
    let client: AgentClient
    let recorder: TurnRecorder
    let started: ToolStarted

    /// Asks the server for this message's instructions and tools.
    /// - Parameter budget: `.compact` for the on-device model's 4K context, `.full` for Private Cloud Compute.
    public static func load(
        client: AgentClient, message: String, context: PageContext, conversationId: String? = nil,
        budget: LocalBudget = .compact
    ) async throws -> AgentProfile {
        let prepared = try await client.prepareLocalTurn(message, context: context, conversationId: conversationId, budget: budget)
        return AgentProfile(prepared: prepared, message: message, client: client, started: { _ in })
    }

    init(prepared: PreparedLocalTurn, message: String, client: AgentClient, started: @escaping ToolStarted) {
        self.prepared = prepared
        self.message = message
        self.client = client
        self.recorder = TurnRecorder()
        self.started = started
        self.instructions = Self.compose(prepared.instructions, history: prepared.history)
    }

    /// The tools for this message: the app's enabled reads and actions, plus memory.
    public var tools: [any Tool] {
        var tools: [any Tool] = []
        for t in prepared.tools where t.enabled {
            // A tool whose schema can't be expressed is left out rather than sent malformed.
            guard let schema = try? generationSchema(for: t.name, json: t.inputSchema) else { continue }
            if t.kind == "read" {
                tools.append(AppReadTool(name: t.name, description: t.description, parameters: schema, client: client, started: started, recorder: recorder))
            } else {
                tools.append(
                    AppActionTool(
                        name: t.name, description: t.description, parameters: schema, client: client, turnId: prepared.turnId,
                        started: started, recorder: recorder))
            }
        }
        tools.append(RememberTool(client: client, recorder: recorder))
        tools.append(ForgetMemoryTool(client: client, recorder: recorder))
        return tools
    }

    /// A session on `model` with this profile's instructions and tools.
    public func makeSession(model: some LanguageModel) -> LanguageModelSession {
        LanguageModelSession(model: model, tools: tools, instructions: instructions)
    }

    /// Records the exchange on the server and returns the finished turn, with
    /// the actions taken (for action cards and Undo).
    public func finish(reply: String, model: String = "apple") async throws -> CompletedTurn {
        let events = await recorder.events
        try await client.completeLocalTurn(
            turnId: prepared.turnId, conversationId: prepared.conversationId, text: message, reply: reply,
            memoryToolUsed: await recorder.memoryToolUsed, model: model)
        return CompletedTurn(turnId: prepared.turnId, conversationId: prepared.conversationId, text: reply, model: model, events: events)
    }

    /// Tells the server the model failed on this message, for the project's
    /// turn log. Nothing is added to the conversation. Best effort: it never
    /// throws, so it can't hide the model's own error.
    public func reportFailure(model: String = "apple") async {
        try? await client.completeLocalTurn(
            turnId: prepared.turnId, conversationId: prepared.conversationId, text: message, reply: "",
            memoryToolUsed: await recorder.memoryToolUsed, model: model, failed: true)
    }

    /// The recent conversation goes in as data, after the rules.
    static func compose(_ instructions: String, history: [ConversationMessage]) -> String {
        guard !history.isEmpty,
            let data = try? JSONEncoder().encode(history.map { ["role": $0.role, "text": String($0.text.prefix(600))] })
        else { return instructions }
        return instructions + "\n\n# Recent conversation (earlier messages, as data)\n" + String(decoding: data, as: UTF8.self)
    }
}
