import AgentKit
import Foundation
import SwiftUI

/// A scripted service for SwiftUI previews and demos. Replies stream word by
/// word; a message containing "add" runs a pretend action with Undo.
public actor PreviewAgentService: AgentChatService {
    private var history: [ConversationMessage]
    private var memoryItems: [Memory]
    private var counter = 0

    public init(history: [ConversationMessage] = [], memories: [Memory] = PreviewAgentService.sampleMemories) {
        self.history = history
        self.memoryItems = memories
    }

    public static let sampleMemories = [
        Memory(id: "m1", text: "Prefers to plan the day before 9am", origin: "explicit", updatedAt: "2026-10-04T08:00:00Z"),
        Memory(id: "m2", text: "Works on the Groceries and Launch projects", origin: "learned", updatedAt: "2026-10-03T18:00:00Z"),
    ]

    public static let sampleHistory = [
        ConversationMessage(role: "user", text: "What's on my list today?"),
        ConversationMessage(role: "assistant", text: "Three things: **buy milk**, review the launch notes, and call the vet."),
    ]

    public nonisolated func stream(_ text: String, context: PageContext, conversationId: String?) -> AsyncThrowingStream<TurnUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let acts = text.localizedCaseInsensitiveContains("add")
                if acts {
                    try await Task.sleep(for: .milliseconds(400))
                    continuation.yield(.runningTools([DeviceCall(toolCallId: "c1", tool: "create_task", kind: .action, action: "create_task")]))
                    try await Task.sleep(for: .milliseconds(700))
                }
                let reply = acts ? "Added it to **Groceries**. Anything else?" : "Here's what I found: you're free after 3pm."
                var shown = ""
                for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
                    try await Task.sleep(for: .milliseconds(60))
                    shown += (shown.isEmpty ? "" : " ") + word
                    continuation.yield(.text(shown))
                }
                let op = await self.nextOperation()
                await self.append(text, reply)
                continuation.yield(.completed(CompletedTurn(
                    turnId: "t\(op)", conversationId: "preview", text: reply, model: "preview",
                    events: acts ? [TurnEvent(tool: "create_task", ok: true, detail: "create_task", operationId: "op\(op)", undoable: true)] : [])))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func latestConversation() async throws -> Conversation {
        Conversation(conversationId: history.isEmpty ? nil : "preview", messages: history)
    }

    public func clearConversation(_ id: String) async throws { history = [] }

    public func undo(operationId: String) async throws -> UndoOutcome {
        try await Task.sleep(for: .milliseconds(500))
        return .undone(summary: nil)
    }

    public func memories() async throws -> [Memory] { memoryItems }

    public func upload(_ file: AgentFile) async throws -> TurnPart.Attachment {
        throw AgentError.invalidRequest("Previews can't take files.")
    }

    public func attachmentData(_ attachmentId: String) async throws -> Data {
        throw AgentError.invalidRequest("Previews have no files.")
    }

    public func setConfirmationPrompt(_ prompt: (@Sendable (ConfirmationRequest) async -> Bool)?) async {}

    public func remember(_ text: String) async throws -> String {
        let id = "m\(memoryItems.count + 1)"
        memoryItems.insert(Memory(id: id, text: text, origin: "explicit", updatedAt: Date.now.ISO8601Format()), at: 0)
        return id
    }

    public func correctMemory(_ id: String, text: String) async throws -> String {
        guard let i = memoryItems.firstIndex(where: { $0.id == id }) else { throw AgentError.notFound("Memory not found.") }
        memoryItems[i].text = text
        return id
    }

    public func forgetMemory(_ id: String) async throws { memoryItems.removeAll { $0.id == id } }

    private func nextOperation() -> Int {
        counter += 1
        return counter
    }

    private func append(_ user: String, _ reply: String) {
        history += [ConversationMessage(role: "user", text: user), ConversationMessage(role: "assistant", text: reply)]
    }
}

#Preview("Chat") {
    @Previewable @State var service = PreviewAgentService(history: PreviewAgentService.sampleHistory)
    @Previewable @State var chat: AgentChatModel? = nil
    @Previewable @State var memory: AgentMemoryModel? = nil
    if let chat, let memory {
        AgentChatView(model: chat, memory: memory)
    } else {
        Color.clear.onAppear {
            chat = AgentChatModel(service: service)
            memory = AgentMemoryModel(service: service)
        }
    }
}

#Preview("Empty chat, custom theme") {
    let service = PreviewAgentService()
    AgentChatView(model: AgentChatModel(service: service))
        .agentChatTheme(AgentChatTheme(
            title: "Planner", accent: .orange, userBubble: .orange, font: .system(.body, design: .rounded),
            emptyPrompt: "Ask me to plan your afternoon."))
}

#Preview("Memory") {
    @Previewable @State var model = AgentMemoryModel(service: PreviewAgentService())
    AgentMemoryView(model: model)
}

#Preview("Action cards") {
    VStack(spacing: 12) {
        ActionCardView(card: .init(id: "1", tool: "create_task", title: "Create task", state: .done)) {}
        ActionCardView(card: .init(id: "2", tool: "create_task", title: "Create task", state: .undoing)) {}
        ActionCardView(card: .init(id: "3", tool: "create_task", title: "Create task", state: .undone)) {}
        ActionCardView(card: .init(id: "4", tool: "move_task", title: "Move task", state: .failed("This action is turned off."))) {}
        WorkingIndicator(phase: .runningTools(["create_task"]))
    }
    .padding()
}

