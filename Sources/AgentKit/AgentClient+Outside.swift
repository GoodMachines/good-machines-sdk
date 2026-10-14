import Foundation

/// Where an APNs device token is valid: the development (sandbox) or the
/// production push environment, matching the app's `aps-environment` entitlement.
public enum PushEnvironment: String, Codable, Sendable {
    case sandbox
    case production
}

/// The result of sending an event.
public struct EventReceipt: Codable, Sendable, Equatable {
    public var accepted: Bool
    /// The app already sent an event with this id; it was ignored.
    public var duplicate: Bool
    /// How many of the user's alerts this event set off.
    public var queuedRuns: Int
}

/// The user's own switches for the assistant outside the chat.
public struct NotificationSettings: Codable, Sendable, Equatable {
    public var notificationsEnabled: Bool
    public var timezone: String?
}

/// A notification the assistant sent.
public struct AgentNotificationItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var body: String
    public var conversationId: String?
    public var createdAt: String
}

/// Reads the assistant's part of a push notification's payload.
public struct AgentNotification: Sendable, Equatable {
    public var notificationId: String
    /// The chat the notification's message landed in.
    public var conversationId: String?

    /// Nil when the notification isn't from the assistant.
    ///
    ///     func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    ///         if let n = AgentNotification(userInfo: response.notification.request.content.userInfo) {
    ///             openAssistantChat(n.conversationId)
    ///         }
    ///     }
    public init?(userInfo: [AnyHashable: Any]) {
        guard let gma = userInfo["gma"] as? [String: Any], let id = gma["notificationId"] as? String else { return nil }
        notificationId = id
        conversationId = gma["conversationId"] as? String
    }
}

extension AgentClient {
    private struct OKResponse: Decodable {}

    // MARK: Events

    /// Tells the assistant something happened for the signed-in user, e.g. a
    /// task became overdue. `type` is a registered event capability; `payload`
    /// must fit its schema. Alerts the user set up in chat run when their
    /// conditions match. Send each event once with a stable `id`: resends
    /// with the same id are ignored.
    @discardableResult
    public func sendEvent(_ type: String, id: String, payload: JSONValue = [:]) async throws -> EventReceipt {
        struct Body: Encodable { var type: String; var eventId: String; var payload: JSONValue }
        return try await send("POST", "events", body: Body(type: type, eventId: id, payload: payload))
    }

    // MARK: Notifications

    /// Registers this device for the assistant's notifications. Call it from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
    /// after sign-in, and again when the signed-in user changes. Also sends the
    /// device's time zone, so "every Sunday at 6" means the user's 6.
    public func registerPushToken(_ deviceToken: Data, environment: PushEnvironment) async throws {
        struct Body: Encodable { var token: String; var environment: PushEnvironment; var timezone: String }
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        let _: OKResponse = try await send(
            "POST", "push-tokens", body: Body(token: hex, environment: environment, timezone: timeZone().identifier))
    }

    /// Stops notifications to this device for the signed-in user. Call it before signing out.
    public func unregisterPushToken(_ deviceToken: Data) async throws {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        let _: OKResponse = try await send("DELETE", "push-tokens/\(Self.segment(hex))")
    }

    public func notificationSettings() async throws -> NotificationSettings {
        try await send("GET", "notification-settings")
    }

    /// The user's own switch for the assistant's notifications.
    @discardableResult
    public func setNotificationsEnabled(_ enabled: Bool) async throws -> NotificationSettings {
        struct Body: Encodable { var notificationsEnabled: Bool }
        return try await send("PATCH", "notification-settings", body: Body(notificationsEnabled: enabled))
    }

    /// Recent notifications the assistant sent this user.
    public func notifications() async throws -> [AgentNotificationItem] {
        struct List: Decodable { var items: [AgentNotificationItem] }
        let list: List = try await send("GET", "notifications")
        return list.items
    }
}
