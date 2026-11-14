import Foundation

/// Draft previews have no HTTP endpoint. Keep this bounded RPC exchange separate
/// from the legacy realtime event consumer, which cannot decode JSON-RPC replies.
/// The socket owns no watches, stays inactive, and closes on completion/cancellation.
enum DraftLinkPreviewRPC {
    static func fetch(
        socket: URLSessionWebSocketTask, token: String, appVersion: String?,
        chatID: String, urls: [String], timeout: TimeInterval
    ) async throws -> [MessageLinkPreview] {
        defer { socket.cancel(with: .goingAway, reason: nil) }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: [MessageLinkPreview].self) { group in
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    socket.cancel(with: .goingAway, reason: nil)
                    throw APIError.transport(URLError(.timedOut))
                }
                group.addTask {
                    socket.resume()
                    try await send(
                        Request(
                            id: 1, method: "session.open",
                            params: OpenParams(token: token, appVersion: appVersion)),
                        to: socket)
                    let opened: OpenResult = try await receive(id: 1, from: socket)
                    guard opened.protocolVersion == 1, opened.authenticated else {
                        throw APIError.invalidToken
                    }
                    try await send(
                        Request<AppState>(
                            id: nil, method: "session.setAppState", params: AppState()),
                        to: socket)
                    try await send(
                        Request(
                            id: 2, method: "messages.previewLinks",
                            params: PreviewParams(chatId: chatID, urls: urls)),
                        to: socket)
                    return try await receive(id: 2, from: socket)
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw APIError.unexpectedResponse }
                return result
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private static func send(_ request: some Encodable, to socket: URLSessionWebSocketTask)
        async throws
    {
        try Task.checkCancellation()
        let data = try JSONCoding.encoder.encode(request)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private static func receive<Result: Decodable>(id: Int, from socket: URLSessionWebSocketTask)
        async throws -> Result
    {
        while true {
            try Task.checkCancellation()
            let data: Data
            switch try await socket.receive() {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: throw APIError.unexpectedResponse
            }
            let header = try JSONCoding.decoder.decode(Header.self, from: data)
            guard header.jsonrpc == "2.0" else { throw APIError.unexpectedResponse }
            // Session notifications can precede the correlated response.
            guard header.id == id else {
                guard header.id == nil, header.method != nil else {
                    throw APIError.unexpectedResponse
                }
                continue
            }
            if let error = header.error {
                switch error.code {
                case 1001: throw APIError.invalidToken
                case 1003: throw APIError.http(status: 403, body: data)
                case 1503, 1429: throw APIError.unavailable
                default: throw APIError.unexpectedResponse
                }
            }
            return try JSONCoding.decoder.decode(Response<Result>.self, from: data).result
        }
    }

    private struct Request<Params: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: Int?
        let method: String
        let params: Params
    }
    private struct OpenParams: Encodable {
        let protocolVersion = 1
        let token: String
        let appVersion: String?
    }
    private struct OpenResult: Decodable {
        let protocolVersion: Int
        let authenticated: Bool
    }
    private struct AppState: Encodable { let state = "inactive" }
    private struct PreviewParams: Encodable {
        let chatId: String
        let urls: [String]
    }
    private struct Header: Decodable {
        let jsonrpc: String
        let id: Int?
        let method: String?
        let error: Failure?
    }
    private struct Failure: Decodable { let code: Int }
    private struct Response<Result: Decodable>: Decodable { let result: Result }
}
