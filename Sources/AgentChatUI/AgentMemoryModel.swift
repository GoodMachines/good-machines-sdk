import AgentKit
import Foundation
import Observation

/// The user's own memory controls: see, add, correct and forget what the assistant remembers.
@MainActor
@Observable
public final class AgentMemoryModel {
    public private(set) var items: [Memory] = []
    public private(set) var isLoading = false
    /// True once the first load has finished, whether or not it worked. Reloads after
    /// add, correct or forget keep it true, so an emptied list shows its empty state
    /// rather than a spinner.
    public private(set) var hasLoaded = false
    public var errorMessage: String?

    /// Things the user asked the assistant to remember.
    public var explicit: [Memory] { items.filter { $0.origin == "explicit" } }
    /// Things the assistant picked up from conversations.
    public var learned: [Memory] { items.filter { $0.origin != "explicit" } }

    private let service: any AgentChatService

    public init(service: any AgentChatService) {
        self.service = service
    }

    public func load() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            items = try await service.memories()
        } catch {
            errorMessage = describe(error)
        }
    }

    public func add(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await change { _ = try await self.service.remember(text) }
    }

    /// Replaces a memory's text. The corrected memory may get a new id.
    public func correct(_ memory: Memory, to text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != memory.text else { return }
        await change { _ = try await self.service.correctMemory(memory.id, text: text) }
    }

    public func forget(_ memory: Memory) async {
        // Gone from the list at once; reloaded below either way.
        items.removeAll { $0.id == memory.id }
        await change { try await self.service.forgetMemory(memory.id) }
    }

    private func change(_ work: @escaping () async throws -> Void) async {
        do {
            try await work()
        } catch {
            errorMessage = describe(error)
        }
        await load()
    }
}
