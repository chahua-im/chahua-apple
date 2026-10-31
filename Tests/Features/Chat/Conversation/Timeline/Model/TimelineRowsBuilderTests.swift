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
            try TimelineTestFixtures.message(id: 1, at: 0),
            try TimelineTestFixtures.message(id: 2, at: 1, dayOffset: 1),
        ])

        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.compactMap(dateRow).map(\.ordinalDay).count, 2)
        XCTAssertEqual(
            rows.compactMap(messageRow).map(\.entry.serverID), [MessageID(1), MessageID(2)])
        XCTAssertEqual(rows.compactMap(messageRow).map(\.groupPosition), [.single, .single])
    }

    func testBuildKeepsContiguousSenderGroupedAcrossMinutes() throws {
        let rows = builder().build([
            try TimelineTestFixtures.message(id: 1, senderID: 2, at: 0),
            try TimelineTestFixtures.message(id: 2, senderID: 2, at: 30),
            try TimelineTestFixtures.message(id: 3, senderID: 2, at: 45),
            try TimelineTestFixtures.message(id: 4, senderID: 2, at: 0, minute: 6),
        ])
        let messages = rows.compactMap(messageRow)
        XCTAssertEqual(messages.map(\.groupPosition), [.first, .middle, .middle, .last])
        XCTAssertEqual(messages.map(\.showsSenderName), [true, false, false, false])
    }

    func testSenderRunSpacingMatchesLayoutDensityAndOneAvatar() throws {
        for body in ["Hi", String(repeating: "A longer message for row geometry. ", count: 8)] {
            let rows = builder().build([
                try TimelineTestFixtures.message(id: 1, senderID: 2, at: 0, text: body),
                try TimelineTestFixtures.message(
                    id: 2, senderID: 2, at: 0, minute: 6, text: body),
                try TimelineTestFixtures.message(
                    id: 3, senderID: 3, at: 10, minute: 6, text: body),
            ]).compactMap(messageRow)
            XCTAssertEqual(rows.map(\.groupPosition), [.first, .last, .single])
            XCTAssertEqual(rows.map(\.showsSenderName), [true, false, true])
            let engine = TimelineLayoutEngine()
            for isWide in [false, true] {
                let environment = TimelineLayoutEnvironment.current(
                    timelineWidth: isWide ? 900 : 320, isWideChatLayout: isWide)
                let layouts = rows.map { row in
                    engine.layout(
                        TimelineRowPresentation.make(
                            row: .message(row), currentUserID: 1, isThreadTimeline: false,
                            environment: environment),
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
                        index == 0 ? (isWide ? 2 : 4) : (isWide ? 12 : 8), accuracy: 0.5)
                }
            }
        }
    }

    func testSystemMessageBreaksGrouping() throws {
        let rows = builder().build([
            try TimelineTestFixtures.message(id: 1, senderID: 2, at: 0),
            try TimelineTestFixtures.message(id: 2, senderID: 2, at: 10, type: .system),
            try TimelineTestFixtures.message(id: 3, senderID: 2, at: 20),
        ])

        XCTAssertEqual(
            rows.compactMap(messageRow).map(\.groupPosition), [.single, .single, .single])
    }

    func testBuildShowsSenderNamesAtTheStartOfEveryNonSystemGroup() throws {
        let rows = builder().build([
            try TimelineTestFixtures.message(id: 1, senderID: 1, at: 0),
            try TimelineTestFixtures.message(id: 2, senderID: 2, at: 10),
            try TimelineTestFixtures.message(id: 3, senderID: 2, at: 20),
        ])
        let messages = rows.compactMap(messageRow)

        XCTAssertEqual(messages.map(\.isOutgoing), [true, false, false])
        XCTAssertEqual(messages.map(\.showsSenderName), [true, true, false])
    }

    func testMessageRowUsesClientGeneratedIDAsItsStableIdentity() throws {
        let message = try TimelineTestFixtures.message(
            id: 9,
            at: 0,
            clientGeneratedID: "send-9"
        )
        let rows = builder().build([message])

        XCTAssertEqual(rows[1].id, .message(.clientGenerated("send-9")))
        XCTAssertEqual(rows[1].messageID, MessageID(9))
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

    func testSenderMetadataRemainsAvailableForIdentityPreferences() throws {
        let rows = builder().build([
            try TimelineTestFixtures.message(id: 1, senderID: 2, at: 0)
        ])

        XCTAssertTrue(rows.compactMap(messageRow)[0].showsSenderName)
    }

    func testAllAvatarDensityKeepsGroupingAndSenderHeaders() throws {
        let rows = builder().build(
            try (1...3).map {
                try TimelineTestFixtures.message(id: UInt64($0), senderID: 2, at: $0)
            }
        ).compactMap(messageRow)
        XCTAssertEqual(rows.map(\.groupPosition), [.first, .middle, .last])
        let engine = TimelineLayoutEngine()
        for showAllAvatars in [false, true] {
            let environment = TimelineLayoutEnvironment.current(
                timelineWidth: 320, showAllAvatars: showAllAvatars)
            let presentations = rows.map {
                TimelineRowPresentation.make(
                    row: .message($0), currentUserID: 1, isThreadTimeline: false,
                    environment: environment)
            }
            let layouts = presentations.map { engine.layout($0, environment: environment) }
            XCTAssertEqual(
                layouts.map { $0.frames[.avatar] != nil },
                showAllAvatars ? [true, true, true] : [false, false, true])
            XCTAssertEqual(presentations.map { $0.title != nil }, [true, false, false])
        }
    }

    func testHiddenIdentityReclaimsLanesInConversationsAndThreads() throws {
        let visibleEnvironment = TimelineLayoutEnvironment.current(timelineWidth: 320)
        let hiddenEnvironment = TimelineLayoutEnvironment.current(
            timelineWidth: 320, showAllAvatars: true, showsMessageDetails: false)
        XCTAssertEqual(
            hiddenEnvironment.centralWidth - visibleEnvironment.centralWidth,
            2 * (visibleEnvironment.avatarSize + TimelineRowMetrics.laneGap))
        let engine = TimelineLayoutEngine()
        for outgoing in [false, true] {
            let message = try TimelineTestFixtures.message(
                id: 1, senderID: outgoing ? 1 : 2, at: 0,
                text: String(repeating: "A longer message for identity geometry. ", count: 8))
            let row = try XCTUnwrap(builder().build([message]).first { $0.messageID != nil })
            for isThread in [false, true] {
                let visible = TimelineRowPresentation.make(
                    row: row, currentUserID: 1, isThreadTimeline: isThread,
                    environment: visibleEnvironment)
                let hidden = TimelineRowPresentation.make(
                    row: row, currentUserID: 1, isThreadTimeline: isThread,
                    environment: hiddenEnvironment)
                let visibleLayout = engine.layout(visible, environment: visibleEnvironment)
                let hiddenLayout = engine.layout(hidden, environment: hiddenEnvironment)
                XCTAssertNotNil(visible.title)
                XCTAssertNil(hidden.title)
                XCTAssertNil(hiddenLayout.frames[.avatar])
                XCTAssertNil(hiddenLayout.frames[.title])
                XCTAssertEqual(visible.row, hidden.row)
                XCTAssertNotEqual(visible.layoutKey, hidden.layoutKey)
                let bubble = try XCTUnwrap(hiddenLayout.frames[.bubble])
                XCTAssertGreaterThan(
                    bubble.width, try XCTUnwrap(visibleLayout.frames[.bubble]).width)
                XCTAssertGreaterThanOrEqual(bubble.minX, TimelineRowMetrics.rowHorizontalInset)
                XCTAssertLessThanOrEqual(
                    bubble.maxX,
                    hiddenEnvironment.timelineWidth - TimelineRowMetrics.rowHorizontalInset)
            }
        }
    }

    func testWideLayoutCapsBubblesAndInvalidatesCachedWidthAndDensity() throws {
        for senderID in [Int32(1), Int32(2)] {
            let message = try TimelineTestFixtures.message(
                id: 1, senderID: senderID, at: 0,
                text: String(
                    repeating: "A longer message for native width measurement. ", count: 30))
            let row = try XCTUnwrap(builder().build([message]).first { $0.messageID != nil })
            let cache = TimelineLayoutCache()
            let compact = TimelineLayoutEnvironment.current(
                timelineWidth: 1200, bodySize: 23, showsMessageDetails: false)
            let wide = TimelineLayoutEnvironment.current(
                timelineWidth: 1200, bodySize: 23, showsMessageDetails: false,
                isWideChatLayout: true)
            let narrowPane = TimelineLayoutEnvironment.current(
                timelineWidth: 420, bodySize: 23, showsMessageDetails: false, isWideChatLayout: true
            )
            var layouts: [TimelineRowLayout] = []
            for environment in [compact, wide, narrowPane] {
                let presentation = TimelineRowPresentation.make(
                    row: row, currentUserID: 1, isThreadTimeline: false, environment: environment)
                XCTAssertEqual(presentation.environment.bodySize, 23)
                layouts.append(cache.layout(for: presentation, environment: environment))
                // An identical environment reuses geometry, not another measurement.
                _ = cache.layout(for: presentation, environment: environment)
            }
            XCTAssertEqual(cache.missCount, 3)
            XCTAssertNotEqual(compact, wide)
            let compactBubble = try XCTUnwrap(layouts[0].frames[.bubble])
            let wideBubble = try XCTUnwrap(layouts[1].frames[.bubble])
            let narrowBubble = try XCTUnwrap(layouts[2].frames[.bubble])
            XCTAssertGreaterThan(compactBubble.width, 620)
            XCTAssertEqual(wideBubble.width, 620, accuracy: 0.5)
            XCTAssertLessThanOrEqual(narrowBubble.width, 420 - 48)
            XCTAssertGreaterThan(layouts[2].size.height, layouts[1].size.height)
            if senderID == 1 {
                XCTAssertEqual(wideBubble.maxX, 1200 - 24, accuracy: 0.5)
                XCTAssertEqual(narrowBubble.maxX, 420 - 24, accuracy: 0.5)
            } else {
                XCTAssertEqual(wideBubble.minX, 24, accuracy: 0.5)
                XCTAssertEqual(narrowBubble.minX, 24, accuracy: 0.5)
            }
        }
    }

    func testUnreadBoundaryBreaksSenderGroupingWithoutChangingMessageIdentity() throws {
        let messages = [
            try TimelineTestFixtures.message(id: 1, senderID: 2, at: 0),
            try TimelineTestFixtures.message(id: 2, senderID: 2, at: 10),
            try TimelineTestFixtures.message(id: 3, senderID: 2, at: 20),
        ]
        let rows = builder().build(messages, unreadBeforeMessageID: MessageID(2))
        let separator = try XCTUnwrap(rows.firstIndex { $0.id == .unreadSeparator })

        XCTAssertEqual(rows[separator - 1].messageID, MessageID(1))
        XCTAssertEqual(rows[separator + 1].messageID, MessageID(2))
        XCTAssertNil(rows[separator].messageID)
        XCTAssertEqual(rows.compactMap(messageRow).map(\.groupPosition), [.single, .first, .last])
        XCTAssertEqual(rows.compactMap(messageRow).map(\.showsSenderName), [true, true, false])
        XCTAssertEqual(
            rows.compactMap(\.stableMessageKey),
            builder().build(messages).compactMap(\.stableMessageKey))
    }

    private func builder() -> TimelineRowsBuilder {
        TimelineRowsBuilder(currentUserID: 1, calendar: calendar)
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
