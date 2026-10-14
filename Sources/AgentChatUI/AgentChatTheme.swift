import SwiftUI

/// The chat's look, in the app's own colors and fonts.
public struct AgentChatTheme: Sendable {
    public var title: String
    public var accent: Color
    public var userBubble: Color
    public var userText: Color
    public var assistantBubble: Color
    public var assistantText: Color
    public var font: Font
    public var bubbleRadius: CGFloat
    /// Shown when there are no messages yet.
    public var emptyPrompt: String

    public init(
        title: String = "Assistant",
        accent: Color = .accentColor,
        userBubble: Color = .accentColor,
        userText: Color = .white,
        assistantBubble: Color = Color(white: 0.5, opacity: 0.12),
        assistantText: Color = .primary,
        font: Font = .body,
        bubbleRadius: CGFloat = 20,
        emptyPrompt: String = "Ask me to find, plan or change something."
    ) {
        self.title = title
        self.accent = accent
        self.userBubble = userBubble
        self.userText = userText
        self.assistantBubble = assistantBubble
        self.assistantText = assistantText
        self.font = font
        self.bubbleRadius = bubbleRadius
        self.emptyPrompt = emptyPrompt
    }
}

extension EnvironmentValues {
    @Entry public var agentChatTheme = AgentChatTheme()
}

extension View {
    public func agentChatTheme(_ theme: AgentChatTheme) -> some View {
        environment(\.agentChatTheme, theme)
    }
}

/// Motion used across the chat: quick, slightly springy, never a linear fade.
enum ChatMotion {
    static let insert = Animation.spring(duration: 0.38, bounce: 0.18)
    static let state = Animation.spring(duration: 0.3, bounce: 0.1)
}
