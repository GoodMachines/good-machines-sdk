#if canImport(SwiftUI)
import Observation
import SwiftUI

/// Tracks the screen the user is on, for sending with each message.
///
/// Put one in the environment at the root (`.environment(\.agentContext, tracker)`)
/// and mark screens with `.agentContext(page:...)`. Read `current` when the user
/// sends a message, so the context is the one they saw at that moment.
@MainActor
@Observable
public final class AgentContextTracker {
    public private(set) var current: PageContext?
    private var revision = 0

    public init() {}

    public func update(page: String, projectId: String?, selection: PageContext.Selection?, visible: JSONValue?) {
        revision += 1
        current = PageContext(
            page: page, projectId: projectId, selection: selection, visible: visible, observedAt: .now, revision: revision)
    }

    /// The current context, or a bare one for `fallbackPage` before any screen reported.
    public func snapshot(fallbackPage: String = "unknown") -> PageContext {
        current ?? PageContext(page: fallbackPage, revision: revision)
    }
}

extension EnvironmentValues {
    @Entry public var agentContext: AgentContextTracker? = nil
}

private struct AgentContextModifier: ViewModifier {
    @Environment(\.agentContext) private var tracker
    let key: Key

    struct Key: Equatable {
        var page: String
        var projectId: String?
        var selection: PageContext.Selection?
        var visible: JSONValue?
    }

    func body(content: Content) -> some View {
        content
            .onAppear(perform: report)
            .onChange(of: key) { report() }
    }

    private func report() {
        tracker?.update(page: key.page, projectId: key.projectId, selection: key.selection, visible: key.visible)
    }
}

extension View {
    /// Tells the assistant which screen this is and what's selected on it.
    /// Updates whenever the arguments change and when the view appears.
    public func agentContext(
        page: String, projectId: String? = nil, selection: PageContext.Selection? = nil, visible: JSONValue? = nil
    ) -> some View {
        modifier(AgentContextModifier(key: .init(page: page, projectId: projectId, selection: selection, visible: visible)))
    }
}
#endif
