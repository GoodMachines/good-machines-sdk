import AgentKit
import SwiftUI

/// Asking the user before their data goes to AI providers. `AgentClient`
/// provides it; previews and tests use their own.
public protocol AgentConsentService: Sendable {
    func consentStatus() async throws -> ConsentStatus
    func setConsent(version: Int, granted: Bool) async throws -> ConsentStatus
}

extension AgentClient: AgentConsentService {}

@MainActor @Observable
public final class AgentConsentModel {
    public private(set) var status: ConsentStatus?
    public private(set) var error: String?
    public private(set) var isSaving = false
    private let service: any AgentConsentService

    public init(service: any AgentConsentService) {
        self.service = service
    }

    /// True once the user may chat: consent isn't required, or they agreed.
    public var isGranted: Bool { status?.granted == true }

    public func load() async {
        do {
            status = try await service.consentStatus()
            error = nil
        } catch {
            self.error = describe(error)
        }
    }

    public func answer(_ granted: Bool) async {
        guard let version = status?.version else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            status = try await service.setConsent(version: version, granted: granted)
            error = nil
        } catch AgentError.conflict {
            // The notice changed while it was on screen: show the new one.
            await load()
        } catch {
            self.error = describe(error)
        }
    }
}

/// Shows the app's data-sharing notice before the chat, once per user and
/// notice version, when the developer asks for consent. The chat appears only
/// after the user agrees; the API refuses turns until then either way.
///
///     AgentConsentGate(service: Assistant.client) {
///         AgentChatView(model: chat, memory: memory)
///     }
public struct AgentConsentGate<Content: View>: View {
    @State private var model: AgentConsentModel
    @Environment(\.agentChatTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    private let content: () -> Content

    public init(service: any AgentConsentService, @ViewBuilder content: @escaping () -> Content) {
        _model = State(initialValue: AgentConsentModel(service: service))
        self.content = content
    }

    public var body: some View {
        Group {
            if model.isGranted {
                content()
            } else if let status = model.status {
                notice(status)
            } else if let error = model.error {
                ContentUnavailableView {
                    Label("Can't reach the assistant", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await model.load() } }
                }
            } else {
                ProgressView()
            }
        }
        .task { if model.status == nil { await model.load() } }
    }

    private func notice(_ status: ConsentStatus) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(theme.accent)
                .accessibilityHidden(true)
            Text("Before you start")
                .font(.title2.bold())
            Text(status.text)
                .font(theme.font)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Spacer()
            Button {
                Task { await model.answer(true) }
            } label: {
                Text("Agree and continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
            .controlSize(.large)
            .disabled(model.isSaving)
            .accessibilityIdentifier("agent.consent.agree")
            Button {
                Task {
                    await model.answer(false)
                    dismiss()
                }
            } label: {
                Text("Not now").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(model.isSaving)
            .accessibilityIdentifier("agent.consent.decline")
        }
        .padding(24)
        // A container, so the buttons keep their own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.consent")
    }
}
