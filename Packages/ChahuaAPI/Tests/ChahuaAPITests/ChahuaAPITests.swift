import Foundation
import XCTest
@testable import ChahuaAPI

final class ChahuaAPITests: XCTestCase {
    override func tearDown() { StubURLProtocol.handler = nil; super.tearDown() }

    func testAuthenticateInstallsValidatedTokenForLaterRequests() async throws {
        let requests = RequestRecorder()
        StubURLProtocol.handler = { request in
            requests.append(request)
            guard request.url?.path == "/users/me" else { return (404, "") }
            return (200, #"{"uid":1,"username":"fixture","gender":0,"stickerPackOrder":[],"permissions":[],"avatarUrl":null}"#)
        }
        let client = ChahuaClient(
            configuration: ChahuaConfiguration(baseURL: URL(string: "https://api.example")!),
            session: testSession()
        )

        _ = try await client.authenticate(candidateJWT: "candidate")
        _ = try await client.me()

        let recorded = requests.values
        XCTAssertEqual(recorded.map { $0.url?.path }, ["/users/me", "/users/me"])
        XCTAssertTrue(recorded.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer candidate" })
    }

    func testAuthenticateRejectsInvalidCandidateWithoutInstallingIt() async throws {
        StubURLProtocol.handler = { _ in (401, "") }
        let client = ChahuaClient(
            configuration: ChahuaConfiguration(baseURL: URL(string: "https://api.example")!),
            session: testSession()
        )

        do { _ = try await client.authenticate(candidateJWT: "candidate"); XCTFail("Expected invalid token") }
        catch APIError.invalidToken { }
    }

    func testListChatsRequestsActiveChatsAndDecodesResponse() async throws {
        let requests = RequestRecorder()
        StubURLProtocol.handler = { request in
            requests.append(request)
            return (200, #"""
            {
              "chats": [
                {
                  "id": "10",
                  "name": "Engineering",
                  "avatar": "https://cdn.example/group.png",
                  "lastMessageAt": "2026-08-31T12:34:56Z",
                  "unreadCount": 3,
                  "lastReadMessageId": "99",
                  "lastMessage": {
                    "id": "100",
                    "clientGeneratedId": "client-100",
                    "createdAt": "2026-08-31T12:34:56Z",
                    "sender": {"uid": 1, "gender": 0, "name": "Ada", "avatarUrl": null, "userGroup": null},
                    "messageType": "text",
                    "attachments": [],
                    "mentions": [],
                    "isDeleted": false,
                    "message": "Ship it",
                    "sticker": null
                  },
                  "mutedUntil": null,
                  "archived": false,
                  "kind": "group",
                  "peer": null
                },
                {
                  "id": "11",
                  "name": null,
                  "avatar": null,
                  "lastMessageAt": null,
                  "unreadCount": 0,
                  "lastReadMessageId": null,
                  "lastMessage": null,
                  "mutedUntil": null,
                  "archived": false,
                  "kind": "dm",
                  "peer": {
                    "uid": 2,
                    "username": "Grace",
                    "avatarUrl": "https://cdn.example/grace.png",
                    "gender": 1,
                    "userGroup": {"groupId": 7, "name": "Staff", "chatGroupColor": "#111111", "chatGroupColorDark": "#eeeeee"}
                  }
                }
              ],
              "nextCursor": "11"
            }
            """#)
        }
        let client = ChahuaClient(
            configuration: ChahuaConfiguration(baseURL: URL(string: "https://api.example")!),
            token: "candidate",
            session: testSession()
        )

        let response = try await client.listChats(query: ListChatsQuery(archived: false))

        XCTAssertEqual(response.chats.map(\.id), ["10", "11"])
        XCTAssertEqual(response.chats[0].kind, .group)
        XCTAssertEqual(response.chats[0].lastMessage?.message, "Ship it")
        XCTAssertEqual(response.chats[1].kind, .dm)
        XCTAssertEqual(response.chats[1].peer?.username, "Grace")
        XCTAssertEqual(response.chats[1].peer?.userGroup?.groupId, 7)
        XCTAssertEqual(response.nextCursor, "11")

        XCTAssertEqual(requests.values.count, 1)
        let request = try XCTUnwrap(requests.values.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/chats")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "archived", value: "false"),
        ])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer candidate")
    }

    func testReactionPathsPreserveEmojiAndReservedCharactersAsSingleSegments() async throws {
        let requests = RequestRecorder()
        StubURLProtocol.handler = { request in
            requests.append(request)
            return (204, "")
        }
        let client = ChahuaClient(
            configuration: ChahuaConfiguration(baseURL: URL(string: "https://api.example/base%20path/")!),
            token: "candidate",
            session: testSession()
        )
        let emojis = ["👩🏽‍💻", "#️⃣", "/", "%2F"]
        for emoji in emojis {
            try await client.putReaction(chatID: "chat/one", messageID: "message#two", emoji: emoji)
            try await client.deleteReaction(chatID: "chat/one", messageID: "message#two", emoji: emoji)
        }

        XCTAssertEqual(requests.values.count, emojis.count * 2)
        for (index, request) in requests.values.enumerated() {
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let segments = components.percentEncodedPath.split(separator: "/").map(String.init)
            XCTAssertEqual(segments.count, 7)
            XCTAssertEqual(Array(segments.prefix(6)), ["base%20path", "chats", "chat%2Fone", "messages", "message%23two", "reactions"])
            XCTAssertEqual(segments.last?.removingPercentEncoding, emojis[index / 2])
            XCTAssertNil(components.query)
            XCTAssertNil(components.fragment)
            XCTAssertEqual(request.httpMethod, index.isMultiple(of: 2) ? "PUT" : "DELETE")
            XCTAssertNil(request.httpBody)
        }
    }

    private func testSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var values: [URLRequest] { lock.withLock { storage } }
    func append(_ request: URLRequest) { lock.withLock { storage.append(request) } }
}

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { fatalError("Missing handler") }
        let result = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
