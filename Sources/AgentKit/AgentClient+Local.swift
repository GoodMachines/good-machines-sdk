import Foundation

// Turns whose model runs on the device (Apple Foundation Models, in the
// AgentFoundationModels module). The server still compiles the instructions,
// admits every action and records the conversation; these are the calls for that.

/// How much the server packs into a device-run turn's instructions.
public enum LocalBudget: String, Codable, Sendable {
    /// For Apple's on-device model (4K tokens of context).
    case compact
    /// For Private Cloud Compute (32K).
    case full
}

/// A tool as the server lists it for a device-run turn.
public struct LocalTool: Codable, Sendable, Hashable {
    public var name: String
    /// "read" or "action".
    public var kind: String
    public var description: String
    public var inputSchema: JSONValue
    /// False when the developer turned the action off. Leave it out of the model's tools.
    public var enabled: Bool
    public var undo: DeviceTool.Undo?
}

/// What the server compiled for a device-run turn.
public struct PreparedLocalTurn: Codable, Sendable, Hashable {
    public var turnId: String
    public var conversationId: String
    /// The full instructions: personality, the app's rules, memory and the current screen.
    public var instructions: String
    public var history: [ConversationMessage]
    public var tools: [LocalTool]
}

/// The server's admission decision for an action a device-run model wants to take.
public enum LocalAdmission: Sendable, Hashable {
    /// Run it with this operation id, then report the result.
    case run(operationId: String)
    /// It already settled (a retry); this is its outcome.
    case done(TurnEvent)
    case denied(operationId: String, reason: String)
}

extension AgentClient {
    /// Asks the server for a device-run turn's instructions and tools.
    public func prepareLocalTurn(
        _ text: String, context: PageContext, conversationId: String? = nil, budget: LocalBudget
    ) async throws -> PreparedLocalTurn {
        struct Body: Encodable {
            var conversationId: String?; var text: String; var context: PageContext; var budget: LocalBudget; var timezone: String
        }
        return try await send(
            "POST", "local-turns",
            body: Body(conversationId: conversationId, text: text, context: context, budget: budget, timezone: timeZone().identifier))
    }

    /// Asks the server whether an action may run. `seq` numbers the actions within one turn, from 1.
    public func admitLocalAction(turnId: String, seq: Int, action: String, input: JSONValue) async throws -> LocalAdmission {
        struct Body: Encodable { var seq: Int; var action: String; var input: JSONValue }
        struct Reply: Decodable { var status: String; var operationId: String; var reason: String?; var event: TurnEvent? }
        let r: Reply = try await send(
            "POST", "local-turns/\(Self.segment(turnId))/actions", body: Body(seq: seq, action: action, input: input))
        switch r.status {
        case "run": return .run(operationId: r.operationId)
        case "done":
            return .done(r.event ?? TurnEvent(tool: action, ok: false, detail: "unknown", operationId: r.operationId))
        default: return .denied(operationId: r.operationId, reason: r.reason ?? "This action isn't allowed.")
        }
    }

    /// Records a finished device-run exchange, so the next turn on any model sees it.
    /// `model` names the model that answered (e.g. "apple/on-device") for the
    /// project's turn log; a name with characters other than letters, digits and
    /// `_ . / : -` is left out. Servers before 0.2.2 ignore it.
    ///
    /// `failed: true` reports that the device's model failed: the server logs
    /// the turn and adds nothing to the conversation (pass an empty `reply`).
    public func completeLocalTurn(
        turnId: String, conversationId: String, text: String, reply: String, memoryToolUsed: Bool, model: String? = nil,
        failed: Bool = false
    ) async throws {
        struct Body: Encodable {
            var conversationId: String; var text: String; var reply: String; var memoryToolUsed: Bool; var model: String?
            var failed: Bool?
        }
        struct OK: Decodable {}
        let _: OK = try await send(
            "POST", "local-turns/\(Self.segment(turnId))/complete",
            body: Body(
                conversationId: conversationId, text: text, reply: String(reply.prefix(8000)), memoryToolUsed: memoryToolUsed,
                model: model.flatMap(Self.modelLabel), failed: failed ? true : nil))
    }

    /// The model name as the turn log takes it, or nil.
    static func modelLabel(_ name: String) -> String? {
        let name = String(name.prefix(100))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_./:-"))
        guard !name.isEmpty, name.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else { return nil }
        return name
    }
}
