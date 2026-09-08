import Combine
import Foundation
import XCTest
@testable import chahua_apple
import ChahuaAPI

@MainActor
final class ConversationMessageStoreTests: XCTestCase {
    func testQueuedMessageImmediatelyAppearsAsSendingProjectionEntry() throws {
        let store = ConversationMessageStore()
        store.enqueue(pending(id: "send-1", state: .queued))
        store.markSending(chatID: "chat", clientGeneratedID: "send-1")

        let projection = store.projection(for: "chat", remoteMessages: [], includePendingOutgoing: true)

        XCTAssertEqual(projection.entries.count, 1)
        XCTAssertEqual(projection.entries[0].stableKey, .clientGenerated("send-1"))
        XCTAssertEqual(projection.entries[0].displayState, .sending)
        XCTAssertNil(projection.entries[0].serverID)
    }

    func testAcknowledgementReplacesPendingEntryUnderSameStableKey() throws {
        let store = ConversationMessageStore()
        store.enqueue(pending(id: "send-1", state: .sending))
        let acknowledgement = try TimelineTestFixtures.message(
            id: "server-2",
            at: 2,
            clientGeneratedID: "send-1"
        )

        store.acknowledge(acknowledgement)
        let projection = store.projection(for: "chat", remoteMessages: [acknowledgement], includePendingOutgoing: true)

        XCTAssertEqual(projection.entries.count, 1)
        XCTAssertEqual(projection.entries[0].stableKey, .clientGenerated("send-1"))
        XCTAssertEqual(projection.entries[0].serverID, "server-2")
        XCTAssertEqual(projection.entries[0].displayState, .delivered)
    }

    func testOverlappingSnapshotTokensObserveOnlyTheirOwnChatAndRequestSuffix() throws {
        let store = ConversationMessageStore()
        let first = store.beginSnapshot(chatID: "chat")
        let message = try TimelineTestFixtures.message(id: "1", at: 1)
        store.apply(.message(message))
        let second = store.beginSnapshot(chatID: "chat")
        store.apply(.message(try TimelineTestFixtures.message(id: "other", chatID: "other", at: 2)))
        store.apply(.messageUpdated(message))
        XCTAssertEqual(eventNames(store.eventsDuringSnapshot(first)), ["create", "update"])
        XCTAssertEqual(eventNames(store.eventsDuringSnapshot(second)), ["update"])
        store.endSnapshot(first)
        XCTAssertEqual(eventNames(store.eventsDuringSnapshot(second)), ["update"])
        store.endSnapshot(second)
        let later = store.beginSnapshot(chatID: "chat")
        XCTAssertTrue(store.eventsDuringSnapshot(later).isEmpty)
        store.reset()
        store.apply(.message(message))
        XCTAssertTrue(store.eventsDuringSnapshot(later).isEmpty)
    }

    func testAcknowledgementBroadcastHasNoIntermediatePendingRemoval() throws {
        let store = ConversationMessageStore()
        store.enqueue(pending(id: "send-1", state: .sending))
        let acknowledgement = try TimelineTestFixtures.message(id: "server", at: 2, clientGeneratedID: "send-1")
        var projections: [ConversationProjection] = []
        let observation = store.changes.sink { change in
            let remote: [MessageResponse]
            if case .realtime(.message(let message)) = change { remote = [message] } else { remote = [] }
            projections.append(store.projection(for: "chat", remoteMessages: remote, includePendingOutgoing: true))
        }
        defer { observation.cancel() }
        store.acknowledge(acknowledgement)
        XCTAssertEqual(projections.map { $0.entries.map(\.stableKey) }, [[.clientGenerated("send-1")]])
        XCTAssertEqual(projections.first?.entries.first?.displayState, .delivered)
    }

    private func eventNames(_ events: [RealtimeServerEvent]) -> [String] {
        events.map {
            switch $0 {
            case .message: "create"
            case .messageUpdated: "update"
            default: "other"
            }
        }
    }

    private func pending(id: String, state: PendingOutgoingMessage.State) -> PendingOutgoingMessage {
        PendingOutgoingMessage(
            chatID: "chat",
            clientGeneratedID: id,
            body: CreateMessageBody(messageType: .text, clientGeneratedId: id, message: "hello"),
            enqueuedAt: Date(timeIntervalSince1970: 1_788_220_800),
            senderID: 1,
            state: state
        )
    }
}
