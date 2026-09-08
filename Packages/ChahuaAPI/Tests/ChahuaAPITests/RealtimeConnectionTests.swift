import CryptoKit
import Foundation
@preconcurrency import Network
import XCTest
@testable import ChahuaAPI

final class RealtimeConnectionTests: XCTestCase {
    func testOpeningUsesInstalledJWTAndPreservesAPIPrefixWithoutTicketOrRefresh() async throws {
        let server = try await RealtimeLoopbackServer.start()
        do {
            let baseURL = await server.baseURL
            let client = ChahuaClient(configuration: ChahuaConfiguration(
                baseURL: URL(string: baseURL.absoluteString + "api/?inherited=secret#fragment")!,
                userAgent: "RealtimeTests"
            ), token: "installed")
            let connection = try await client.openRealtimeConnection()
            guard case .pong = try await connection.receive() else { return XCTFail("Expected first pong") }
            let requests = await server.requests
            XCTAssertEqual(requests.map(\.path), ["/api/ws"])
            XCTAssertEqual(requests.first?.headers["user-agent"], "RealtimeTests")
            XCTAssertNil(requests.first?.headers["authorization"])
            let frames = await server.authentications
            XCTAssertEqual(frames, ["installed"])
            await connection.close()
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    func testRefreshAndReconnectShareNewCredentialWithoutAdditionalRefresh() async throws {
        let server = try await RealtimeLoopbackServer.start()
        do {
            let client = ChahuaClient(configuration: ChahuaConfiguration(baseURL: await server.baseURL), token: "expired")
            _ = try await client.me()
            let first = try await client.openRealtimeConnection()
            guard case .pong = try await first.receive() else { return XCTFail("Expected pong") }
            await first.close()
            let second = try await client.openRealtimeConnection()
            guard case .pong = try await second.receive() else { return XCTFail("Expected pong") }
            await second.close()
            let requests = await server.requests
            XCTAssertEqual(requests.map(\.path), ["/users/me", "/auth/refresh", "/users/me", "/ws", "/ws"])
            XCTAssertEqual(requests[2].headers["authorization"], "Bearer refreshed")
            let auth = await server.authentications
            XCTAssertEqual(auth, ["refreshed", "refreshed"])
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    func testOldHeldRefreshCannotOverwriteNewAuthenticatedAccount() async throws {
        let server = try await RealtimeLoopbackServer.start()
        do {
            await server.holdRefresh()
            let client = ChahuaClient(configuration: ChahuaConfiguration(baseURL: await server.baseURL), token: "expired")
            let oldRequest = Task { try await client.me() }
            await server.waitForHeldRefresh()
            _ = try await client.authenticate(candidateJWT: "account-B")
            await server.releaseRefresh()
            do {
                _ = try await oldRequest.value
                XCTFail("The replaced account must not return an HTTP result")
            } catch is CancellationError { }
            _ = try await client.me()
            let connection = try await client.openRealtimeConnection()
            guard case .pong = try await connection.receive() else { return XCTFail("Expected pong") }
            let requests = await server.requests
            XCTAssertEqual(requests.filter { $0.path == "/auth/refresh" }.count, 1)
            XCTAssertEqual(requests.last { $0.path == "/users/me" }?.headers["authorization"], "Bearer account-B")
            let auth = await server.authentications
            XCTAssertEqual(auth, ["account-B"])
            await connection.close()
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    func testUnknownAndUnhandledFramesDoNotInterruptLaterEventsButMalformedKnownFrameFails() async throws {
        let server = try await RealtimeLoopbackServer.start()
        do {
            await server.setFrames([
                .string(#"{"type":"friendshipRemoved","payload":{"actorUid":8}}"#),
                .data(Data(#"{"type":"futureFeature","payload":false}"#.utf8)),
                .string(#"{"type":"message","payload":{"id":"9007199254740993","chatId":"42","clientGeneratedId":"c","messageType":"text","sender":{"uid":1,"gender":0},"createdAt":"2026-09-01T00:00:00Z","isEdited":false,"isDeleted":false,"hasAttachments":false,"attachments":[],"reactions":[],"message":"received"}}"#),
                .string(#"{"type":"reactionUpdated","payload":{}}"#),
            ])
            let client = ChahuaClient(configuration: ChahuaConfiguration(baseURL: await server.baseURL), token: "installed")
            let connection = try await client.openRealtimeConnection()
            guard case .pong = try await connection.receive() else { return XCTFail("Expected pong") }
            guard case let .friendshipRemoved(payload) = try await connection.receive() else { return XCTFail("Expected typed no-op") }
            XCTAssertEqual(payload.actorUid, 8)
            guard case let .unknown(type) = try await connection.receive() else { return XCTFail("Expected future event") }
            XCTAssertEqual(type, "futureFeature")
            guard case let .message(message) = try await connection.receive() else { return XCTFail("Expected message") }
            XCTAssertEqual(message.message, "received")
            do {
                _ = try await connection.receive()
                XCTFail("Invalid known payload must fail")
            } catch is DecodingError { }
            do {
                _ = try await connection.receive()
                XCTFail("Protocol failure must close the connection")
            } catch is CancellationError { }
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    func testNonJSONBinaryFrameFailsConnection() async throws {
        let server = try await RealtimeLoopbackServer.start()
        do {
            await server.setFrames([.data(Data([0xff, 0xfe]))])
            let client = ChahuaClient(configuration: ChahuaConfiguration(baseURL: await server.baseURL), token: "installed")
            let connection = try await client.openRealtimeConnection()
            guard case .pong = try await connection.receive() else { return XCTFail("Expected pong") }
            do {
                _ = try await connection.receive()
                XCTFail("Non-UTF8 binary frame must fail")
            } catch APIError.unexpectedResponse { }
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    func testCancellingReceiveUnblocksAndClosesConnection() async throws {
        let server = try await RealtimeLoopbackServer.start()
        do {
            let client = ChahuaClient(configuration: ChahuaConfiguration(baseURL: await server.baseURL), token: "installed")
            let connection = try await client.openRealtimeConnection()
            guard case .pong = try await connection.receive() else { return XCTFail("Expected pong") }
            let pending = Task { try await connection.receive() }
            pending.cancel()
            do {
                _ = try await pending.value
                XCTFail("A cancelled receive must unblock")
            } catch is CancellationError { }
            do {
                _ = try await connection.receive()
                XCTFail("Cancellation must close the underlying socket")
            } catch is CancellationError { }
            await connection.close()
            await connection.close()
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }
}

/// A real, loopback-only HTTP/WebSocket peer. It has no ticket endpoint.
private actor RealtimeLoopbackServer {
    struct Request: Sendable {
        let path: String
        let headers: [String: String]
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "ChahuaAPI.RealtimeLoopback")
    private var connections: [NWConnection] = []
    private(set) var requests: [Request] = []
    private(set) var authentications: [String] = []
    private var frames: [URLSessionWebSocketTask.Message] = []
    private var holdsRefresh = false
    private var heldRefresh: CheckedContinuation<Void, Never>?
    private var refreshWaiter: CheckedContinuation<Void, Never>?

    private init(listener: NWListener) { self.listener = listener }

    static func start() async throws -> RealtimeLoopbackServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let server = RealtimeLoopbackServer(listener: listener)
        listener.newConnectionHandler = { connection in
            Task { await server.accept(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "ChahuaAPI.RealtimeListener"))
        }
        return server
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")! }

    func setFrames(_ frames: [URLSessionWebSocketTask.Message]) { self.frames = frames }
    func holdRefresh() { holdsRefresh = true }
    func waitForHeldRefresh() async {
        if heldRefresh != nil { return }
        await withCheckedContinuation { refreshWaiter = $0 }
    }
    func releaseRefresh() {
        holdsRefresh = false
        heldRefresh?.resume()
        heldRefresh = nil
    }
    func stop() {
        releaseRefresh()
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) async {
        connections.append(connection)
        connection.start(queue: queue)
        let wire = LoopbackWire(connection: connection)
        do {
            let request = try await wire.readRequest()
            requests.append(request)
            // The nested backend upgrade route is /ws, not /ws/.
            if request.path == "/ws" || request.path == "/api/ws" {
                guard let key = request.headers["sec-websocket-key"] else { throw APIError.unexpectedResponse }
                let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
                let accept = Data(digest).base64EncodedString()
                try await wire.send(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8))
                let (authOpcode, authData) = try await wire.readFrame()
                let auth = try JSONDecoder().decode(ClientFrame.self, from: authData)
                guard authOpcode == 1, auth.type == "auth", let ticket = auth.ticket else { throw APIError.unexpectedResponse }
                authentications.append(ticket)
                let (pingOpcode, pingData) = try await wire.readFrame()
                let ping = try JSONDecoder().decode(ClientFrame.self, from: pingData)
                guard pingOpcode == 1, ping.type == "ping", ping.state == "active" else { throw APIError.unexpectedResponse }
                try await wire.sendFrame(opcode: 1, data: Data(#"{"type":"pong"}"#.utf8))
                for frame in frames {
                    switch frame {
                    case let .string(text): try await wire.sendFrame(opcode: 1, data: Data(text.utf8))
                    case let .data(data): try await wire.sendFrame(opcode: 2, data: data)
                    @unknown default: throw APIError.unexpectedResponse
                    }
                }
                while true {
                    let (opcode, _) = try await wire.readFrame()
                    if opcode == 8 { break }
                }
            } else if request.path == "/auth/refresh" {
                if holdsRefresh {
                    await withCheckedContinuation { continuation in
                        heldRefresh = continuation
                        refreshWaiter?.resume()
                        refreshWaiter = nil
                    }
                }
                try await wire.respond(status: 200, body: #"{"token":"refreshed"}"#)
            } else if request.path == "/users/me" {
                if request.headers["authorization"] == "Bearer expired" {
                    try await wire.respond(status: 401, body: "")
                } else {
                    try await wire.respond(status: 200, body: #"{"uid":1,"username":"fixture","gender":0,"stickerPackOrder":[],"permissions":[]}"#)
                }
            } else {
                try await wire.respond(status: 404, body: "")
            }
        } catch {
            // Cancellation, closed clients and malformed client frames terminate only this peer.
        }
        connection.cancel()
    }

    private struct ClientFrame: Decodable {
        let type: String
        let ticket: String?
        let state: String?
    }
}

/// Each wire belongs to exactly one server request task.
private final class LoopbackWire: @unchecked Sendable {
    private let connection: NWConnection
    private var buffer = Data()
    private var offset = 0

    init(connection: NWConnection) { self.connection = connection }

    private func read(_ count: Int) async throws -> Data {
        while buffer.count - offset < count {
            let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if complete { continuation.resume(throwing: CancellationError()) }
                    else { continuation.resume(throwing: APIError.unexpectedResponse) }
                }
            }
            if offset > 0 {
                buffer.removeFirst(offset)
                offset = 0
            }
            buffer.append(chunk)
        }
        let start = buffer.startIndex + offset
        let result = buffer.subdata(in: start ..< start + count)
        offset += count
        return result
    }

    func readRequest() async throws -> RealtimeLoopbackServer.Request {
        var header = Data()
        while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard header.count < 16384 else { throw APIError.unexpectedResponse }
            header.append(try await read(1))
        }
        let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
        guard let path = lines.first?.split(separator: " ").dropFirst().first else { throw APIError.unexpectedResponse }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return .init(path: String(path), headers: headers)
    }

    func readFrame() async throws -> (UInt8, Data) {
        let header = try await read(2)
        let opcode = header[0] & 0x0f
        let masked = header[1] & 0x80 != 0
        var length = Int(header[1] & 0x7f)
        if length == 126 {
            let bytes = try await read(2)
            length = Int(bytes[0]) << 8 | Int(bytes[1])
        }
        guard length < 65536, length != 127 else { throw APIError.unexpectedResponse }
        let mask = masked ? try await read(4) : Data()
        var data = try await read(length)
        if masked { for index in data.indices { data[index] ^= mask[index % 4] } }
        return (opcode, data)
    }

    func sendFrame(opcode: UInt8, data: Data) async throws {
        var frame = Data([0x80 | opcode])
        if data.count < 126 { frame.append(UInt8(data.count)) }
        else { frame.append(contentsOf: [126, UInt8(data.count >> 8), UInt8(data.count & 0xff)]) }
        frame.append(data)
        try await send(frame)
    }

    func respond(status: Int, body: String) async throws {
        try await send(Data("HTTP/1.1 \(status) Response\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8))
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}
