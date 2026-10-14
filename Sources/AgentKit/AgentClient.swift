import Foundation
import os

/// The client for the hosted platform API.
///
/// The assistant's model, memory and receipts run on the server; the app's
/// registered reads and actions run here, on the device, when a turn asks for them.
public actor AgentClient {
    /// The most device round trips one message may take. The server bounds
    /// model steps too; this stops a misbehaving server from looping the app.
    public static let maxDeviceRounds = 10

    private let baseURL: URL
    let projectId: String
    private let tokenStore: any TokenStore
    private let idToken: @Sendable () async throws -> String
    let urlSession: URLSession
    public nonisolated let registry: ActionRegistry
    private let attestor: (any AppAttestor)?
    /// The device's time zone, sent with each message so "today" is the user's date.
    let timeZone: @Sendable () -> TimeZone

    private var signingIn: Task<PlatformSession, Error>?
    /// Asks the user to confirm an action when the registry has no `confirm`
    /// of its own. `AgentChatModel` sets it to show its confirmation card.
    private var confirmationPrompt: (@Sendable (ConfirmationRequest) async -> Bool)?
    /// The prompt bound to the turn running in this task (`stream(..., confirm:)`).
    /// It wins over `confirmationPrompt`, so a second chat can't take over
    /// another chat's confirmations.
    @TaskLocal package static var turnConfirmation: (@Sendable (ConfirmationRequest) async -> Bool)?
    static let log = Logger(subsystem: "AgentKit", category: "confirmations")

    /// - Parameters:
    ///   - baseURL: The API origin, e.g. `https://api.example.com` (the client adds `/v1`).
    ///   - projectId: The app's project id from the dashboard.
    ///   - registry: The reads and actions this app runs for the assistant.
    ///   - tokenStore: Where the platform session is kept. Use `KeychainTokenStore` in apps.
    ///   - idToken: Returns the app's current ID token for its signed-in user
    ///     (Supabase, Firebase, Clerk or Sign in with Apple). Called when a session is needed.
    ///   - attestation: Proves sessions come from this app on a real device
    ///     (`AppAttestService`). Needed when the developer requires App Attest.
    ///   - timeZone: The user's time zone. Each message carries it, so relative
    ///     dates ("today", "this week") are the user's. Defaults to the device's.
    public init(
        baseURL: URL,
        projectId: String,
        registry: ActionRegistry = ActionRegistry(),
        tokenStore: any TokenStore,
        urlSession: URLSession = .shared,
        attestation: (any AppAttestor)? = nil,
        timeZone: @escaping @Sendable () -> TimeZone = { .current },
        idToken: @escaping @Sendable () async throws -> String
    ) {
        // Trailing slashes would double up when paths are joined.
        var origin = baseURL.absoluteString
        while origin.hasSuffix("/") { origin.removeLast() }
        self.baseURL = URL(string: origin + "/v1") ?? baseURL
        self.projectId = projectId
        self.registry = registry
        self.tokenStore = tokenStore
        self.urlSession = urlSession
        self.idToken = idToken
        self.attestor = attestation
        self.timeZone = timeZone
    }

    // MARK: Sessions

    /// Exchanges the app's ID token for a platform session and stores it.
    /// Other calls do this on demand; call it to sign in eagerly.
    @discardableResult
    public func signIn() async throws -> PlatformSession {
        if let signingIn { return try await signingIn.value }
        let task = Task { [projectId, idToken, attestor] in
            struct Body: Encodable { var projectId: String; var idToken: String; var attestation: AttestationProof? }
            var proof: AttestationProof?
            if let attestor { proof = try await self.attestationProof(attestor) }
            let session: PlatformSession = try await self.send(
                "POST", "sessions", body: Body(projectId: projectId, idToken: try await idToken(), attestation: proof), authorized: false)
            try await self.tokenStore.save(session)
            return session
        }
        signingIn = task
        defer { signingIn = nil }
        return try await task.value
    }

    /// Ends this user's platform sessions everywhere, including paused turns,
    /// and clears the stored session. Call it when the app signs its user out.
    public func signOut() async throws {
        guard try await tokenStore.load() != nil else { return }
        do {
            let _: OK = try await send("DELETE", "sessions/current")
        } catch AgentError.staleSession {
            // Already ended.
        } catch {
            try? await tokenStore.clear()
            throw error
        }
        try await tokenStore.clear()
    }

    /// The signed-in platform user id, if a session is stored.
    public func currentUserId() async throws -> String? {
        try await tokenStore.load()?.userId
    }

    // MARK: Turns

    /// Sends a message and runs any device tools the assistant asks for until
    /// the turn completes.
    ///
    /// - Parameters:
    ///   - context: The screen the user is on when they send it.
    ///   - conversationId: Continue this conversation; nil starts a new one.
    ///   - attachments: Files the user sent with the message, from `upload(_:)`.
    public func send(
        _ text: String, context: PageContext, conversationId: String? = nil, attachments: [String] = []
    ) async throws -> CompletedTurn {
        struct Body: Encodable {
            var conversationId: String?; var text: String; var context: PageContext; var attachments: [String]?; var timezone: String
        }
        var response: TurnResponse = try await send(
            "POST", "turns",
            body: Body(
                conversationId: conversationId, text: text, context: context, attachments: attachments.isEmpty ? nil : attachments,
                timezone: timeZone().identifier))
        var rounds = 0
        while case .requiresAction(let pending) = response {
            rounds += 1
            guard rounds <= Self.maxDeviceRounds else { throw AgentError.turnDidNotFinish(rounds: rounds - 1) }
            // In order: a later call may depend on an earlier action.
            var results: [DeviceResult] = []
            for call in pending.calls { results.append(await runCall(call)) }
            response = try await submitResults(turnId: pending.turnId, results: results)
        }
        guard case .completed(let done) = response else { throw AgentError.decoding("Turn ended without completing.") }
        return done
    }

    /// Low level: starts a turn without running device calls.
    public func startTurn(_ text: String, context: PageContext, conversationId: String? = nil) async throws -> TurnResponse {
        struct Body: Encodable { var conversationId: String?; var text: String; var context: PageContext; var timezone: String }
        return try await send(
            "POST", "turns", body: Body(conversationId: conversationId, text: text, context: context, timezone: timeZone().identifier))
    }

    /// Low level: posts device results for a paused turn.
    public func submitResults(turnId: String, results: [DeviceResult]) async throws -> TurnResponse {
        struct Body: Encodable { var results: [DeviceResult] }
        return try await send("POST", "turns/\(Self.segment(turnId))/results", body: Body(results: results))
    }

    /// Runs one device call with this client's upload and confirmation prompt.
    package func runCall(_ call: DeviceCall) async -> DeviceResult {
        let turnPrompt = Self.turnConfirmation
        if call.kind == .confirm {
            Self.log.debug(
                "confirm \(call.action, privacy: .public) \(call.toolCallId, privacy: .public): asking (\(turnPrompt != nil ? "turn" : "client", privacy: .public) prompt)")
        }
        let result = await registry.run(
            call, upload: { [weak self] file in
                guard let self else { throw CancellationError() }
                return try await self.upload(file, origin: .app).attachmentId
            }, confirmFallback: turnPrompt ?? confirmationPrompt)
        if call.kind == .confirm {
            Self.log.debug(
                "confirm \(call.action, privacy: .public) \(call.toolCallId, privacy: .public): answered \(result.confirmed == true, privacy: .public)")
        }
        return result
    }

    /// Sets how the user is asked to confirm actions when the registry's
    /// `confirm` isn't set. The chat sets this to its own confirmation card.
    public func setConfirmationPrompt(_ prompt: (@Sendable (ConfirmationRequest) async -> Bool)?) {
        confirmationPrompt = prompt
    }

    // MARK: Files

    public enum FileOrigin: String, Sendable { case user, app }

    /// Uploads a file for the chat: a photo or document the user sends with a
    /// message (`.user`), or a file the app produced for them (`.app`).
    /// Returns the attachment to pass to `send` or `stream`.
    public func upload(_ file: AgentFile, origin: FileOrigin) async throws -> TurnPart.Attachment {
        guard file.data.count <= AgentFile.maxBytes else {
            throw AgentError.invalidRequest("Files can be at most \(AgentFile.maxBytes / 1024 / 1024) MB.")
        }
        guard AgentFile.allowedTypes.contains(file.mimeType) else {
            throw AgentError.invalidRequest("Files of type \(file.mimeType) can't be sent.")
        }
        var request = try await makeRequest(
            "POST", "attachments?origin=\(origin.rawValue)", body: Optional<Empty>.none, authorized: true, accept: "application/json")
        request.setValue(file.mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(file.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file", forHTTPHeaderField: "X-File-Name")
        request.httpBody = file.data
        let (data, response) = try await urlSession.data(for: request)
        try await check(response, data, authorized: true)
        return try decode(TurnPart.Attachment.self, data, "POST", "attachments")
    }

    /// Uploads a photo or document the user sends with a message.
    public func upload(_ file: AgentFile) async throws -> TurnPart.Attachment {
        try await upload(file, origin: .user)
    }

    /// A file's bytes, for showing or sharing an attachment. Only the user's own.
    public func attachmentData(_ attachmentId: String) async throws -> Data {
        let request = try await makeRequest(
            "GET", "attachments/\(Self.segment(attachmentId))", body: Optional<Empty>.none, authorized: true, accept: "*/*")
        let (data, response) = try await urlSession.data(for: request)
        try await check(response, data, authorized: true)
        return data
    }

    // MARK: Capabilities, history, memory

    public func capabilities() async throws -> Capabilities {
        try await send("GET", "capabilities")
    }

    public func latestConversation() async throws -> Conversation {
        try await send("GET", "conversations/latest")
    }

    public func clearConversation(_ id: String) async throws {
        let _: OK = try await send("DELETE", "conversations/\(Self.segment(id))")
    }

    public func memories() async throws -> [Memory] {
        struct List: Decodable { var items: [Memory] }
        let list: List = try await send("GET", "memories")
        return list.items
    }

    /// Saves something the user asked the assistant to remember. Returns its id.
    @discardableResult
    public func remember(_ text: String) async throws -> String {
        let r: Id = try await send("POST", "memories", body: MemoryEdit(text: text))
        return r.id
    }

    /// Replaces a memory's text. Returns the id of the corrected memory.
    @discardableResult
    public func correctMemory(_ id: String, text: String) async throws -> String {
        let r: Id = try await send("PATCH", "memories/\(Self.segment(id))", body: MemoryEdit(text: text))
        return r.id
    }

    public func forgetMemory(_ id: String) async throws {
        let _: OK = try await send("DELETE", "memories/\(Self.segment(id))")
    }

    // MARK: Settling and Undo

    /// Actions the server is still waiting to hear about.
    public func unsettledOperations() async throws -> [UnsettledOperation] {
        struct List: Decodable { var items: [UnsettledOperation] }
        let list: List = try await send("GET", "operations/unsettled")
        return list.items
    }

    /// Reports the outcome of an unsettled operation. Returns the receipt's new status.
    @discardableResult
    public func report(operationId: String, _ outcome: OperationReport) async throws -> String {
        struct Body: Encodable { var ok: Bool; var ref: AppObjectRef?; var error: String?; var known: Bool? }
        let body: Body = switch outcome {
        case .succeeded(let ref): Body(ok: true, ref: ref)
        case .failed(let error, let known): Body(ok: false, error: String(error.prefix(2000)), known: known)
        }
        let r: Status = try await send("POST", "operations/\(Self.segment(operationId))/result", body: body)
        return r.status
    }

    public enum Settlement: Sendable, Hashable {
        /// Reported; `status` is the receipt's new status.
        case reported(status: String)
        /// Left for later: no lookup registered, or the lookup failed.
        case skipped(reason: String)
    }

    /// Settles actions interrupted by the app closing, using each action's
    /// `lookup` handler. Call it on launch after sign-in.
    @discardableResult
    public func settleUnsettled() async throws -> [String: Settlement] {
        var settled: [String: Settlement] = [:]
        for op in try await unsettledOperations() {
            let found: AppObjectRef??
            do {
                found = try await registry.lookup(action: op.action, operationId: op.operationId)
            } catch {
                settled[op.operationId] = .skipped(reason: ActionRegistry.message(error))
                continue
            }
            switch found {
            case .none:
                settled[op.operationId] = .skipped(reason: "No lookup registered for \(op.action).")
            case .some(.some(let ref)):
                settled[op.operationId] = .reported(status: try await report(operationId: op.operationId, .succeeded(ref)))
            case .some(.none):
                // Nothing with this operation id exists: the action never took effect.
                let status = try await report(
                    operationId: op.operationId, .failed("The app has no record of this action.", known: true))
                settled[op.operationId] = .reported(status: status)
            }
        }
        return settled
    }

    /// Undoes an action from the app's own UI. For a device action the
    /// server asks for compensation, the registered undo handler runs here,
    /// and the result is reported back.
    public func undo(operationId: String) async throws -> UndoOutcome {
        struct Begin: Decodable { var status: String; var action: String?; var ref: AppObjectRef?; var summary: String?; var reason: String? }
        let id = Self.segment(operationId)
        let begun: Begin = try await send("POST", "operations/\(id)/undo")
        switch begun.status {
        case "undone":
            return .undone(summary: begun.summary)
        case "compensate":
            guard let action = begun.action, let ref = begun.ref else { throw AgentError.decoding("Undo response missing action or ref.") }
            struct Body: Encodable { var ok: Bool; var reason: String? }
            let body: Body
            do {
                try await registry.compensate(action: action, operationId: operationId, ref: ref)
                body = Body(ok: true)
            } catch {
                body = Body(ok: false, reason: ActionRegistry.message(error))
            }
            let r: Begin = try await send("POST", "operations/\(id)/undo-result", body: body)
            return r.status == "undone" ? .undone(summary: nil) : .refused(reason: r.reason ?? "The app couldn't undo it.")
        default:
            return .refused(reason: begun.reason ?? "This action can't be undone.")
        }
    }

    // MARK: Transport

    private struct OK: Decodable {}
    private struct Id: Decodable { var id: String }
    private struct Status: Decodable { var status: String }
    private struct MemoryEdit: Encodable { var text: String }
    private struct Empty: Encodable {}
    struct ErrorBody: Decodable { var error: String?; var code: String? }

    func send<R: Decodable>(_ method: String, _ path: String, authorized: Bool = true) async throws -> R {
        try await send(method, path, body: Optional<Empty>.none, authorized: authorized)
    }

    func send<B: Encodable, R: Decodable>(
        _ method: String, _ path: String, body: B?, authorized: Bool = true
    ) async throws -> R {
        let request = try await makeRequest(method, path, body: body, authorized: authorized, accept: "application/json")
        let (data, response) = try await urlSession.data(for: request)
        try await check(response, data, authorized: authorized)
        return try decode(R.self, data, method, path)
    }

    func makeRequest<B: Encodable>(
        _ method: String, _ path: String, body: B?, authorized: Bool, accept: String
    ) async throws -> URLRequest {
        guard let url = URL(string: baseURL.absoluteString + "/" + path) else { throw AgentError.invalidRequest("Bad path \(path).") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        } else if method == "POST" {
            // The API reads a JSON body on every POST; send an empty one.
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
        }
        if authorized {
            request.setValue("Bearer \(try await session().sessionToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Throws the mapped error for a non-2xx response.
    func check(_ response: URLResponse, _ data: Data, authorized: Bool) async throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard !(200..<300).contains(status) else { return }
        let err = try? JSONDecoder().decode(ErrorBody.self, from: data)
        try await fail(AgentError(status: status, code: err?.code, message: err?.error ?? "Request failed (\(status))."), authorized: authorized)
    }

    /// Throws `error`, clearing the stored session first if it ended.
    func fail(_ error: AgentError, authorized: Bool = true) async throws -> Never {
        if case .staleSession = error, authorized { try? await tokenStore.clear() }
        throw error
    }

    func decode<R: Decodable>(_ type: R.Type, _ data: Data, _ method: String, _ path: String) throws -> R {
        do {
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            throw AgentError.decoding("Unexpected response from \(method) /v1/\(path): \(error)")
        }
    }

    private func session() async throws -> PlatformSession {
        if let stored = try await tokenStore.load(), !stored.isExpired() { return stored }
        return try await signIn()
    }

    static func segment(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s
    }
}
