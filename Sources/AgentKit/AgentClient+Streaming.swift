import Foundation

/// Progress of a streamed turn.
public enum TurnUpdate: Sendable, Hashable {
    /// The reply so far. It can shrink back to empty when the assistant moves
    /// on to a new step (for example after running a tool).
    case text(String)
    /// The device is running these calls for the assistant.
    case runningTools([DeviceCall])
    /// A view, navigation offer or attachment, as soon as the server adds it.
    /// The completed turn's `parts` carries it again.
    case part(TurnPart)
    /// The turn finished. Its `text` is the final reply; show it in place of the streamed text.
    case completed(CompletedTurn)
}

extension AgentClient {
    /// Sends a message and streams the reply, running device tools as the
    /// assistant asks for them. Cancelling the iteration cancels the request.
    public nonisolated func stream(
        _ text: String, context: PageContext, conversationId: String? = nil
    ) -> AsyncThrowingStream<TurnUpdate, Error> {
        stream(text, context: context, conversationId: conversationId, attachments: [])
    }

    /// `stream(_:context:conversationId:)` with files the user sent, from `upload(_:)`.
    public nonisolated func stream(
        _ text: String, context: PageContext, conversationId: String?, attachments: [String]
    ) -> AsyncThrowingStream<TurnUpdate, Error> {
        stream(text, context: context, conversationId: conversationId, attachments: attachments, confirm: nil)
    }

    /// `stream(_:context:conversationId:attachments:)` with a confirmation
    /// prompt for this turn only, used in place of `setConfirmationPrompt`'s.
    /// The registry's own `confirm` still comes first.
    public nonisolated func stream(
        _ text: String, context: PageContext, conversationId: String?, attachments: [String],
        confirm: (@Sendable (ConfirmationRequest) async -> Bool)?
    ) -> AsyncThrowingStream<TurnUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.$turnConfirmation.withValue(confirm ?? Self.turnConfirmation) {
                        try await self.runStreamed(text, context: context, conversationId: conversationId, attachments: attachments) {
                            continuation.yield($0)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStreamed(
        _ text: String, context: PageContext, conversationId: String?, attachments: [String], emit: @Sendable (TurnUpdate) -> Void
    ) async throws {
        struct Start: Encodable {
            var conversationId: String?; var text: String; var context: PageContext; var attachments: [String]?; var timezone: String
        }
        struct Results: Encodable { var results: [DeviceResult] }
        // Shared across requests: a new step after a device round trip still
        // has to clear what the previous step showed.
        var reply = ""
        var response = try await streamTurn(
            "turns",
            body: Start(
                conversationId: conversationId, text: text, context: context, attachments: attachments.isEmpty ? nil : attachments,
                timezone: timeZone().identifier),
            reply: &reply, emit: emit)
        var rounds = 0
        while case .requiresAction(let pending) = response {
            rounds += 1
            guard rounds <= Self.maxDeviceRounds else { throw AgentError.turnDidNotFinish(rounds: rounds - 1) }
            emit(.runningTools(pending.calls))
            var results: [DeviceResult] = []
            for call in pending.calls {
                try Task.checkCancellation()
                results.append(await runCall(call))
            }
            response = try await streamTurn(
                "turns/\(Self.segment(pending.turnId))/results", body: Results(results: results), reply: &reply, emit: emit)
        }
        guard case .completed(let done) = response else { throw AgentError.decoding("Turn ended without completing.") }
        emit(.completed(done))
    }

    /// Posts to a turn endpoint asking for server-sent events and returns the
    /// turn result, forwarding text as it arrives.
    private func streamTurn<B: Encodable>(
        _ path: String, body: B, reply: inout String, emit: @Sendable (TurnUpdate) -> Void
    ) async throws -> TurnResponse {
        let request = try await makeRequest("POST", path, body: body, authorized: true, accept: "text/event-stream")
        let (bytes, response) = try await urlSession.bytes(for: request)

        let isEventStream = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?
            .contains("text/event-stream") ?? false
        guard isEventStream else {
            // An error status, or a server that doesn't stream: read it whole.
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            try await check(response, data, authorized: true)
            return try decode(TurnResponse.self, data, "POST", path)
        }

        var parser = ServerSentEvents()
        for try await byte in bytes {
            guard let event = parser.feed(byte) else { continue }
            switch event.name {
            case "step":
                if !reply.isEmpty {
                    reply = ""
                    emit(.text(""))
                }
            case "text":
                if let delta = try? JSONDecoder().decode(TextDelta.self, from: Data(event.data.utf8)) {
                    reply += delta.delta
                    emit(.text(reply))
                }
            case "part":
                if let part = try? JSONDecoder().decode(TurnPart.self, from: Data(event.data.utf8)) { emit(.part(part)) }
            case "turn":
                return try decode(TurnResponse.self, Data(event.data.utf8), "POST", path)
            case "error":
                let err = try? JSONDecoder().decode(ErrorBody.self, from: Data(event.data.utf8))
                try await fail(AgentError(status: 200, code: err?.code, message: err?.error ?? "The assistant couldn't answer."))
            default:
                continue
            }
        }
        throw AgentError.unavailable("The connection ended before the reply finished.")
    }
}

private struct TextDelta: Decodable { var delta: String }

/// A minimal text/event-stream parser, fed one byte at a time. It keeps blank
/// lines, which `AsyncLineSequence` drops, because they end each event.
struct ServerSentEvents {
    struct Event: Equatable {
        var name: String
        var data: String
    }

    private var line: [UInt8] = []
    private var name = ""
    private var data: [String] = []

    mutating func feed(_ byte: UInt8) -> Event? {
        guard byte == UInt8(ascii: "\n") else {
            line.append(byte)
            return nil
        }
        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)

        if text.isEmpty {
            defer { name = ""; data = [] }
            return data.isEmpty ? nil : Event(name: name.isEmpty ? "message" : name, data: data.joined(separator: "\n"))
        }
        if text.hasPrefix(":") { return nil }
        let (field, value) = Self.split(text)
        switch field {
        case "event": name = value
        case "data": data.append(value)
        default: break
        }
        return nil
    }

    private static func split(_ line: String) -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        var value = line[line.index(after: colon)...]
        if value.first == " " { value = value.dropFirst() }
        return (String(line[..<colon]), String(value))
    }
}
