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

    func testListThreadsDecodesSubscriptionsAndPreservesPaginationCursor() async throws {
        let requests = RequestRecorder()
        let cursor = "2026-09-01T01:02:03.456+00:00"
        StubURLProtocol.handler = { request in
            requests.append(request)
            // Axum decodes query strings as form data: a literal '+' becomes a space.
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
            let query = components.queryItems ?? []
            if let before = query.first(where: { $0.name == "before" }) {
                guard before.value == cursor else { return (400, "Invalid datetime cursor") }
                return (200, #"{"threads":[],"nextCursor":null}"#)
            }
            return (200, #"""
            {
              "threads": [{
                "chatId": "9007199254740993",
                "chatName": "Engineering",
                "chatAvatar": null,
                "threadRootMessage": {
                  "id": "9007199254740994",
                  "clientGeneratedId": "root-attempt",
                  "createdAt": "2026-09-01T00:00:00Z",
                  "sender": {"uid": 1, "gender": 0, "name": "Ada"},
                  "messageType": "text",
                  "message": "Discuss the release",
                  "attachments": [],
                  "mentions": [],
                  "isDeleted": false
                },
                "participants": [{"uid": 2, "gender": 1, "name": null, "avatarUrl": null}],
                "lastReply": {
                  "id": "9007199254740995",
                  "clientGeneratedId": "reply-attempt",
                  "createdAt": "2026-09-01T01:02:03.456Z",
                  "sender": {"uid": 2, "gender": 1, "name": null},
                  "messageType": "text",
                  "message": null,
                  "attachments": [],
                  "mentions": [],
                  "isDeleted": true
                },
                "replyCount": 4,
                "lastReplyAt": "2026-09-01T01:02:03.456Z",
                "unreadCount": 2,
                "lastReadMessageId": null,
                "subscribedAt": "2026-09-01T00:00:00Z",
                "archived": false
              }],
              "nextCursor": "2026-09-01T01:02:03.456+00:00"
            }
            """#)
        }
        let client: any ChahuaAPIClient = ChahuaClient(
            configuration: ChahuaConfiguration(baseURL: URL(string: "https://api.example")!),
            token: "candidate",
            session: testSession()
        )

        let first = try await client.listThreads(query: ListThreadsQuery(limit: 20, archived: false))
        let thread = try XCTUnwrap(first.threads.first)
        XCTAssertEqual(thread.chatId, "9007199254740993")
        XCTAssertEqual(thread.threadRootMessage.id, "9007199254740994")
        XCTAssertEqual(thread.threadRootMessage.message, "Discuss the release")
        XCTAssertEqual(thread.participants.first?.uid, 2)
        XCTAssertNil(thread.participants.first?.name)
        XCTAssertNil(thread.chatAvatar)
        XCTAssertEqual(thread.lastReply?.id, "9007199254740995")
        XCTAssertEqual(thread.lastReply?.isDeleted, true)
        XCTAssertNil(thread.lastReply?.message)
        XCTAssertEqual(thread.replyCount, 4)
        XCTAssertEqual(thread.unreadCount, 2)
        XCTAssertEqual(thread.lastReplyAt.timeIntervalSince(thread.subscribedAt), 3723.456, accuracy: 0.0001)
        XCTAssertEqual(first.nextCursor, cursor)

        let second = try await client.listThreads(query: ListThreadsQuery(limit: 20, before: first.nextCursor, archived: false))
        XCTAssertEqual(second.threads, [])
        XCTAssertNil(second.nextCursor)
        XCTAssertEqual(requests.values.count, 2)
        for (index, request) in requests.values.enumerated() {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/threads")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer candidate")
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            var expected = [URLQueryItem(name: "limit", value: "20")]
            if index == 1 { expected.append(URLQueryItem(name: "before", value: cursor)) }
            expected.append(URLQueryItem(name: "archived", value: "false"))
            XCTAssertEqual(query, expected)
        }
    }

    func testReadReceiptsUseDistinctChatAndThreadScopesWithOpaqueMessageIDs() async throws {
        StubURLProtocol.handler = { request in
            guard request.httpMethod == "POST",
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer candidate",
                  let body = try? JSONSerialization.jsonObject(with: requestBody(request)) as? [String: String],
                  body["messageId"] == "9007199254740995" else { return (400, "Invalid read request") }
            switch request.url?.path {
            case "/chats/chat/read":
                return (200, #"{"lastReadMessageId":"9007199254740995","unreadCount":3}"#)
            case "/chats/chat/threads/root/read":
                return (200, #"{"lastReadMessageId":"9007199254740995","unreadCount":0}"#)
            default:
                return (404, "Wrong read scope")
            }
        }
        let client = ChahuaClient(
            configuration: .init(baseURL: URL(string: "https://api.example")!),
            token: "candidate", session: testSession())
        let chat = try await client.markChatRead(chatID: "chat", messageID: "9007199254740995")
        let thread = try await client.markThreadRead(chatID: "chat", threadID: "root", messageID: "9007199254740995")
        XCTAssertEqual(chat, .init(lastReadMessageId: "9007199254740995", unreadCount: 3))
        XCTAssertEqual(thread, .init(lastReadMessageId: "9007199254740995", unreadCount: 0))
    }

    func testMalformedThreadReportsNestedFieldWithoutLeakingInvalidValue() async throws {
        StubURLProtocol.handler = { _ in
            (200, #"""
            {"threads":[{"chatId":"10","chatName":"private chat",
              "threadRootMessage":{"id":"101","clientGeneratedId":"root",
                "createdAt":"2026-09-01T00:00:00Z",
                "sender":{"uid":1,"gender":0},
                "messageType":{"private-invalid-value":1},"message":"private message",
                "attachments":[],"mentions":[],"isDeleted":false},
              "participants":[],"replyCount":0,"lastReplyAt":"2026-09-01T00:00:00Z",
              "unreadCount":0,"subscribedAt":"2026-09-01T00:00:00Z","archived":false}]}
            """#)
        }
        let client = ChahuaClient(
            configuration: ChahuaConfiguration(baseURL: URL(string: "https://api.example")!),
            token: "private-token", session: testSession())
        do {
            _ = try await client.listThreads(query: .init())
            XCTFail("Invalid message type shape must remain a decoding failure")
        } catch APIError.decoding(let status, let description) {
            XCTAssertEqual(status, 200)
            XCTAssertTrue(description.contains("$.threads[0].threadRootMessage.messageType"))
            XCTAssertFalse(description.contains("private"))
        }
    }

    func testThreadTimelineUsesCamelCaseThreadFilterWithoutChangingParentRoute() async throws {
        let requests = RequestRecorder()
        StubURLProtocol.handler = { request in
            requests.append(request)
            return (200, #"{"messages":[],"olderCursor":null,"newerCursor":null}"#)
        }
        let client = ChahuaClient(
            configuration: ChahuaConfiguration(baseURL: URL(string: "https://api.example")!),
            session: testSession()
        )

        _ = try await client.listMessages(chatID: "10", query: ListMessagesQuery(before: "90", max: 30, threadID: "80"))
        _ = try await client.listMessages(chatID: "10")

        XCTAssertEqual(requests.values.map { $0.url?.path }, ["/chats/10/messages", "/chats/10/messages"])
        let threadURL = try XCTUnwrap(requests.values.first?.url)
        XCTAssertEqual(URLComponents(url: threadURL, resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "before", value: "90"),
            URLQueryItem(name: "max", value: "30"),
            URLQueryItem(name: "threadId", value: "80"),
        ])
        XCTAssertNil(requests.values.last?.url?.query)
    }

    func testSendThreadMessageUsesThreadRouteAndPreservesMessageBody() async throws {
        let requests = RequestRecorder()
        StubURLProtocol.handler = { request in
            requests.append(request)
            let body = try? JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            XCTAssertEqual(body?["messageType"] as? String, "text")
            XCTAssertEqual(body?["message"] as? String, "Thread reply")
            XCTAssertEqual(body?["clientGeneratedId"] as? String, "reply-attempt")
            XCTAssertEqual(body?["replyToId"] as? String, "previous-reply")
            XCTAssertNil(body?["attachmentIds"])
            return (200, #"""
            {
              "id": "server-reply",
              "chatId": "chat/one",
              "clientGeneratedId": "reply-attempt",
              "messageType": "text",
              "sender": {"uid": 1, "gender": 0, "name": "Ada"},
              "createdAt": "2026-09-01T01:02:03Z",
              "isEdited": false,
              "isDeleted": false,
              "hasAttachments": false,
              "attachments": [],
              "reactions": [],
              "message": "Thread reply",
              "replyRootId": "root#two"
            }
            """#)
        }
        let client: any ChahuaAPIClient = ChahuaClient(
            configuration: ChahuaConfiguration(baseURL: URL(string: "https://api.example")!),
            token: "candidate",
            session: testSession()
        )

        let response = try await client.sendThreadMessage(
            chatID: "chat/one",
            threadID: "root#two",
            body: CreateMessageBody(
                messageType: .text,
                clientGeneratedId: "reply-attempt",
                message: "Thread reply",
                replyToId: "previous-reply"
            )
        )

        XCTAssertEqual(response.id, "server-reply")
        XCTAssertEqual(response.replyRootId, "root#two")
        XCTAssertEqual(response.message, "Thread reply")
        let request = try XCTUnwrap(requests.values.first)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/chats/chat%2Fone/threads/root%23two/messages")
        XCTAssertNil(components.query)
        XCTAssertNil(components.fragment)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
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

private func requestBody(_ request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return data
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
