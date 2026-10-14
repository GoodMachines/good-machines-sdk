import AgentKit
import SwiftUI

/// What the assistant remembers about the user, with add, correct and forget.
public struct AgentMemoryView: View {
    @Bindable private var model: AgentMemoryModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Editing?

    private enum Editing: Identifiable {
        case add
        case correct(Memory)
        var id: String {
            switch self {
            case .add: "add"
            case .correct(let m): m.id
            }
        }
    }

    public init(model: AgentMemoryModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            List {
                if !model.explicit.isEmpty { section("You asked me to remember", model.explicit) }
                if !model.learned.isEmpty { section("Learned from our chats", model.learned) }
            }
            .overlay {
                if model.items.isEmpty, !model.hasLoaded {
                    ProgressView()
                } else if model.items.isEmpty {
                    ContentUnavailableView(
                        "Nothing remembered yet", systemImage: "brain",
                        description: Text("Tell the assistant something to remember, or add it here."))
                }
            }
            .navigationTitle("Memory")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = .add } label: { Label("Add", systemImage: "plus") }
                }
            }
            .refreshable { await model.load() }
            .task { await model.load() }
            .sheet(item: $editing) { editing in
                switch editing {
                case .add:
                    MemoryEditor(title: "Remember", initial: "") { await model.add($0) }
                case .correct(let memory):
                    MemoryEditor(title: "Correct", initial: memory.text) { await model.correct(memory, to: $0) }
                }
            }
            .alert("Something went wrong", isPresented: errorShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private func section(_ title: String, _ items: [Memory]) -> some View {
        Section(title) {
            ForEach(items) { memory in
                Button { editing = .correct(memory) } label: {
                    Text(memory.text).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Correct this memory")
                .swipeActions {
                    Button("Forget", role: .destructive) { Task { await model.forget(memory) } }
                }
                .contextMenu {
                    Button("Correct", systemImage: "pencil") { editing = .correct(memory) }
                    Button("Forget", systemImage: "trash", role: .destructive) { Task { await model.forget(memory) } }
                }
            }
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

private struct MemoryEditor: View {
    let title: String
    let initial: String
    let save: (String) async -> Void
    @State private var text = ""
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Something to remember", text: $text, axis: .vertical)
                    .lineLimit(2...6)
                    .focused($focused)
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            await save(text)
                            dismiss()
                        }
                    }
                    .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == initial)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            text = initial
            focused = true
        }
    }
}
