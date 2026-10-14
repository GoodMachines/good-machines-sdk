import AgentKit
import Foundation
import Observation
import os

/// The state behind `AgentChatView`. Use it directly to build your own chat UI.
@MainActor
@Observable
public final class AgentChatModel {
    public enum Role: Sendable, Hashable { case user, assistant }

    /// An action the assistant took in the app, shown under its reply, with
    /// Undo when it can be undone.
    public struct ActionCard: Identifiable, Sendable, Hashable {
        public enum State: Sendable, Hashable {
            case done
            case undoing
            case undone
            /// The action didn't happen (refused by policy, the app reported a
            /// failure, or the user said no: then the reason is "Cancelled").
            case failed(String)
        }

        /// The operation id.
        public let id: String
        public let tool: String
        public let title: String
        public var state: State
        /// Whether Undo is offered: the server says the action supports it,
        /// or, from older servers, the app registered an undo handler for it.
        public var canUndo: Bool = false
        /// The user declined the action when asked to confirm it.
        public var cancelled: Bool = false
    }

    /// The user's answer to an action that needs confirmation, asked in the chat.
    public struct Confirmation: Identifiable, Sendable, Hashable {
        public enum State: Sendable, Hashable { case asking, confirmed, declined }
        public let id: UUID
        public let action: String
        /// The exact action, in words: the app's wording from
        /// `ActionRegistry.describeConfirmation` when it has one, else the server's.
        public let summary: String
        public var state: State
        /// The tool call being confirmed, when the service knows it.
        public var toolCallId: String? = nil
    }

    public struct Message: Identifiable, Sendable, Hashable {
        public let id: UUID
        public let role: Role
        public var text: String
        public var actions: [ActionCard]
        /// Views, links and files: for a reply, what the assistant added; for
        /// the user's message, the files they sent.
        public var parts: [TurnPart]
        /// Actions in this reply the user was asked to confirm.
        public var confirmations: [Confirmation]
        /// True while the reply is still arriving.
        public var isStreaming: Bool
        /// True while `text` is the previous step's, kept until the next
        /// step's text arrives. The chat dims it.
        public var isStepPending = false
        /// The server's id, once known. Messages are merged by it.
        public var serverId: String?
        /// "user", "assistant" or "background" (both sides of a background
        /// run), when the server said.
        public var origin: String?

        init(
            role: Role, text: String, actions: [ActionCard] = [], parts: [TurnPart] = [], isStreaming: Bool = false,
            serverId: String? = nil, origin: String? = nil
        ) {
            self.id = UUID()
            self.role = role
            self.text = text
            self.actions = actions
            self.parts = parts
            self.confirmations = []
            self.isStreaming = isStreaming
            self.serverId = serverId
            self.origin = origin
        }

        init(_ stored: ConversationMessage) {
            self.init(
                role: stored.role == "user" ? .user : .assistant, text: stored.text, parts: (stored.parts ?? []).filter(\.isShown),
                serverId: stored.id, origin: stored.origin)
        }

        /// A user-side message a background run wrote, not something the user typed.
        public var isAutomatic: Bool { origin == "background" && role == .user }
    }

    public enum Phase: Sendable, Hashable {
        case idle
        case thinking
        /// The app is running tools for the assistant (their names).
        case runningTools([String])
        case loading
    }

    public private(set) var messages: [Message] = []
    public private(set) var phase: Phase = .idle
    public private(set) var conversationId: String?
    public var draft = ""
    /// Files picked for the next message, already uploaded.
    public private(set) var pendingFiles: [TurnPart.Attachment] = []
    /// True while a picked file uploads.
    public private(set) var isUploading = false
    /// Set when something fails; the view shows it and clears it.
    public var errorMessage: String?

    public var canSend: Bool {
        phase == .idle && !isUploading
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingFiles.isEmpty)
    }

    /// Bumped after each reply arrives, for haptics and scrolling.
    public private(set) var repliesReceived = 0
    /// Bumped when the assistant opened a screen the user asked for. The chat
    /// view closes itself so the screen shows.
    public private(set) var screensOpened = 0

    /// The app's views and destinations, for rendering and opening them.
    public var registry: ActionRegistry? { service.chatRegistry }

    private let service: any AgentChatService
    private let context: @MainActor () -> PageContext
    private let actionTitle: @Sendable (String) -> String
    private var sending: Task<Void, Never>?
    /// Confirmations waiting for the user, by tool call id (or the card's id
    /// when the service gives none).
    private var answers: [String: PendingAnswer] = [:]
    private var fileCache: [String: Data] = [:]
    private var fileLoads: [String: Task<Data, Error>] = [:]
    private var refreshing = false
    private var refreshAgain = false
    private static let log = Logger(subsystem: "AgentChatUI", category: "confirmations")

    private struct PendingAnswer {
        var confirmationId: UUID
        var replyId: UUID?
        var continuation: CheckedContinuation<Bool, Never>
    }

    /// - Parameters:
    ///   - contextTracker: Where the current screen is read from at send time.
    ///   - fallbackPage: The page name used when no screen has reported context.
    ///   - actionTitle: The card title for an action's tool name. Defaults to
    ///     "create_task" → "Create task".
    public init(
        service: any AgentChatService,
        contextTracker: AgentContextTracker? = nil,
        fallbackPage: String = "chat",
        actionTitle: @escaping @Sendable (String) -> String = AgentChatModel.defaultTitle
    ) {
        self.service = service
        self.context = { contextTracker?.snapshot(fallbackPage: fallbackPage) ?? PageContext(page: fallbackPage) }
        self.actionTitle = actionTitle
        // Actions that need confirmation ask here, in the chat, unless the
        // app set its own `confirm` on the registry. A service that can bind
        // the prompt to each turn gets it in `send()`; others get one prompt
        // for the whole service, which the latest chat model replaces.
        guard !(service is any AgentChatTurnConfirming) else { return }
        let prompt: @Sendable (ConfirmationRequest) async -> Bool = { [weak self] request in
            guard let self else { return false }
            return await self.ask(request)
        }
        Task { [service] in await service.setConfirmationPrompt(prompt) }
    }

    public nonisolated static func defaultTitle(_ tool: String) -> String {
        let words = tool.split(separator: "_").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    // MARK: Actions

    /// Loads the latest conversation. Safe to call more than once.
    public func load() async {
        guard messages.isEmpty, phase == .idle else { return }
        phase = .loading
        defer { phase = .idle }
        do {
            let latest = try await service.latestConversation()
            conversationId = latest.conversationId
            messages = latest.messages.map(Message.init)
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Fetches the latest conversation and adds messages this chat hasn't
    /// shown yet, such as a background run's alert or scheduled reply.
    /// Messages are matched by the server's id, so nothing shows twice.
    /// The chat view calls it when the app comes to the foreground, and the
    /// model after each reply. During a reply it runs once the reply ends.
    public func refresh() async {
        guard phase == .idle, !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            guard let latest = try? await service.latestConversation() else { return }
            // A turn started while this was loading: merge after it ends.
            guard phase == .idle else {
                refreshAgain = true
                return
            }
            merge(latest)
        } while refreshAgain
    }

    /// Call it from the app's notification delegate when a notification from
    /// the assistant arrives while the app is open, so an open chat shows
    /// the new message:
    ///
    ///     func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
    ///         -> UNNotificationPresentationOptions {
    ///         if let n = AgentNotification(userInfo: notification.request.content.userInfo) { await chat.didReceive(n) }
    ///         return [.banner, .sound]
    ///     }
    public func didReceive(_ notification: AgentNotification) async {
        await refresh()
    }

    /// Sends the draft, with any picked files.
    public func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let files = pendingFiles
        draft = ""
        pendingFiles = []
        messages.append(Message(role: .user, text: text, parts: files.map(TurnPart.attachment)))
        messages.append(Message(role: .assistant, text: "", isStreaming: true))
        phase = .thinking
        let replyId = messages[messages.count - 1].id
        let stream: AsyncThrowingStream<TurnUpdate, Error>
        if let turns = service as? any AgentChatTurnConfirming {
            // This turn's confirmations ask in this reply, whatever other chat
            // models exist for the same service.
            let prompt: @Sendable (ConfirmationRequest) async -> Bool = { [weak self] request in
                guard let self else { return false }
                return await self.ask(request, in: replyId)
            }
            stream = turns.stream(text, context: context(), conversationId: conversationId, attachments: files.map(\.attachmentId), confirm: prompt)
        } else {
            stream = service.stream(text, context: context(), conversationId: conversationId, attachments: files.map(\.attachmentId))
        }
        sending = Task {
            let completed = await self.receive(stream, replyId: replyId, sent: text, files: files)
            if completed || self.refreshAgain { await self.refresh() }
        }
    }

    /// Uploads a photo or document for the next message.
    public func attach(_ file: AgentFile) async {
        guard pendingFiles.count < 4 else {
            errorMessage = "You can send up to 4 files at a time."
            return
        }
        isUploading = true
        defer { isUploading = false }
        do {
            let uploaded = try await service.upload(file)
            fileCache[uploaded.attachmentId] = file.data
            pendingFiles.append(uploaded)
        } catch {
            errorMessage = describe(error)
        }
    }

    /// Takes a picked file back before sending.
    public func removePendingFile(_ attachmentId: String) {
        pendingFiles.removeAll { $0.attachmentId == attachmentId }
    }

    /// An attachment's bytes, to show or share it. A failed fetch is tried
    /// twice more after a short wait, and callers asking for the same file
    /// at once share one fetch, which carries on if a caller is cancelled.
    public func data(for attachment: TurnPart.Attachment) async throws -> Data {
        let id = attachment.attachmentId
        if let cached = fileCache[id] { return cached }
        let load: Task<Data, Error>
        if let inFlight = fileLoads[id] {
            load = inFlight
        } else {
            load = Task { [service] in
                var attempt = 0
                while true {
                    do {
                        return try await service.attachmentData(id)
                    } catch {
                        guard attempt < Self.fileRetryDelays.count else { throw error }
                        try await Task.sleep(for: Self.fileRetryDelays[attempt])
                        attempt += 1
                    }
                }
            }
            fileLoads[id] = load
        }
        do {
            let data = try await load.value
            fileCache[id] = data
            fileLoads[id] = nil
            return data
        } catch {
            if fileLoads[id] == load { fileLoads[id] = nil }
            throw error
        }
    }

    /// Waits between attempts at loading a file.
    static let fileRetryDelays: [Duration] = [.milliseconds(300), .milliseconds(900)]

    /// Opens a link the assistant offered.
    public func open(_ destination: String, params: JSONValue) {
        if registry?.open(destination, params: params) != true {
            errorMessage = "This screen isn't available in this version of the app."
        }
    }

    /// The user's answer to a confirmation shown in the chat.
    public func answer(_ confirmation: Confirmation, confirmed: Bool) {
        let key = Self.answerKey(confirmation.toolCallId, confirmation.id)
        guard let pending = answers[key], pending.confirmationId == confirmation.id else {
            Self.log.error("confirm \(confirmation.action, privacy: .public): answer for a card that isn't waiting")
            return
        }
        answers[key] = nil
        setConfirmation(confirmation.id, confirmed ? .confirmed : .declined)
        Self.log.debug("confirm \(confirmation.action, privacy: .public) \(key, privacy: .public): answered \(confirmed, privacy: .public)")
        pending.continuation.resume(returning: confirmed)
    }

    /// Answers no to every confirmation still waiting, so the turn moves on.
    /// `AgentChatView` calls it when it's closed (Done, or a presented chat
    /// going away), not when a chat in a tab is switched away from. Call it
    /// yourself if your own chat UI is dismissed mid-reply.
    public func declinePendingConfirmations() {
        drain { _ in true }
    }

    /// Stops waiting for the current reply. Actions the app already ran stay
    /// done; a confirmation still waiting is answered no.
    public func stop() {
        declinePendingConfirmations()
        sending?.cancel()
    }

    /// Waits for the reply in progress, if any.
    public func waitForReply() async {
        await sending?.value
    }

    public func undo(_ card: ActionCard) async {
        guard card.state == .done, card.canUndo else { return }
        setCard(card.id, .undoing)
        do {
            switch try await service.undo(operationId: card.id) {
            case .undone:
                setCard(card.id, .undone)
            case .refused(let reason):
                setCard(card.id, .done)
                errorMessage = reason
            }
        } catch {
            setCard(card.id, .done)
            errorMessage = describe(error)
        }
    }

    /// Clears the conversation on the server and starts a new one.
    public func clear() async {
        stop()
        guard let id = conversationId else {
            messages = []
            return
        }
        do {
            try await service.clearConversation(id)
            messages = []
            conversationId = nil
        } catch {
            errorMessage = describe(error)
        }
    }

    // MARK: Internals

    /// Shows a confirmation card and waits for the answer: in the turn's
    /// reply when given, else in the reply in progress, else in a new reply.
    func ask(_ request: ConfirmationRequest, in replyId: UUID? = nil) async -> Bool {
        let confirmation = Confirmation(
            id: UUID(), action: request.action, summary: request.shownSummary, state: .asking, toolCallId: request.toolCallId)
        let key = Self.answerKey(request.toolCallId, confirmation.id)
        Self.log.debug("confirm \(request.action, privacy: .public) \(key, privacy: .public): asked")
        // The same call asking again replaces its earlier card.
        drain { $0 == key }
        let target = replyId.flatMap { id in messages.contains { $0.id == id } ? id : nil }
            ?? messages.last(where: { $0.role == .assistant && $0.isStreaming })?.id
        let reply: UUID
        if let target {
            reply = target
        } else {
            let added = Message(role: .assistant, text: "")
            messages.append(added)
            reply = added.id
        }
        updateMessage(reply) { $0.confirmations.append(confirmation) }
        Self.log.debug("confirm \(request.action, privacy: .public) \(key, privacy: .public): shown")
        return await withCheckedContinuation {
            answers[key] = PendingAnswer(confirmationId: confirmation.id, replyId: replyId, continuation: $0)
        }
    }

    private static func answerKey(_ toolCallId: String?, _ id: UUID) -> String {
        toolCallId.map { "call:\($0)" } ?? "card:\(id.uuidString)"
    }

    /// Answers no to the waiting confirmations whose key matches.
    private func drain(_ matching: (String) -> Bool) {
        for (key, pending) in answers where matching(key) {
            answers[key] = nil
            setConfirmation(pending.confirmationId, .declined)
            Self.log.debug("confirm \(key, privacy: .public): declined unanswered")
            pending.continuation.resume(returning: false)
        }
    }

    /// Adds the server's messages this chat hasn't shown, matched by id.
    private func merge(_ latest: Conversation) {
        guard let serverConversation = latest.conversationId else { return }
        // Servers before 0.2.2 send no ids: nothing to match on.
        guard latest.messages.allSatisfy({ $0.id != nil }) else { return }
        if let conversationId, conversationId != serverConversation {
            // A different conversation is now the latest (cleared or started elsewhere).
            declinePendingConfirmations()
            self.conversationId = serverConversation
            messages = latest.messages.map(Message.init)
            return
        }
        conversationId = serverConversation
        let known = Set(messages.compactMap(\.serverId))
        var unseen = latest.messages.filter { !known.contains($0.id ?? "") }
        // Messages sent from this chat have no server id yet: match them in
        // order by role and text, so they aren't shown twice.
        for i in messages.indices where messages[i].serverId == nil && !messages[i].isStreaming {
            let role = messages[i].role == .user ? "user" : "assistant"
            guard let j = unseen.firstIndex(where: { $0.role == role && $0.text == messages[i].text }) else { continue }
            messages[i].serverId = unseen[j].id
            messages[i].origin = unseen[j].origin
            unseen.remove(at: j)
        }
        guard !unseen.isEmpty else { return }
        messages.append(contentsOf: unseen.map(Message.init))
        if unseen.contains(where: { $0.role == "assistant" }) { repliesReceived += 1 }
    }

    private func setConfirmation(_ id: UUID, _ state: Confirmation.State) {
        for m in messages.indices {
            if let c = messages[m].confirmations.firstIndex(where: { $0.id == id }) { messages[m].confirmations[c].state = state }
        }
    }

    /// Adds a part to a reply, and opens a screen the user asked for once.
    private func add(_ part: TurnPart, to replyId: UUID) {
        guard part.isShown else { return }
        guard let i = messages.firstIndex(where: { $0.id == replyId }), !messages[i].parts.contains(part) else { return }
        messages[i].parts.append(part)
        if case .navigation(let destination, let params, _, true) = part, registry?.open(destination, params: params) == true {
            screensOpened += 1
        }
    }

    /// Shows the turn as it streams. True when it completed.
    @discardableResult
    private func receive(
        _ stream: AsyncThrowingStream<TurnUpdate, Error>, replyId: UUID, sent: String, files: [TurnPart.Attachment]
    ) async -> Bool {
        var completed = false
        defer {
            // The stream is over: nothing will answer a card still waiting for this turn.
            drain { [answers] key in answers[key]?.replyId == replyId }
            updateMessage(replyId) { $0.isStepPending = false }
            phase = .idle
            sending = nil
        }
        do {
            for try await update in stream {
                switch update {
                case .text(let text):
                    phase = .thinking
                    updateMessage(replyId) { message in
                        // A new step starts empty: keep the last step's text,
                        // dimmed, until the new text arrives.
                        if text.isEmpty, !message.text.isEmpty {
                            message.isStepPending = true
                        } else {
                            message.text = text
                            message.isStepPending = false
                        }
                    }
                case .runningTools(let calls):
                    phase = .runningTools(calls.map(\.action))
                case .part(let part):
                    add(part, to: replyId)
                case .completed(let turn):
                    conversationId = turn.conversationId
                    apply(turn, to: replyId)
                    repliesReceived += 1
                    completed = true
                }
            }
            // Cancelled before completion: keep whatever arrived.
            updateMessage(replyId) { $0.isStreaming = false }
            if let last = messages.last, last.id == replyId, last.text.isEmpty, last.parts.isEmpty, last.confirmations.isEmpty {
                messages.removeLast()
            }
            return completed
        } catch {
            errorMessage = describe(error)
            // Nothing came back: take the message back so it can be sent again.
            if let i = messages.firstIndex(where: { $0.id == replyId }), messages[i].text.isEmpty {
                messages.remove(at: i)
                if let last = messages.last, last.role == .user, last.text == sent {
                    messages.removeLast()
                    if draft.isEmpty { draft = sent }
                    if pendingFiles.isEmpty { pendingFiles = files }
                }
            } else {
                updateMessage(replyId) { $0.isStreaming = false }
            }
            return false
        }
    }

    private func apply(_ turn: CompletedTurn, to replyId: UUID) {
        var cards: [ActionCard] = []
        for event in turn.events {
            guard let op = event.operationId else { continue }
            if event.tool == "undo_action" {
                // The assistant undid something, possibly from an earlier reply.
                if event.ok { setCard(op, .undone) }
                continue
            }
            let cancelled = !event.ok && event.detail == "declined"
            let state: ActionCard.State = event.ok ? .done : .failed(cancelled ? "Cancelled" : event.detail)
            // The server's word when it gave one; else the app's own undo handler.
            let canUndo = event.ok && (event.undoable ?? registry?.deviceTools.first { $0.name == event.tool }?.undo?.supported ?? false)
            cards.append(ActionCard(id: op, tool: event.tool, title: actionTitle(event.tool), state: state, canUndo: canUndo, cancelled: cancelled))
        }
        updateMessage(replyId) {
            $0.text = turn.text
            $0.actions = cards
            $0.isStreaming = false
        }
        // Parts streamed already are kept in order; any the stream missed are added.
        for part in turn.parts { add(part, to: replyId) }
    }

    private func updateMessage(_ id: UUID, _ change: (inout Message) -> Void) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[i])
    }

    private func setCard(_ operationId: String, _ state: ActionCard.State) {
        for m in messages.indices {
            if let c = messages[m].actions.firstIndex(where: { $0.id == operationId }) {
                messages[m].actions[c].state = state
            }
        }
    }
}

extension TurnPart {
    /// Parts the chat shows: views, links and files (the text is shown as the message).
    var isShown: Bool {
        switch self {
        case .view, .navigation, .attachment: true
        case .text, .unknown: false
        }
    }
}
