import AgentKit
import SwiftUI

/// A picker for where the assistant's model runs. Sources this device or app
/// can't use are shown disabled with the reason. Put it in `AgentChatView`'s
/// More menu, or in your settings.
public struct AgentModelPicker: View {
    @Binding private var selection: AgentModelSource
    private let service: FoundationAgentService

    public init(selection: Binding<AgentModelSource>, service: FoundationAgentService) {
        self._selection = selection
        self.service = service
    }

    public var body: some View {
        Picker(selection: $selection) {
            ForEach(AgentModelSource.allCases, id: \.self) { source in
                let status = service.status(of: source)
                // In a menu the second text shows as the item's subtitle.
                VStack {
                    Text(source.displayName)
                    if case .unavailable(let reason) = status { Text(reason) }
                }
                .tag(source)
                .selectionDisabled(!status.isAvailable)
                .accessibilityIdentifier("model-\(source.rawValue)")
            }
        } label: {
            Label("Model", systemImage: "cpu")
        }
        .pickerStyle(.menu)
        .onChange(of: selection, initial: true) { _, new in service.source = new }
    }
}
