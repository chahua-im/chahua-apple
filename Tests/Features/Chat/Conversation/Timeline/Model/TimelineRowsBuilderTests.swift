import ChahuaAPI
import Foundation
import SwiftUI
import XCTest

@testable import chahua_apple

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
        XCTAssertEqual(rows.compactMap(messageRow).map(\.groupPosition), [.single, .single])
    }

    func testBuildKeepsContiguousSenderGroupedAcrossMinutes() throws {
        let rows = builder().build([
            try TimelineTestFixtures.message(id: "1", senderID: 2, at: 0),
            try TimelineTestFixtures.message(id: "2", senderID: 2, at: 30),
            try TimelineTestFixtures.message(id: "3", senderID: 2, at: 45),
            try TimelineTestFixtures.message(id: "4", senderID: 2, at: 0, minute: 6),
        ])
        let messages = rows.compactMap(messageRow)
        XCTAssertEqual(messages.map(\.groupPosition), [.first, .middle, .middle, .last])
        XCTAssertEqual(messages.map(\.showsSenderName), [true, false, false, false])
    }

    func testSameSenderBubblesUseFourPointGapAndOneAvatar() throws {
        for body in ["Hi", String(repeating: "A longer message for row geometry. ", count: 8)] {
            let rows = builder().build([
                try TimelineTestFixtures.message(id: "1", senderID: 2, at: 0, text: body),
                try TimelineTestFixtures.message(
                    id: "2", senderID: 2, at: 0, minute: 6, text: body),
                try TimelineTestFixtures.message(
                    id: "3", senderID: 3, at: 10, minute: 6, text: body),
            ]).compactMap(messageRow)
            XCTAssertEqual(rows.map(\.groupPosition), [.first, .last, .single])
            XCTAssertEqual(rows.map(\.showsSenderName), [true, false, true])
            let environment = TimelineLayoutEnvironment.current(timelineWidth: 320)
            let engine = TimelineLayoutEngine()
            let layouts = rows.map { row in
                engine.layout(
                    TimelineRowPresentation.make(
                        row: .message(row), currentUserProfile: nil, currentUserID: 1,
                        isThreadTimeline: false, environment: environment),
                    environment: environment)
            }
            XCTAssertNil(layouts[0].frames[.avatar])
            for index in 1..<3 {
                let bubble = try XCTUnwrap(layouts[index].frames[.bubble])
                let avatar = try XCTUnwrap(layouts[index].frames[.avatar])
                XCTAssertEqual(avatar.maxY, bubble.maxY, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(bubble.height, environment.avatarSize)
            }
            for index in 0..<2 {
                let current = try XCTUnwrap(layouts[index].frames[.bubble])
                let next = try XCTUnwrap(layouts[index + 1].frames[.bubble])
                XCTAssertEqual(
                    layouts[index].size.height - current.maxY + next.minY,
                    index == 0 ? 4 : 8, accuracy: 0.5)
            }
        }
    }

    func testSystemMessageBreaksGrouping() throws {
        let rows = builder().build([
            try TimelineTestFixtures.message(id: "1", senderID: 2, at: 0),
            try TimelineTestFixtures.message(id: "2", senderID: 2, at: 10, type: .system),
            try TimelineTestFixtures.message(id: "3", senderID: 2, at: 20),
        ])

        XCTAssertEqual(
            rows.compactMap(messageRow).map(\.groupPosition), [.single, .single, .single])
    }

    func testBuildShowsSenderNamesAtTheStartOfEveryNonSystemGroup() throws {
        let rows = builder().build([
            try TimelineTestFixtures.message(id: "1", senderID: 1, at: 0),
            try TimelineTestFixtures.message(id: "2", senderID: 2, at: 10),
            try TimelineTestFixtures.message(id: "3", senderID: 2, at: 20),
        ])
        let messages = rows.compactMap(messageRow)

        XCTAssertEqual(messages.map(\.isOutgoing), [true, false, false])
        XCTAssertEqual(messages.map(\.showsSenderName), [true, true, false])
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
            body: CreateMessageBody(
                messageType: .text, clientGeneratedId: "send-10", message: "Sending"),
            enqueuedAt: Date(timeIntervalSince1970: 1_788_220_800),
            senderID: 1,
            state: .sending
        )
        let rows = builder().build([.pending(pending)])

        XCTAssertEqual(rows[1].id, .message(.clientGenerated("send-10")))
        XCTAssertNil(rows[1].messageID)
        XCTAssertEqual(messageRow(rows[1])?.entry.displayState, .sending)
    }

    func testDirectMessageSenderMetadataMatchesPlatformContract() throws {
        let rows = builder(isGroupChat: false).build([
            try TimelineTestFixtures.message(id: "1", senderID: 2, at: 0)
        ])

        #if os(macOS)
            XCTAssertFalse(rows.compactMap(messageRow)[0].showsSenderName)
        #else
            XCTAssertTrue(rows.compactMap(messageRow)[0].showsSenderName)
        #endif
    }

    func testUnreadBoundaryBreaksSenderGroupingWithoutChangingMessageIdentity() throws {
        let messages = [
            try TimelineTestFixtures.message(id: "read", senderID: 2, at: 0),
            try TimelineTestFixtures.message(id: "unread", senderID: 2, at: 10),
            try TimelineTestFixtures.message(id: "next", senderID: 2, at: 20),
        ]
        let rows = builder().build(messages, unreadBeforeMessageID: "unread")
        let separator = try XCTUnwrap(rows.firstIndex { $0.id == .unreadSeparator })

        XCTAssertEqual(rows[separator - 1].messageID, "read")
        XCTAssertEqual(rows[separator + 1].messageID, "unread")
        XCTAssertNil(rows[separator].messageID)
        XCTAssertEqual(rows.compactMap(messageRow).map(\.groupPosition), [.single, .first, .last])
        XCTAssertEqual(rows.compactMap(messageRow).map(\.showsSenderName), [true, true, false])
        XCTAssertEqual(
            rows.compactMap(\.stableMessageKey),
            builder().build(messages).compactMap(\.stableMessageKey))
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
