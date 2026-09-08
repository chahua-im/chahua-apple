import Foundation

public enum RealtimeAppState: String, Encodable, Sendable {
    case active, inactive
}

public protocol RealtimeConnection: Sendable {
    func receive() async throws -> RealtimeServerEvent
    func sendPing(state: RealtimeAppState) async throws
    func sendAppState(_ state: RealtimeAppState) async throws
    func close() async
}

public protocol RealtimeConnectionProviding: Sendable {
    func openRealtimeConnection() async throws -> any RealtimeConnection
}

/// A single consumer receives frames; sends may run alongside a suspended receive.
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
            case let .string(text): data = Data(text.utf8)
            case let .data(bytes):
                guard String(data: bytes, encoding: .utf8) != nil else { throw APIError.unexpectedResponse }
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
}
