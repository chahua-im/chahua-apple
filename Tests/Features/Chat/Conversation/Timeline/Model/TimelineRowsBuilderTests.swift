import Foundation
import XCTest
@testable import chahua_apple
import ChahuaAPI

@MainActor
final class TimelineRowsBuilderTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testBuildInsertsDateSeparatorsAtDayBoundaries() throws {
        let rows = builder().build([
            try TimelineTestFixtures.message(id: "1", at: 0),
            try TimelineTestFixtures.message(id: "2", at: 1, dayOffset: 1),
        ])

        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.compactMap(dateRow).map(\.ordinalDay).count, 2)
        XCTAssertEqual(rows.compactMap(messageRow).map(\.entry.serverID), ["1", "2"])
    }

    func testBuildDerivesGroupPositionsFromSenderAndGap() throws {
        let rows = builder().build([
            try TimelineTestFixtures.message(id: "1", senderID: 2, at: 0),
            try TimelineTestFixtures.message(id: "2", senderID: 2, at: 30),
            try TimelineTestFixtures.message(id: "3", senderID: 2, at: 45),
            try TimelineTestFixtures.message(id: "4", senderID: 2, at: 0, minute: 6),
        ])

        XCTAssertEqual(rows.compactMap(messageRow).map(\.groupPosition), [.first, .middle, .last, .single])
    }

    func testSystemMessageBreaksGrouping() throws {
        let rows = builder().build([
            try TimelineTestFixtures.message(id: "1", senderID: 2, at: 0),
            try TimelineTestFixtures.message(id: "2", senderID: 2, at: 10, type: .system),
            try TimelineTestFixtures.message(id: "3", senderID: 2, at: 20),
        ])

        XCTAssertEqual(rows.compactMap(messageRow).map(\.groupPosition), [.single, .single, .single])
    }

    func testBuildMarksOutgoingAndIncomingGroupSenderNames() throws {
        let rows = builder().build([
            try TimelineTestFixtures.message(id: "1", senderID: 1, at: 0),
            try TimelineTestFixtures.message(id: "2", senderID: 2, at: 10),
            try TimelineTestFixtures.message(id: "3", senderID: 2, at: 20),
        ])
        let messages = rows.compactMap(messageRow)


        XCTAssertEqual(messages.map(\.isOutgoing), [true, false, false])
        XCTAssertEqual(messages.map(\.showsSenderName), [false, true, false])
    }

    func testMessageRowUsesClientGeneratedIDAsItsStableIdentity() throws {
        let message = try TimelineTestFixtures.message(
            id: "server-9",
            at: 0,
            clientGeneratedID: "send-9"
        )
        let rows = builder().build([message])

        XCTAssertEqual(rows[1].id, .message(.clientGenerated("send-9")))
        XCTAssertEqual(rows[1].messageID, "server-9")
    }

    func testPendingMessageProducesAStableSendingRowWithoutServerID() {
        let pending = PendingOutgoingMessage(
            chatID: "chat",
            clientGeneratedID: "send-10",
            body: CreateMessageBody(messageType: .text, clientGeneratedId: "send-10", message: "Sending"),
            enqueuedAt: Date(timeIntervalSince1970: 1_788_220_800),
            senderID: 1,
            state: .sending
        )
        let rows = builder().build([.pending(pending)])

        XCTAssertEqual(rows[1].id, .message(.clientGenerated("send-10")))
        XCTAssertNil(rows[1].messageID)
        XCTAssertEqual(messageRow(rows[1])?.entry.displayState, .sending)
    }

    func testDirectMessagesNeverShowSenderNames() throws {
        let rows = builder(isGroupChat: false).build([
            try TimelineTestFixtures.message(id: "1", senderID: 2, at: 0),
        ])

        XCTAssertFalse(rows.compactMap(messageRow)[0].showsSenderName)
    }

    private func builder(isGroupChat: Bool = true) -> TimelineRowsBuilder {
        TimelineRowsBuilder(currentUserID: 1, isGroupChat: isGroupChat, calendar: calendar)
    }

    private func messageRow(_ row: TimelineRow) -> TimelineMessageRow? {
        guard case .message(let value) = row else { return nil }
        return value
    }

    private func dateRow(_ row: TimelineRow) -> TimelineDateSeparatorRow? {
        guard case .dateSeparator(let value) = row else { return nil }
        return value
    }
}
