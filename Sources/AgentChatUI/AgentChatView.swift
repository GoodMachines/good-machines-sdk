import AgentKit
import PhotosUI
import SwiftUI

/// A native chat with the app's assistant: streamed replies, cards for the
/// actions it took with Undo, the app's own views and links to its screens,
/// confirmations, photos and files both ways, and the user's memory controls.
///
/// Present it as a sheet, or push it in a navigation stack:
/// ```swift
/// .sheet(isPresented: $showAssistant) {
///     AgentChatView(model: chat, memory: memory)
/// }
/// ```
public struct AgentChatView: View {
    @Bindable private var model: AgentChatModel
    private let memory: AgentMemoryModel?
    @Environment(\.agentChatTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
    @Environment(\.scenePhase) private var scenePhase
    @State private var showMemory = false
    @State private var confirmClear = false
    @State private var pickingPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var pickingFile = false
    @FocusState private var composerFocused: Bool
    private let subtitle: String?
    private let moreMenu: AnyView?

    /// - Parameters:
    ///   - memory: Pass one to show the memory screen button.
    ///   - subtitle: Shown under the title, for example the model in use.
    ///   - moreMenu: Extra items for the toolbar's More menu, for example `AgentModelPicker`.
    public init<Menu: View>(
        model: AgentChatModel, memory: AgentMemoryModel? = nil, subtitle: String? = nil,
        @ViewBuilder moreMenu: () -> Menu
    ) {
        self.model = model
        self.memory = memory
        self.subtitle = subtitle
        self.moreMenu = AnyView(moreMenu())
    }

    /// - Parameter memory: Pass one to show the memory screen button.
    public init(model: AgentChatModel, memory: AgentMemoryModel? = nil) {
        self.model = model
        self.memory = memory
        self.subtitle = nil
        self.moreMenu = nil
    }

    public var body: some View {
        NavigationStack {
            transcript
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                .navigationTitle(theme.title)
                .navigationSubtitle(subtitle ?? "")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbar }
                .sheet(isPresented: $showMemory) {
                    if let memory { AgentMemoryView(model: memory) }
                }
                .confirmationDialog("Clear this conversation?", isPresented: $confirmClear, titleVisibility: .visible) {
                    Button("Clear Conversation", role: .destructive) { Task { await model.clear() } }
                } message: {
                    Text("The assistant keeps what it remembers about you. Manage that in Memory.")
                }
                .alert("Something went wrong", isPresented: errorShown) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(model.errorMessage ?? "")
                }
        }
        .tint(theme.accent)
        .task { await model.load() }
        // Messages a background run wrote while the app was away.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
        // Nobody can answer a card on a closed chat: let the turn move on. Only
        // when the chat was presented (a sheet or a pushed screen) and so is
        // closing. A chat in a tab also disappears on a tab switch, but it's
        // still there to answer, so its cards keep waiting.
        .onDisappear { if isPresented { model.declinePendingConfirmations() } }
        // The assistant opened a screen the user asked for: get out of its way.
        .onChange(of: model.screensOpened) { close() }
        .photosPicker(isPresented: $pickingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self), let file = AgentFile.photo(data) else {
                    model.errorMessage = "That photo couldn't be loaded."
                    return
                }
                await model.attach(file)
            }
        }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.pdf, .commaSeparatedText, .plainText, .json, .image]) { result in
            guard case .success(let url) = result else { return }
            Task {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let picked = try AgentFile.document(at: url)
                    let file = picked.flatMap { $0.mimeType.hasPrefix("image/") ? (AgentFile.photo($0.data, name: $0.name) ?? $0) : $0 }
                    guard let file else {
                        model.errorMessage = "That kind of file can't be sent."
                        return
                    }
                    await model.attach(file)
                } catch {
                    model.errorMessage = "That file couldn't be read."
                }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: model.messages.count { $0.role == .user })
        .sensoryFeedback(.selection, trigger: model.repliesReceived)
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(model.messages) { message in
                    MessageRow(message: message, model: model) { card in
                        Task { await model.undo(card) }
                    }
                    .id(message.id)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .animation(ChatMotion.insert, value: model.messages.map(\.id))
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if model.messages.isEmpty {
                if model.phase == .loading { ProgressView() } else { EmptyChat(prompt: theme.emptyPrompt) }
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 6) {
            if !model.pendingFiles.isEmpty || model.isUploading { PendingFilesRow(model: model) }
            composerRow
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button { pickingPhoto = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                Button { pickingFile = true } label: { Label("Choose File", systemImage: "folder") }
            } label: {
                Image(systemName: "plus.circle.fill").font(.system(size: 28)).foregroundStyle(.secondary)
            }
            .disabled(isWorking || model.pendingFiles.count >= 4)
            .accessibilityLabel("Attach")
            .accessibilityIdentifier("agentChat.attach")

            TextField("Message", text: $model.draft, axis: .vertical)
                .font(theme.font)
                .lineLimit(1...6)
                .focused($composerFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.fill.tertiary, in: .rect(cornerRadius: 22))
                .onSubmit(send)
                .submitLabel(.send)
                .accessibilityLabel("Message the assistant")

            if isWorking {
                Button(action: model.stop) {
                    Image(systemName: "stop.circle.fill").font(.system(size: 32))
                }
                .accessibilityLabel("Stop")
                .transition(.scale.combined(with: .opacity))
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(!model.canSend)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("agentChat.send")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(ChatMotion.state, value: isWorking)
        .padding(.horizontal, 12)
    }

    private var isWorking: Bool {
        switch model.phase {
        case .thinking, .runningTools: true
        case .idle, .loading: false
        }
    }

    // Closing the chat on purpose answers waiting cards no, wherever it's hosted.
    private func close() {
        model.declinePendingConfirmations()
        dismiss()
    }

    private func send() {
        guard model.canSend else { return }
        model.send()
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { close() }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if memory != nil {
                Button { showMemory = true } label: { Label("Memory", systemImage: "brain") }
            }
            Menu {
                if let moreMenu { moreMenu }
                Button(role: .destructive) { confirmClear = true } label: {
                    Label("Clear Conversation", systemImage: "trash")
                }
                .disabled(model.messages.isEmpty)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

// MARK: - Rows

private struct EmptyChat: View {
    let prompt: String
    @Environment(\.agentChatTheme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(theme.accent)
                .symbolEffect(.breathe, options: .nonRepeating)
            Text(prompt)
                .font(theme.font)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .transition(.opacity)
    }
}

struct MessageRow: View {
    let message: AgentChatModel.Message
    let model: AgentChatModel
    let undo: (AgentChatModel.ActionCard) -> Void
    @Environment(\.agentChatTheme) private var theme

    var body: some View {
        switch message.role {
        case .user where message.isAutomatic:
            // A background run's request: not something the user typed.
            Label(message.text, systemImage: "bell")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 24)
                .accessibilityIdentifier("agentChat.automatic")
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                PartsView(parts: message.parts, model: model)
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(theme.font)
                        .foregroundStyle(theme.userText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(theme.userBubble, in: .rect(cornerRadius: theme.bubbleRadius))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 48)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if message.isStreaming, message.text.isEmpty, message.confirmations.isEmpty {
                    WorkingIndicator(phase: model.phase)
                } else if !message.text.isEmpty {
                    Text(Self.markdown(message.text))
                        .font(theme.font)
                        .foregroundStyle(theme.assistantText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(theme.assistantBubble, in: .rect(cornerRadius: theme.bubbleRadius))
                        .contentTransition(.interpolate)
                        .textSelection(.enabled)
                        // The previous step's text, until the next step's arrives.
                        .opacity(message.isStepPending ? 0.5 : 1)
                        .animation(ChatMotion.state, value: message.isStepPending)
                }
                ForEach(message.confirmations) { confirmation in
                    ConfirmationCard(confirmation: confirmation) { model.answer(confirmation, confirmed: $0) }
                }
                PartsView(parts: message.parts, model: model)
                ForEach(message.actions) { card in
                    ActionCardView(card: card) { undo(card) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 48)
        }
    }

    /// Inline Markdown (bold, italics, code) without links. Replies can repeat
    /// untrusted data the app read for the assistant, so a link in one could
    /// point anywhere; the text stays, the link target doesn't.
    static func markdown(_ text: String) -> AttributedString {
        guard var styled = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(text) }
        for run in styled.runs where run.link != nil {
            styled[run.range].link = nil
        }
        return styled
    }
}

/// Three dots while the assistant thinks, with what the app is doing when it runs tools.
struct WorkingIndicator: View {
    let phase: AgentChatModel.Phase
    @Environment(\.agentChatTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .frame(width: 7, height: 7)
                        .phaseAnimator([0.3, 1.0]) { dot, value in
                            dot.opacity(value).scaleEffect(0.8 + 0.2 * value)
                        } animation: { _ in
                            .spring(duration: 0.5, bounce: 0).delay(Double(i) * 0.15)
                        }
                }
            }
            .foregroundStyle(.secondary)
            if case .runningTools(let names) = phase {
                Text(label(names))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(theme.assistantBubble, in: .rect(cornerRadius: theme.bubbleRadius))
        .animation(ChatMotion.state, value: phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The assistant is working")
    }

    private func label(_ names: [String]) -> String {
        let readable = Set(names.map(AgentChatModel.defaultTitle)).sorted()
        return readable.isEmpty ? "Working in the app" : readable.joined(separator: ", ")
    }
}

struct ActionCardView: View {
    let card: AgentChatModel.ActionCard
    let undo: () -> Void
    @Environment(\.agentChatTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(iconStyle)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.subheadline.weight(.semibold))
                    .strikethrough(card.state == .undone, color: .secondary)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 8)
            switch card.state {
            case .done where card.canUndo:
                Button("Undo", action: undo)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            case .done:
                EmptyView()
            case .undoing:
                ProgressView().controlSize(.small)
            case .undone, .failed:
                EmptyView()
            }
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator, lineWidth: 0.5))
        .animation(ChatMotion.state, value: card.state)
        .sensoryFeedback(.success, trigger: card.state == .undone) { _, undone in undone }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch card.state {
        case .done, .undoing: "checkmark.circle.fill"
        case .undone: "arrow.uturn.backward.circle.fill"
        case .failed: card.cancelled ? "xmark.circle.fill" : "exclamationmark.circle.fill"
        }
    }

    private var iconStyle: Color {
        switch card.state {
        case .done, .undoing: theme.accent
        case .undone: .secondary
        case .failed: card.cancelled ? .secondary : .orange
        }
    }

    private var status: String {
        switch card.state {
        case .done: "Done"
        case .undoing: "Undoing…"
        case .undone: "Undone"
        case .failed(let reason): reason
        }
    }
}
