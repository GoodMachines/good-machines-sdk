import Foundation

// Wire types for the hosted platform API's turn contract. Field names
// match the JSON exactly.

/// The object an action created or changed in the app's own store.
public struct AppObjectRef: Codable, Sendable, Hashable {
    public var objectId: String
    public var objectRevision: Int
    public init(objectId: String, objectRevision: Int) {
        self.objectId = objectId
        self.objectRevision = objectRevision
    }
}

/// A platform session, minted by `POST /v1/sessions` from the app's ID token.
public struct PlatformSession: Codable, Sendable, Hashable {
    public var sessionToken: String
    /// ISO 8601 timestamp.
    public var expiresAt: String
    public var userId: String

    public init(sessionToken: String, expiresAt: String, userId: String) {
        self.sessionToken = sessionToken
        self.expiresAt = expiresAt
        self.userId = userId
    }

    /// True when the session is expired or within `margin` seconds of it.
    public func isExpired(now: Date = .now, margin: TimeInterval = 30) -> Bool {
        guard let date = (try? Date(expiresAt, strategy: .iso8601WithFractionalSeconds)) ?? (try? Date(expiresAt, strategy: .iso8601))
        else { return true }
        return date.timeIntervalSince(now) <= margin
    }
}

extension ParseStrategy where Self == Date.ISO8601FormatStyle {
    fileprivate static var iso8601WithFractionalSeconds: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    }
}

/// What the app tells the agent about the screen the user is on. Captured per
/// message so a write can't silently move to another page after navigation.
public struct PageContext: Codable, Sendable, Hashable {
    public struct Selection: Codable, Sendable, Hashable {
        public var type: String
        public var id: String
        public init(type: String, id: String) {
            self.type = type
            self.id = id
        }
    }

    public var page: String
    public var projectId: String?
    public var selection: Selection?
    public var visible: JSONValue?
    /// ISO 8601 timestamp of when the app observed this state.
    public var observedAt: String
    /// Increases each time the context changes.
    public var revision: Int

    public init(
        page: String, projectId: String? = nil, selection: Selection? = nil, visible: JSONValue? = nil,
        observedAt: Date = .now, revision: Int = 0
    ) {
        self.page = page
        self.projectId = projectId
        self.selection = selection
        self.visible = visible
        self.observedAt = observedAt.ISO8601Format(.iso8601WithTimeZone(includingFractionalSeconds: true))
        self.revision = revision
    }
}

/// One tool the assistant used during a turn, for showing results and Undo.
public struct TurnEvent: Codable, Sendable, Hashable {
    public var tool: String
    public var ok: Bool
    public var detail: String
    public var operationId: String?
    /// Actions only: whether the user can undo this one now. Nil from servers
    /// before 0.2.2 and from on-device turns; the chat then asks the registry.
    public var undoable: Bool?

    public init(tool: String, ok: Bool, detail: String, operationId: String? = nil, undoable: Bool? = nil) {
        self.tool = tool
        self.ok = ok
        self.detail = detail
        self.operationId = operationId
        self.undoable = undoable
    }
}

/// A tool call the device has to run before the turn can continue.
public struct DeviceCall: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case read, action, compensate
        /// Ask the user to approve `action` with `input`, shown as `summary`.
        /// Answer with `DeviceResult.confirmed`.
        case confirm
    }

    public var toolCallId: String
    /// The tool name the model called (`undo_action` for a compensation).
    public var tool: String
    public var kind: Kind
    /// The app action this concerns (same as `tool`, except for compensation).
    public var action: String
    public var input: JSONValue?
    public var operationId: String?
    public var ref: AppObjectRef?
    /// For a confirmation: the exact action, in words, for the user to approve.
    public var summary: String?

    public init(
        toolCallId: String, tool: String, kind: Kind, action: String, input: JSONValue? = nil, operationId: String? = nil,
        ref: AppObjectRef? = nil, summary: String? = nil
    ) {
        self.toolCallId = toolCallId
        self.tool = tool
        self.kind = kind
        self.action = action
        self.input = input
        self.operationId = operationId
        self.ref = ref
        self.summary = summary
    }
}

/// The device's answer to a `DeviceCall`.
public struct DeviceResult: Codable, Sendable, Hashable {
    public var toolCallId: String
    public var ok: Bool
    /// A read's data.
    public var output: JSONValue?
    /// An action's created or changed object.
    public var ref: AppObjectRef?
    public var error: String?
    /// false when the device can't tell whether an action took effect.
    public var known: Bool?
    /// A confirmation's answer: true only when the user approved.
    public var confirmed: Bool?
    /// Files the read or action produced for the user, already uploaded.
    public var attachments: [String]?

    public init(
        toolCallId: String, ok: Bool, output: JSONValue? = nil, ref: AppObjectRef? = nil, error: String? = nil,
        known: Bool? = nil, confirmed: Bool? = nil, attachments: [String]? = nil
    ) {
        self.toolCallId = toolCallId
        self.ok = ok
        self.output = output
        self.ref = ref
        self.error = error
        self.known = known
        self.confirmed = confirmed
        self.attachments = attachments
    }
}

/// Part of a reply (`TurnPart` in the platform's turn contract). The app
/// renders views, destinations and attachments from its own data and code;
/// the assistant only picks names and parameters.
public enum TurnPart: Codable, Sendable, Hashable {
    case text(String)
    /// A registered view to show in chat.
    case view(name: String, params: JSONValue)
    /// A link to a registered destination in the app. `openNow`: the user
    /// asked to go there, so the chat opens it once when the reply arrives.
    case navigation(destination: String, params: JSONValue, label: String, openNow: Bool = false)
    case attachment(Attachment)
    /// A kind of part this SDK version doesn't know yet. Skip it.
    case unknown(type: String)

    public struct Attachment: Codable, Sendable, Hashable {
        public var attachmentId: String
        public var name: String
        public var mimeType: String
        public var size: Int

        public init(attachmentId: String, name: String, mimeType: String, size: Int) {
            self.attachmentId = attachmentId
            self.name = name
            self.mimeType = mimeType
            self.size = size
        }
    }

    private enum Keys: String, CodingKey { case type, text, view, params, destination, label, openNow }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text": self = .text(try c.decode(String.self, forKey: .text))
        case "view": self = .view(name: try c.decode(String.self, forKey: .view), params: try c.decode(JSONValue.self, forKey: .params))
        case "navigation":
            self = .navigation(
                destination: try c.decode(String.self, forKey: .destination), params: try c.decode(JSONValue.self, forKey: .params),
                label: try c.decode(String.self, forKey: .label), openNow: try c.decodeIfPresent(Bool.self, forKey: .openNow) ?? false)
        case "attachment": self = .attachment(try Attachment(from: decoder))
        default: self = .unknown(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case .view(let name, let params):
            try c.encode("view", forKey: .type)
            try c.encode(name, forKey: .view)
            try c.encode(params, forKey: .params)
        case .navigation(let destination, let params, let label, let openNow):
            try c.encode("navigation", forKey: .type)
            try c.encode(destination, forKey: .destination)
            try c.encode(params, forKey: .params)
            try c.encode(label, forKey: .label)
            if openNow { try c.encode(true, forKey: .openNow) }
        case .attachment(let a):
            try c.encode("attachment", forKey: .type)
            try a.encode(to: encoder)
        case .unknown(let type):
            try c.encode(type, forKey: .type)
        }
    }
}

/// A file to send in chat: a photo or document the user picked, or a file the
/// app produced for the user (an export).
public struct AgentFile: Sendable, Hashable {
    /// The largest file the API accepts.
    public static let maxBytes = 4 * 1024 * 1024
    /// Types the API accepts.
    public static let allowedTypes: Set<String> = [
        "image/jpeg", "image/png", "image/heic", "image/webp", "application/pdf", "text/csv", "text/plain", "application/json",
    ]

    public var name: String
    public var mimeType: String
    public var data: Data

    public init(name: String, mimeType: String, data: Data) {
        self.name = name
        self.mimeType = mimeType
        self.data = data
    }
}

/// The server's turn response: finished, or waiting on the device.
public enum TurnResponse: Decodable, Sendable, Hashable {
    case completed(CompletedTurn)
    case requiresAction(PendingDeviceTurn)

    private enum Keys: String, CodingKey { case status }

    public init(from decoder: Decoder) throws {
        let status = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .status)
        switch status {
        case "completed": self = .completed(try CompletedTurn(from: decoder))
        case "requires_action": self = .requiresAction(try PendingDeviceTurn(from: decoder))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [Keys.status], debugDescription: "Unknown turn status \(status)"))
        }
    }
}

public struct CompletedTurn: Codable, Sendable, Hashable {
    public var turnId: String
    public var conversationId: String
    public var text: String
    /// The model the turn asked for.
    public var model: String
    public var events: [TurnEvent]
    /// The reply's parts: its text first, then views, navigation offers and
    /// attachments. Empty for turns answered on the device.
    public var parts: [TurnPart]
    /// The model that answered, when the server knows it (0.2.2 and later).
    /// It differs from `model` when the provider reports a more specific
    /// version or a fallback model answered after a failed call.
    public var modelUsed: String?

    public init(
        turnId: String, conversationId: String, text: String, model: String, events: [TurnEvent] = [], parts: [TurnPart] = [],
        modelUsed: String? = nil
    ) {
        self.turnId = turnId
        self.conversationId = conversationId
        self.text = text
        self.model = model
        self.events = events
        self.parts = parts
        self.modelUsed = modelUsed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        turnId = try c.decode(String.self, forKey: .turnId)
        conversationId = try c.decode(String.self, forKey: .conversationId)
        text = try c.decode(String.self, forKey: .text)
        model = try c.decode(String.self, forKey: .model)
        events = try c.decode([TurnEvent].self, forKey: .events)
        parts = try c.decodeIfPresent([TurnPart].self, forKey: .parts) ?? []
        modelUsed = try c.decodeIfPresent(String.self, forKey: .modelUsed)
    }
}

public struct PendingDeviceTurn: Codable, Sendable, Hashable {
    public var turnId: String
    public var conversationId: String
    public var calls: [DeviceCall]
    public var events: [TurnEvent]
}

public struct Capabilities: Codable, Sendable, Hashable {
    public struct Tool: Codable, Sendable, Hashable {
        public var name: String
        /// The block: "read", "action", "search", "view", "destination" or "event".
        public var kind: String
        public var enabled: Bool
        /// Actions only: the user approves each run.
        public var requiresConfirmation: Bool?
    }

    public var policyRev: Int
    public var tools: [Tool]
    public var customization: String
}

public struct ConversationMessage: Codable, Sendable, Hashable {
    /// The server's id for the message. Nil from servers before 0.2.2.
    public var id: String?
    public var role: String
    public var text: String
    /// An assistant reply's views, navigation offers and attachments.
    public var parts: [TurnPart]?
    /// When the server stored it (ISO 8601).
    public var createdAt: String?
    /// "user", "assistant", or "background" for both sides of a background
    /// run (an alert or a schedule), whose user text is the stored request.
    public var origin: String?

    public init(
        role: String, text: String, parts: [TurnPart]? = nil, id: String? = nil, createdAt: String? = nil, origin: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.parts = parts
        self.createdAt = createdAt
        self.origin = origin
    }
}

public struct Conversation: Codable, Sendable, Hashable {
    public var conversationId: String?
    public var messages: [ConversationMessage]

    public init(conversationId: String?, messages: [ConversationMessage]) {
        self.conversationId = conversationId
        self.messages = messages
    }
}

public struct Memory: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var text: String
    /// "explicit" (the user asked) or "learned".
    public var origin: String
    public var updatedAt: String

    public init(id: String, text: String, origin: String, updatedAt: String) {
        self.id = id
        self.text = text
        self.origin = origin
        self.updatedAt = updatedAt
    }
}

/// An action the server is still waiting to hear about, for example because
/// the app was closed mid-action.
public struct UnsettledOperation: Codable, Sendable, Hashable {
    public var operationId: String
    public var action: String
    /// "admitted" or "outcome_uncertain".
    public var status: String
    public var createdAt: String
}

/// What the device reports for an unsettled operation.
public enum OperationReport: Sendable, Hashable {
    /// The action took effect and produced this object.
    case succeeded(AppObjectRef)
    /// The action failed. `known: false` means the device can't tell whether it took effect.
    case failed(String, known: Bool = true)
}

public enum UndoOutcome: Sendable, Hashable {
    /// `summary` is set when the server undid it without the device.
    case undone(summary: String?)
    case refused(reason: String)
}
