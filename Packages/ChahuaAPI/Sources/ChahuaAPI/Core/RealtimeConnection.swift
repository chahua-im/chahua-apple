import Foundation

public enum RealtimeAppState: String, Encodable, Sendable {
    case active, inactive
}

public protocol RealtimeConnection: Sendable {
    func receive() async throws -> RealtimeServerEvent
    func sendPing(state: RealtimeAppState) async throws
    func sendAppState(_ state: RealtimeAppState) async throws
    /// Replaces this socket's watch (up to 100 users and 4 groups).
    /// Empty arrays unsubscribe; callers serialize updates and correlate snapshots by request ID.
    func sendWatchPresence(requestID: UInt64, userIDs: [Int32], chatIDs: [String]) async throws
    /// Replaces unread summary selectors; empty views and `false` cancel the watch.
    func sendWatchConversationUnread(
        requestID: UInt32, views: [ConversationView], appBadge: Bool
    ) async throws
    /// Replaces the explicit conversation state scope; an empty scope cancels the watch.
    func sendWatchConversationStates(
        requestID: UInt32, conversations: [ConversationRef]
    ) async throws
    func close() async
}

public protocol RealtimeConnectionProviding: Sendable {
    /// Opens and sends authentication only. The caller must publish its current
    /// app state after this returns, then schedule stateful application pings.
    func openRealtimeConnection() async throws -> any RealtimeConnection
}

/// A single consumer receives frames; sends may run alongside a suspended receive.
/// Callers serialize presence frames to retain their lifecycle ordering.
actor URLSessionRealtimeConnection: RealtimeConnection {
    private let socket: URLSessionWebSocketTask
    private var isClosed = false

    init(socket: URLSessionWebSocketTask) {
        self.socket = socket
    }

    func authenticate(ticket: String) async throws {
        try await send(AuthFrame(ticket: ticket))
    }

    func receive() async throws -> RealtimeServerEvent {
        guard !isClosed else { throw CancellationError() }
        do {
            let frame = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await socket.receive()
            } onCancel: { [socket] in
                socket.cancel(with: .goingAway, reason: nil)
            }
            try Task.checkCancellation()
            guard !isClosed else { throw CancellationError() }
            let data: Data
            switch frame {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes):
                guard String(data: bytes, encoding: .utf8) != nil else {
                    throw APIError.unexpectedResponse
                }
                data = bytes
            @unknown default: throw APIError.unexpectedResponse
            }
            // Known malformed payloads fail the connection. Unknown names are nonfatal.
            return try JSONCoding.decoder.decode(RealtimeServerEvent.self, from: data)
        } catch {
            close()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func sendPing(state: RealtimeAppState) async throws {
        try await send(StateFrame(type: "ping", state: state))
    }

    func sendAppState(_ state: RealtimeAppState) async throws {
        try await send(StateFrame(type: "appState", state: state))
    }

    func sendWatchPresence(requestID: UInt64, userIDs: [Int32], chatIDs: [String]) async throws {
        try await send(
            WatchPresenceFrame(requestId: requestID, userIds: userIDs, chatIds: chatIDs))
    }

    func sendWatchConversationUnread(
        requestID: UInt32, views: [ConversationView], appBadge: Bool
    ) async throws {
        try await send(
            WatchConversationUnreadFrame(requestId: requestID, views: views, appBadge: appBadge))
    }

    func sendWatchConversationStates(
        requestID: UInt32, conversations: [ConversationRef]
    ) async throws {
        try await send(
            WatchConversationStatesFrame(requestId: requestID, conversations: conversations))
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        socket.cancel(with: .goingAway, reason: nil)
    }

    private func send(_ frame: some Encodable) async throws {
        guard !isClosed else { throw CancellationError() }
        let text = String(decoding: try JSONCoding.encoder.encode(frame), as: UTF8.self)
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await socket.send(.string(text))
            } onCancel: { [socket] in
                socket.cancel(with: .goingAway, reason: nil)
            }
            try Task.checkCancellation()
            guard !isClosed else { throw CancellationError() }
        } catch {
            close()
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private struct AuthFrame: Encodable {
        let type = "auth"
        let ticket: String
    }

    private struct StateFrame: Encodable {
        let type: String
        let state: RealtimeAppState
    }

    private struct WatchPresenceFrame: Encodable {
        let type = "watchPresence"
        let requestId: UInt64
        let userIds: [Int32]
        let chatIds: [String]
    }

    private struct WatchConversationUnreadFrame: Encodable {
        let type = "watchConversationUnread"
        let requestId: UInt32
        let views: [ConversationView]
        let appBadge: Bool
    }

    private struct WatchConversationStatesFrame: Encodable {
        let type = "watchConversationStates"
        let requestId: UInt32
        let conversations: [ConversationRef]
    }
}
