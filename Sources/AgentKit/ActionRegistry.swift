import Foundation
import SwiftUI

/// Input type for tools that take no arguments.
public struct NoInput: Codable, Sendable, Hashable {
    public init() {}
}

/// A tool as the platform's integration contract describes it
/// (`DeviceTool`). Send `ActionRegistry.deviceTools`
/// to `register_integration` as `deviceTools`.
public struct DeviceTool: Codable, Sendable, Hashable {
    public struct Undo: Codable, Sendable, Hashable {
        public var supported: Bool
        public var limits: String
    }

    public var name: String
    public var description: String
    /// The block: "read", "search", "action", "view" or "destination" (the
    /// server also knows "event").
    public var kind: String
    public var inputSchema: JSONValue
    public var undo: Undo?
    /// A read's output schema, with sensitivity labels on fields.
    public var outputSchema: JSONValue? = nil
    /// Actions only: the user approves each run before it is admitted.
    public var requiresConfirmation: Bool? = nil
    /// Actions only: how the action reads to the user, with `{field}` filled
    /// from the input, e.g. "Pay {amount} to {payee}". Shown when confirming.
    public var summary: String? = nil
}

/// What the user is asked to approve before an action runs.
public struct ConfirmationRequest: Sendable, Hashable {
    /// The action's registered name.
    public var action: String
    /// The exact action in words, from the server.
    public var summary: String
    public var input: JSONValue
    /// The operation this would run, when known. Opaque and contains `:`;
    /// use `AgentOperation.idempotencyKey(for:)` for a header-safe key.
    public var operationId: String?
    /// The tool call being confirmed, when known.
    public var toolCallId: String?
    /// The app's own wording for this action, from `describeConfirmation`.
    /// Shown in place of `summary`; it stays on the device.
    public var displaySummary: String?

    public init(
        action: String, summary: String, input: JSONValue, operationId: String? = nil, toolCallId: String? = nil,
        displaySummary: String? = nil
    ) {
        self.action = action
        self.summary = summary
        self.input = input
        self.operationId = operationId
        self.toolCallId = toolCallId
        self.displaySummary = displaySummary
    }

    /// What the user is shown: the app's wording when it has one, else the server's.
    public var shownSummary: String { displaySummary ?? summary }
}

/// How an action is undone on the device.
public struct UndoHandler: Sendable {
    /// What Undo can't restore, shown to the assistant, e.g. "Comments added after creation stay."
    public var limits: String
    public var compensate: @Sendable (_ operationId: String, _ ref: AppObjectRef) async throws -> Void

    public init(limits: String, compensate: @escaping @Sendable (_ operationId: String, _ ref: AppObjectRef) async throws -> Void) {
        self.limits = limits
        self.compensate = compensate
    }
}

/// The reads and actions this app runs on the device for the assistant.
///
/// Reads return data. Actions return the object they created or changed and
/// get receipts, admission and Undo on the server. An action's handler gets a
/// stable `operationId` and must deduplicate by it: a retry after a lost
/// reply sends the same id, and must not create a second object. The id is
/// opaque and contains `:`; when the app's backend or a payment API takes an
/// `Idempotency-Key`, pass `AgentOperation.idempotencyKey(for: operationId)`.
public struct ActionRegistry: Sendable {
    /// Names the platform's own tools use; an app can't replace them.
    public static let reservedNames: Set<String> = [
        "remember", "correct_memory", "forget_memory", "update_my_assistant", "undo_action",
    ]

    private struct Entry: Sendable {
        var tool: DeviceTool
        var read: (@Sendable (JSONValue) async throws -> JSONValue)?
        var file: (@Sendable (JSONValue) async throws -> AgentFile)?
        var perform: (@Sendable (String, JSONValue) async throws -> AppObjectRef)?
        var lookup: (@Sendable (String) async throws -> AppObjectRef?)?
        var undo: UndoHandler?
        var render: (@MainActor @Sendable (JSONValue) throws -> AnyView)?
        var open: (@MainActor @Sendable (JSONValue) throws -> Void)?
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var describers: [String: @Sendable (JSONValue) async -> String?] = [:]

    /// Asks the user to approve an action registered with `requiresConfirmation`
    /// and returns their answer. Without it, those actions are declined.
    public var confirm: (@Sendable (ConfirmationRequest) async -> Bool)?

    public init() {}

    /// Registers a read: the assistant asks, the app answers with data.
    /// Read results are treated as untrusted information, never as instructions.
    ///
    /// - Parameter output: The result's schema. Label sensitive fields with
    ///   `.sensitive(_, .masked)` or `.sensitive(_, .hidden)` so they never fully reach the model.
    public mutating func registerRead<Input: Decodable & Sendable, Output: Encodable & Sendable>(
        _ name: String,
        description: String,
        input: Input.Type,
        schema: JSONSchema,
        output: JSONSchema? = nil,
        handler: @escaping @Sendable (Input) async throws -> Output
    ) throws {
        try add(
            Entry(
                tool: DeviceTool(
                    name: name, description: description, kind: "read", inputSchema: schema.json, undo: nil, outputSchema: output?.json),
                read: { json in try JSONValue(encoding: try await handler(Self.decode(json))) }
            ))
    }

    /// Registers a read that takes no input.
    public mutating func registerRead<Output: Encodable & Sendable>(
        _ name: String,
        description: String,
        output: JSONSchema? = nil,
        handler: @escaping @Sendable () async throws -> Output
    ) throws {
        try registerRead(name, description: description, input: NoInput.self, schema: .empty, output: output) { _ in try await handler() }
    }

    /// Registers a search: like a read, for finding the user's objects by
    /// words, dates or amounts. Return each object's id so the assistant can
    /// link to it (see `registerDestination`).
    public mutating func registerSearch<Input: Decodable & Sendable, Output: Encodable & Sendable>(
        _ name: String,
        description: String,
        input: Input.Type,
        schema: JSONSchema,
        output: JSONSchema? = nil,
        handler: @escaping @Sendable (Input) async throws -> Output
    ) throws {
        try add(
            Entry(
                tool: DeviceTool(
                    name: name, description: description, kind: "search", inputSchema: schema.json, undo: nil, outputSchema: output?.json),
                read: { json in try JSONValue(encoding: try await handler(Self.decode(json))) }
            ))
    }

    /// Registers an export: the app produces a file (for example a CSV) with
    /// its own code, and the chat offers it to the user to save or share.
    public mutating func registerExport<Input: Decodable & Sendable>(
        _ name: String,
        description: String,
        input: Input.Type,
        schema: JSONSchema,
        handler: @escaping @Sendable (Input) async throws -> AgentFile
    ) throws {
        try add(
            Entry(
                tool: DeviceTool(name: name, description: description, kind: "read", inputSchema: schema.json, undo: nil),
                file: { json in try await handler(Self.decode(json)) }
            ))
    }

    /// Registers a view the assistant can show in the chat: one of the app's
    /// own SwiftUI views, drawn from the app's data. The assistant only picks
    /// it and its parameters, which are checked against `schema` first.
    /// It shows again when the conversation reloads, so read current data.
    public mutating func registerView<Params: Decodable & Sendable, Content: View>(
        _ name: String,
        description: String,
        params: Params.Type,
        schema: JSONSchema,
        @ViewBuilder content: @escaping @MainActor @Sendable (Params) -> Content
    ) throws {
        try add(
            Entry(
                tool: DeviceTool(name: name, description: description, kind: "view", inputSchema: schema.json, undo: nil),
                render: { json in AnyView(content(try Self.decode(json))) }
            ))
    }

    /// Registers a screen the assistant can link to or open, with its
    /// parameters (for example an object's id, or a list's filters). `open`
    /// takes the user there with the app's own navigation.
    public mutating func registerDestination<Params: Decodable & Sendable>(
        _ name: String,
        description: String,
        params: Params.Type,
        schema: JSONSchema,
        open: @escaping @MainActor @Sendable (Params) -> Void
    ) throws {
        try add(
            Entry(
                tool: DeviceTool(name: name, description: description, kind: "destination", inputSchema: schema.json, undo: nil),
                open: { json in open(try Self.decode(json)) }
            ))
    }

    /// Registers an action that changes the app's data.
    ///
    /// - Parameters:
    ///   - undo: How to reverse the action. Without it the assistant tells the user it can't be undone.
    ///   - lookup: Finds the object an earlier `operationId` produced, so actions interrupted by the
    ///     app closing can be settled on next launch (`AgentClient.settleUnsettled()`).
    ///   - requiresConfirmation: The user approves each run first (the chat asks, or `confirm`). Use it
    ///     for actions that can't be undone or that move money.
    ///   - summary: How the action reads to the user, with `{field}` filled from the input, e.g.
    ///     "Pay {amount} to {payee}". Shown when asking to confirm, so include every detail that matters.
    ///   - perform: Runs the action. Throw `OutcomeUnknown` if you can't tell whether it took effect;
    ///     any other error means it did not. For an `Idempotency-Key`, use
    ///     `AgentOperation.idempotencyKey(for: operationId)`, not `operationId` itself.
    public mutating func registerAction<Input: Decodable & Sendable>(
        _ name: String,
        description: String,
        input: Input.Type,
        schema: JSONSchema,
        requiresConfirmation: Bool = false,
        summary: String? = nil,
        undo: UndoHandler? = nil,
        lookup: (@Sendable (_ operationId: String) async throws -> AppObjectRef?)? = nil,
        perform: @escaping @Sendable (_ operationId: String, _ input: Input) async throws -> AppObjectRef
    ) throws {
        let undoInfo = DeviceTool.Undo(supported: undo != nil, limits: undo?.limits ?? "This action can't be undone.")
        try add(
            Entry(
                tool: DeviceTool(
                    name: name, description: description, kind: "action", inputSchema: schema.json, undo: undoInfo,
                    requiresConfirmation: requiresConfirmation ? true : nil, summary: summary),
                perform: { op, json in try await perform(op, Self.decode(json)) },
                lookup: lookup,
                undo: undo
            ))
    }

    /// Words the confirmation card for `action` with the app's own code, e.g.
    /// "Pay $124.00 to City Power from Household checking" where the server
    /// would say "Pay 12400 to City Power from joint". Works for actions that
    /// run on the app's server too, which have no entry here.
    ///
    /// The text is only shown on this device. The server still binds the
    /// approval to the exact input, and receipts keep the server's summary.
    /// Build it from `input` alone, never from text the model wrote. Return
    /// nil to show the server's summary.
    public mutating func describeConfirmation(_ action: String, _ describe: @escaping @Sendable (JSONValue) async -> String?) {
        describers[action] = describe
    }

    /// `describeConfirmation` with the input decoded to the app's own type.
    /// When it doesn't decode, the server's summary is shown.
    public mutating func describeConfirmation<Input: Decodable & Sendable>(
        _ action: String, input: Input.Type, _ describe: @escaping @Sendable (Input) async -> String?
    ) {
        describers[action] = { json in
            guard let value = try? json.decode(as: Input.self) else { return nil }
            return await describe(value)
        }
    }

    /// The tool list for the integration contract, in registration order.
    public var deviceTools: [DeviceTool] { order.compactMap { entries[$0]?.tool } }

    /// `deviceTools` as JSON, ready to paste into `register_integration`.
    public func deviceToolsJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(deviceTools), as: UTF8.self)
    }

    // MARK: Showing views and opening screens

    /// The app's view for a view part, or nil when this app version doesn't
    /// have it or its parameters don't decode.
    @MainActor
    public func view(_ name: String, params: JSONValue) -> AnyView? {
        guard let render = entries[name]?.render else { return nil }
        return try? render(params)
    }

    /// Opens a destination with its parameters. False when this app version
    /// doesn't have it or the parameters don't decode.
    @MainActor
    @discardableResult
    public func open(_ destination: String, params: JSONValue) -> Bool {
        guard let open = entries[destination]?.open else { return false }
        do {
            try open(params)
            return true
        } catch {
            return false
        }
    }

    // MARK: Running calls

    /// Runs one call the server asked the device to make. Never throws:
    /// failures become a result the assistant can explain.
    ///
    /// - Parameters:
    ///   - upload: Uploads a file an export produced and returns its attachment id.
    ///   - confirmFallback: Asks the user when `confirm` isn't set (the chat's own prompt).
    package func run(
        _ call: DeviceCall,
        upload: (@Sendable (AgentFile) async throws -> String)? = nil,
        confirmFallback: (@Sendable (ConfirmationRequest) async -> Bool)? = nil
    ) async -> DeviceResult {
        let input = call.input ?? .object([:])
        // Confirmations come first: the action may run on the app's server,
        // so the device has no entry for it and only asks the user.
        if call.kind == .confirm {
            guard let confirm = confirm ?? confirmFallback else { return DeviceResult(toolCallId: call.toolCallId, ok: true, confirmed: false) }
            let display = await describers[call.action]?(input)
            let request = ConfirmationRequest(
                action: call.action, summary: call.summary ?? call.action, input: input, operationId: call.operationId, toolCallId: call.toolCallId,
                displaySummary: display.flatMap { $0.isEmpty ? nil : $0 })
            return DeviceResult(toolCallId: call.toolCallId, ok: true, confirmed: await confirm(request))
        }
        guard let entry = entries[call.action] else {
            return failure(call, "This app doesn't have \(call.action).")
        }
        switch call.kind {
        case .read:
            if let file = entry.file {
                guard let upload else { return failure(call, "This app can't send files here.") }
                do {
                    let produced = try await file(input)
                    let id = try await upload(produced)
                    return DeviceResult(
                        toolCallId: call.toolCallId, ok: true,
                        output: .object(["file": .string(produced.name), "type": .string(produced.mimeType)]), attachments: [id])
                } catch {
                    return failure(call, Self.message(error))
                }
            }
            guard let read = entry.read else { return failure(call, "\(call.action) isn't a read.") }
            do {
                return DeviceResult(toolCallId: call.toolCallId, ok: true, output: try await read(input))
            } catch {
                return failure(call, Self.message(error))
            }
        case .action:
            guard let perform = entry.perform, let operationId = call.operationId else {
                return failure(call, "\(call.action) isn't an action.")
            }
            do {
                return DeviceResult(toolCallId: call.toolCallId, ok: true, ref: try await perform(operationId, input))
            } catch let unknown as OutcomeUnknown {
                return failure(call, unknown.message, known: false)
            } catch {
                return failure(call, Self.message(error), known: true)
            }
        case .confirm:
            return failure(call, "Unreachable: confirmations are answered above.")
        case .compensate:
            guard let operationId = call.operationId, let ref = call.ref else {
                return failure(call, "Missing the operation to undo.")
            }
            do {
                try await compensate(action: call.action, operationId: operationId, ref: ref)
                return DeviceResult(toolCallId: call.toolCallId, ok: true)
            } catch {
                return failure(call, Self.message(error))
            }
        }
    }

    func lookup(action: String, operationId: String) async throws -> AppObjectRef?? {
        guard let lookup = entries[action]?.lookup else { return .none }
        return .some(try await lookup(operationId))
    }

    func compensate(action: String, operationId: String, ref: AppObjectRef) async throws {
        guard let undo = entries[action]?.undo else { throw UndoUnsupported(action: action) }
        try await undo.compensate(operationId, ref)
    }

    // MARK: Helpers

    private mutating func add(_ entry: Entry) throws {
        let name = entry.tool.name
        guard name.wholeMatch(of: /[a-z][a-z0-9_]{0,63}/) != nil else { throw RegistrationError.invalidName(name) }
        guard !Self.reservedNames.contains(name) else { throw RegistrationError.reservedName(name) }
        guard entries[name] == nil else { throw RegistrationError.duplicateName(name) }
        guard (1...1000).contains(entry.tool.description.count) else { throw RegistrationError.invalidDescription(name) }
        entries[name] = entry
        order.append(name)
    }

    private static func decode<T: Decodable>(_ json: JSONValue) throws -> T {
        do { return try json.decode(as: T.self) } catch { throw InvalidInput() }
    }

    private func failure(_ call: DeviceCall, _ message: String, known: Bool? = nil) -> DeviceResult {
        DeviceResult(toolCallId: call.toolCallId, ok: false, error: message, known: call.kind == .action ? known : nil)
    }

    // The server rejects longer error strings.
    static func message(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return String(text.prefix(2000))
    }
}

struct InvalidInput: LocalizedError {
    var errorDescription: String? { "The input didn't match this tool's schema." }
}

struct UndoUnsupported: LocalizedError {
    var action: String
    var errorDescription: String? { "This app can't undo \(action)." }
}
