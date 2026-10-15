import ChahuaAPI
import Foundation
import XCTest

@testable import chahua_apple

@MainActor
final class TimelineWindowTests: XCTestCase {
    func testReplaceNormalizesDescendingPageToServerOrder() throws {
        var window = TimelineWindow()
        window.replace(with: try page([message(3, at: 3), message(2, at: 2), message(1, at: 1)]))

        XCTAssertEqual(window.messages.map(\.id), ids(1, 2, 3))
        XCTAssertEqual(window.index(ofServerID: MessageID(2)), 1)
    }

    func testPrependOlderDeduplicatesAndUpdatesCursor() throws {
        var window = TimelineWindow()
        window.replace(
            with: try page(
                [message(3, at: 3), message(4, at: 4)], olderCursor: 3, newerCursor: nil))

        let inserted = window.prependOlder(
            try page(
                [message(3, at: 3), message(2, at: 2), message(1, at: 1)], olderCursor: 1,
                newerCursor: 3))

        XCTAssertEqual(inserted, 2)
        XCTAssertEqual(window.messages.map(\.id), ids(1, 2, 3, 4))
        XCTAssertEqual(window.olderCursor, MessageID(1))
        XCTAssertNil(window.newerCursor)
    }

    func testEmptyOlderPageMarksHistoryExhausted() throws {
        var window = TimelineWindow()
        window.replace(with: try page([message(2, at: 2)], olderCursor: 2))

        XCTAssertEqual(window.prependOlder(try page([])), 0)
        XCTAssertNil(window.olderCursor)
        XCTAssertFalse(window.hasOlder)
    }

    func testAppendNewerUpdatesCursorAndDeduplicates() throws {
        var window = TimelineWindow()
        window.replace(with: try page([message(1, at: 1), message(2, at: 2)], newerCursor: 2))

        let inserted = window.appendNewer(
            try page([message(2, at: 2), message(3, at: 3)], olderCursor: 2, newerCursor: 3))

        XCTAssertEqual(inserted, 1)
        XCTAssertEqual(window.messages.map(\.id), ids(1, 2, 3))
        XCTAssertEqual(window.newerCursor, MessageID(3))
    }

    func testLiveInsertionDefersOffLiveEdgeAndNeverReplacesDuplicateContent() throws {
        var window = TimelineWindow()
        window.replace(with: try page([message(1, at: 1)], newerCursor: 1))
        XCTAssertEqual(window.insertLive(message(2, at: 2)), .deferred)
        XCTAssertEqual(window.messages.map(\.id), ids(1))

        window.replace(with: try page([message(1, at: 1)]))
        XCTAssertEqual(window.insertLive(message(2, at: 2)), .appended)
        XCTAssertEqual(window.insertLive(message(2, at: 2, text: "stale echo")), .duplicate)
        XCTAssertEqual(window.messages.map(\.id), ids(1, 2))
        XCTAssertEqual(window.messages[1].message, "message 2")
    }

    func testLiveInsertionPlacesEarlierIDAtItsServerPosition() throws {
        // Another node's message can be published after a newer ID has arrived.
        var window = TimelineWindow()
        window.replace(with: try page([message(1, at: 1), message(2, at: 2), message(5, at: 5)]))

        XCTAssertEqual(window.insertLive(message(4, at: 9, clientGeneratedID: "late")), .appended)
        XCTAssertEqual(window.insertLive(message(3, at: 9)), .appended)
        XCTAssertEqual(window.insertLive(message(6, at: 0)), .appended)

        XCTAssertEqual(window.messages.map(\.id), ids(1, 2, 3, 4, 5, 6))
        for (index, id) in window.messages.map(\.id).enumerated() {
            XCTAssertEqual(window.index(ofServerID: id), index)
        }
        XCTAssertEqual(window.index(of: .clientGenerated("late")), 3)
        XCTAssertNil(window.index(ofServerID: MessageID(7)))
    }

    func testAuthoritativePageReplacesKnownContentAndOrdersByServerID() throws {
        var window = TimelineWindow()
        window.replace(with: try page([message(2, at: 2), message(1, at: 1)]))
        window.appendNewer(
            try page([message(4, at: 3), message(2, at: 2, text: "updated"), message(3, at: 3)]))
        XCTAssertEqual(window.messages.map(\.id), ids(1, 2, 3, 4))
        XCTAssertEqual(window.messages[1].message, "updated")

        // Server order is the ID, even when a cross-node timestamp disagrees.
        window.appendNewer(try page([message(5, at: 0)]))
        XCTAssertEqual(window.messages.map(\.id), ids(1, 2, 3, 4, 5))
    }

    func testClientGeneratedIDKeepsAcknowledgedMessageAtTheSameStableKey() throws {
        let provisional = message(1, at: 1, clientGeneratedID: "send-1")
        let acknowledged = message(99, at: 2, text: "delivered", clientGeneratedID: "send-1")
        var window = TimelineWindow()
        window.replace(with: try page([provisional, message(50, at: 1)]))

        window.appendNewer(try page([acknowledged]))
        XCTAssertEqual(window.messages.map(\.id), ids(50, 99))
        XCTAssertEqual(window.index(of: .clientGenerated("send-1")), 1)
        XCTAssertEqual(window.index(ofServerID: MessageID(99)), 1)
        XCTAssertNil(window.index(ofServerID: MessageID(1)))
    }

    func testServerIdentityWinsWhenClientIdentityChangesAndPagesContainDuplicates() throws {
        var window = TimelineWindow()
        window.replace(
            with: try page([
                message(7, at: 1, clientGeneratedID: ""),
                message(7, at: 1, text: "current", clientGeneratedID: "send"),
            ]))
        XCTAssertEqual(window.messages.map(\.message), ["current"])
        XCTAssertEqual(
            window.insertLive(message(7, at: 1, text: "old", clientGeneratedID: "other")),
            .duplicate)
        XCTAssertEqual(window.messages.map(\.message), ["current"])
        XCTAssertEqual(window.index(of: .clientGenerated("send")), 0)
    }

    func testEmptyClientGeneratedIDFallsBackToServerID() throws {
        let response = message(1, at: 1, clientGeneratedID: "")

        XCTAssertEqual(response.timelineStableKey, .server(MessageID(1)))
    }

    func testUpsertAndRemoveOnlyAffectLoadedMessages() throws {
        var window = TimelineWindow()
        window.replace(with: try page([message(1, at: 1)]))

        XCTAssertFalse(window.upsert(message(2, at: 2)))
        XCTAssertTrue(window.upsert(message(1, at: 1, text: "edited")))
        XCTAssertEqual(window.messages[0].message, "edited")
        XCTAssertFalse(window.remove(serverID: MessageID(2)))
        XCTAssertTrue(window.remove(serverID: MessageID(1)))
        XCTAssertTrue(window.messages.isEmpty)
        XCTAssertNil(window.index(of: .clientGenerated("client-1")))
    }

    func testTrimNewestCreatesBoundaryCursorAndLeavesLiveEdge() throws {
        var window = TimelineWindow()
        window.replace(with: try page((1...5).map { message(UInt64($0), at: $0) }))

        XCTAssertEqual(window.trim(.newest, toCount: 3), 2)
        XCTAssertEqual(window.messages.map(\.id), ids(1, 2, 3))
        XCTAssertEqual(window.newerCursor, MessageID(3))
        XCTAssertFalse(window.isAtLiveEdge)
        XCTAssertNil(window.index(of: .clientGenerated("client-4")))
    }

    func testTrimOldestCreatesBoundaryCursor() throws {
        var window = TimelineWindow()
        window.replace(with: try page((1...5).map { message(UInt64($0), at: $0) }))

        XCTAssertEqual(window.trim(.oldest, toCount: 3), 2)
        XCTAssertEqual(window.messages.map(\.id), ids(3, 4, 5))
        XCTAssertEqual(window.olderCursor, MessageID(3))
    }

    private func ids(_ values: UInt64...) -> [MessageID] { values.map(MessageID.init) }

    private func message(
        _ id: UInt64,
        at second: Int,
        text: String? = nil,
        clientGeneratedID: String? = nil
    ) -> MessageResponse {
        try! JSONDecoder.messageFixtureDecoder.decode(
            MessageResponse.self,
            from: Data(
                """
                {
                  "id": "\(id)", "chatId": "chat", "clientGeneratedId": "\(clientGeneratedID ?? "client-\(id)")", "messageType": "text",
                  "sender": {"uid": 1, "gender": 0, "name": "Ada", "avatarUrl": null, "userGroup": null},
                  "createdAt": "2026-09-01T00:00:\(String(format: "%02d", second))Z", "isEdited": false, "isDeleted": false,
                  "hasAttachments": false, "attachments": [], "reactions": [], "mentions": [], "message": \(jsonString(text ?? "message \(id)"))
                }
                """.utf8)
        )
    }

    private func page(
        _ messages: [MessageResponse], olderCursor: UInt64? = nil, newerCursor: UInt64? = nil
    ) throws -> ListMessagesResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let messagesJSON = try String(decoding: encoder.encode(messages), as: UTF8.self)
        return try JSONDecoder.messageFixtureDecoder.decode(
            ListMessagesResponse.self,
            from: Data(
                "{\"messages\":\(messagesJSON),\"olderCursor\":\(jsonString(olderCursor.map(String.init))),\"newerCursor\":\(jsonString(newerCursor.map(String.init)))}"
                    .utf8)
        )
    }

    private func jsonString(_ value: String?) -> String {
        guard let value else { return "null" }
        return "\"\(value)\""
    }
}

extension JSONDecoder {
    fileprivate static var messageFixtureDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
