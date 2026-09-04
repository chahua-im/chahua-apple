import Foundation
import XCTest
@testable import chahua_apple
import ChahuaAPI

@MainActor
final class TimelineWindowTests: XCTestCase {
    func testReplaceNormalizesDescendingPageToChronologicalOrder() throws {
        var window = TimelineWindow()
        window.replace(with: try page([message("3", at: 3), message("2", at: 2), message("1", at: 1)]))

        XCTAssertEqual(window.messages.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(window.index(ofServerID: "2"), 1)
    }

    func testPrependOlderDeduplicatesAndUpdatesCursor() throws {
        var window = TimelineWindow()
        window.replace(with: try page([message("3", at: 3), message("4", at: 4)], olderCursor: "3", newerCursor: nil))

        let inserted = window.prependOlder(try page([message("3", at: 3), message("2", at: 2), message("1", at: 1)], olderCursor: "1", newerCursor: "3"))

        XCTAssertEqual(inserted, 2)
        XCTAssertEqual(window.messages.map(\.id), ["1", "2", "3", "4"])
        XCTAssertEqual(window.olderCursor, "1")
        XCTAssertNil(window.newerCursor)
    }

    func testEmptyOlderPageMarksHistoryExhausted() throws {
        var window = TimelineWindow()
        window.replace(with: try page([message("2", at: 2)], olderCursor: "2"))

        XCTAssertEqual(window.prependOlder(try page([])), 0)
        XCTAssertNil(window.olderCursor)
        XCTAssertFalse(window.hasOlder)
    }

    func testAppendNewerUpdatesCursorAndDeduplicates() throws {
        var window = TimelineWindow()
        window.replace(with: try page([message("1", at: 1), message("2", at: 2)], newerCursor: "2"))

        let inserted = window.appendNewer(try page([message("2", at: 2), message("3", at: 3)], olderCursor: "2", newerCursor: "3"))

        XCTAssertEqual(inserted, 1)
        XCTAssertEqual(window.messages.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(window.newerCursor, "3")
    }

    func testLiveInsertionDefersOffLiveEdgeAndUpdatesExistingMessage() throws {
        var window = TimelineWindow()
        window.replace(with: try page([message("1", at: 1)], newerCursor: "1"))
        XCTAssertEqual(window.insertLive(message("2", at: 2)), .deferred)
        XCTAssertEqual(window.messages.map(\.id), ["1"])

        window.replace(with: try page([message("1", at: 1)]))
        XCTAssertEqual(window.insertLive(message("2", at: 2)), .appended)
        XCTAssertEqual(window.insertLive(message("2", at: 2, text: "updated")), .updated)
        XCTAssertEqual(window.messages.map(\.id), ["1", "2"])
        XCTAssertEqual(window.messages[1].message, "updated")
    }

    func testMergeLiveReplacesKnownMessagesAndOrdersBatchChronologically() throws {
        var window = TimelineWindow()
        window.replace(with: try page([message("2", at: 2), message("1", at: 1)]))

        window.mergeLive([
            message("2", at: 2, text: "updated"),
            message("3", at: 3),
        ])

        XCTAssertEqual(window.messages.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(window.messages[1].message, "updated")
    }

    func testClientGeneratedIDKeepsAcknowledgedMessageAtTheSameStableKey() throws {
        let provisional = message("local-1", at: 1, clientGeneratedID: "send-1")
        let acknowledged = message("server-99", at: 2, text: "delivered", clientGeneratedID: "send-1")
        var window = TimelineWindow()
        window.replace(with: try page([provisional]))

        XCTAssertEqual(window.insertLive(acknowledged), .updated)
        XCTAssertEqual(window.count, 1)
        XCTAssertEqual(window.messages[0].id, "server-99")
        XCTAssertEqual(window.index(of: .clientGenerated("send-1")), 0)
        XCTAssertEqual(window.index(ofServerID: "server-99"), 0)
        XCTAssertNil(window.index(ofServerID: "local-1"))
    }

    func testEmptyClientGeneratedIDFallsBackToServerID() throws {
        let response = message("server-1", at: 1, clientGeneratedID: "")

        XCTAssertEqual(response.timelineStableKey, .server("server-1"))
    }

    func testUpsertAndRemoveOnlyAffectLoadedMessages() throws {
        var window = TimelineWindow()
        window.replace(with: try page([message("1", at: 1)]))

        XCTAssertFalse(window.upsert(message("2", at: 2)))
        XCTAssertTrue(window.upsert(message("1", at: 1, text: "edited")))
        XCTAssertEqual(window.messages[0].message, "edited")
        XCTAssertFalse(window.remove(serverID: "2"))
        XCTAssertTrue(window.remove(serverID: "1"))
        XCTAssertTrue(window.messages.isEmpty)
    }

    func testTrimNewestCreatesBoundaryCursorAndLeavesLiveEdge() throws {
        var window = TimelineWindow()
        window.replace(with: try page((1 ... 5).map { message("\($0)", at: $0) }))

        XCTAssertEqual(window.trim(.newest, toCount: 3), 2)
        XCTAssertEqual(window.messages.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(window.newerCursor, "3")
        XCTAssertFalse(window.isAtLiveEdge)
    }

    func testTrimOldestCreatesBoundaryCursor() throws {
        var window = TimelineWindow()
        window.replace(with: try page((1 ... 5).map { message("\($0)", at: $0) }))

        XCTAssertEqual(window.trim(.oldest, toCount: 3), 2)
        XCTAssertEqual(window.messages.map(\.id), ["3", "4", "5"])
        XCTAssertEqual(window.olderCursor, "3")
    }

    private func message(
        _ id: String,
        at second: Int,
        text: String? = nil,
        clientGeneratedID: String? = nil
    ) -> MessageResponse {
        try! JSONDecoder.messageFixtureDecoder.decode(
            MessageResponse.self,
            from: Data("""
            {
              "id": "\(id)", "chatId": "chat", "clientGeneratedId": "\(clientGeneratedID ?? "client-\(id)")", "messageType": "text",
              "sender": {"uid": 1, "gender": 0, "name": "Ada", "avatarUrl": null, "userGroup": null},
              "createdAt": "2026-09-01T00:00:\(String(format: "%02d", second))Z", "isEdited": false, "isDeleted": false,
              "hasAttachments": false, "attachments": [], "reactions": [], "mentions": [], "message": \(jsonString(text ?? "message \(id)"))
            }
            """.utf8)
        )
    }

    private func page(_ messages: [MessageResponse], olderCursor: String? = nil, newerCursor: String? = nil) throws -> ListMessagesResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let messagesJSON = try String(decoding: encoder.encode(messages), as: UTF8.self)
        return try JSONDecoder.messageFixtureDecoder.decode(
            ListMessagesResponse.self,
            from: Data("{\"messages\":\(messagesJSON),\"olderCursor\":\(jsonString(olderCursor)),\"newerCursor\":\(jsonString(newerCursor))}".utf8)
        )
    }

    private func jsonString(_ value: String?) -> String {
        guard let value else { return "null" }
        return "\"\(value)\""
    }
}

private extension JSONDecoder {
    static var messageFixtureDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
