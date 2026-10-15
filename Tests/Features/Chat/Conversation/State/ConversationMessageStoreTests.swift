import ChahuaAPI
import Combine
import Foundation
import XCTest

@testable import chahua_apple

@MainActor
final class ConversationMessageStoreTests: XCTestCase {
    func testQueuedMessageImmediatelyAppearsAsSendingPendingEntry() throws {
        let store = ConversationMessageStore()
        store.enqueue(pending(id: "send-1", state: .queued))
        store.markSending(chatID: "chat", clientGeneratedID: "send-1")

        let entries = store.pending(chatID: "chat").map(ConversationTimelineEntry.pending)

        XCTAssertEqual(entries.map(\.stableKey), [.clientGenerated("send-1")])
        XCTAssertEqual(entries.first?.displayState, .sending)
        XCTAssertNil(entries.first?.serverID)
    }

    func testPendingSendsKeepOutboxOrderRegardlessOfEnqueueTime() throws {
        let store = ConversationMessageStore()
        store.replacePending(
            chatID: "chat",
            with: [
                pending(id: "first", state: .sending, enqueuedAt: 20),
                pending(id: "second", state: .queued, enqueuedAt: 10),
            ])

        XCTAssertEqual(store.pending(chatID: "chat").map(\.clientGeneratedID), ["first", "second"])
    }

    func testAcknowledgementRemovesPendingAndKeepsTheClientStableKey() throws {
        let store = ConversationMessageStore()
        store.enqueue(pending(id: "send-1", state: .sending))
        let acknowledgement = try TimelineTestFixtures.message(
            id: 2,
            at: 2,
            clientGeneratedID: "send-1"
        )

        store.acknowledge(acknowledgement)

        XCTAssertTrue(store.pending(chatID: "chat").isEmpty)
        XCTAssertEqual(acknowledgement.timelineStableKey, .clientGenerated("send-1"))
        XCTAssertEqual(ConversationTimelineEntry.remote(acknowledgement).displayState, .delivered)
    }

    func testOverlappingSnapshotTokensObserveOnlyTheirOwnChatAndRequestSuffix() throws {
        let store = ConversationMessageStore()
        let first = store.beginSnapshot(chatID: "chat")
        let message = try TimelineTestFixtures.message(id: 1, at: 1)
        store.apply(.message(message))
        let second = store.beginSnapshot(chatID: "chat")
        store.apply(.message(try TimelineTestFixtures.message(id: 2, chatID: "other", at: 2)))
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
        let acknowledgement = try TimelineTestFixtures.message(
            id: 2, at: 2, clientGeneratedID: "send-1")
        var observed: [(pending: [String], acknowledged: MessageID?)] = []
        let observation = store.changes.sink { change in
            var acknowledged: MessageID?
            if case .realtime(.message(let message)) = change { acknowledged = message.id }
            observed.append(
                (store.pending(chatID: "chat").map(\.clientGeneratedID), acknowledged))
        }
        defer { observation.cancel() }
        store.acknowledge(acknowledgement)
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.pending, [])
        XCTAssertEqual(observed.first?.acknowledged, MessageID(2))
    }

    func testCommittedBatchAcknowledgementPublishesSuccessorStateAndJournalsOneAtomicIngress()
        throws
    {
        let store = ConversationMessageStore()
        store.replacePending(
            chatID: "chat",
            with: [
                pending(id: "send-1", state: .sending),
                pending(id: "send-2", state: .queued),
            ])
        let token = store.beginSnapshot(chatID: "chat")
        defer { store.endSnapshot(token) }
        let acknowledgement = try TimelineTestFixtures.message(
            id: 2, at: 2, clientGeneratedID: "send-1")
        var observed: [(pending: [PendingOutgoingMessage], acknowledged: MessageID?)] = []
        let observation = store.changes.sink { change in
            var acknowledged: MessageID?
            if case .realtime(.message(let message)) = change { acknowledged = message.id }
            observed.append((store.pending(chatID: "chat"), acknowledged))
        }
        defer { observation.cancel() }

        store.replacePending(
            chatID: "chat", with: [pending(id: "send-2", state: .failed)],
            acknowledging: acknowledgement)

        XCTAssertEqual(observed.count, 1)
        let state = try XCTUnwrap(observed.first)
        XCTAssertEqual(state.acknowledged, MessageID(2))
        XCTAssertEqual(state.pending.map(\.clientGeneratedID), ["send-2"])
        XCTAssertEqual(state.pending.first?.state, .failed)
        XCTAssertEqual(eventNames(store.eventsDuringSnapshot(token)), ["create"])
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

    private func pending(
        id: String, state: PendingOutgoingMessage.State, enqueuedAt second: TimeInterval = 0
    ) -> PendingOutgoingMessage {
        PendingOutgoingMessage(
            chatID: "chat",
            clientGeneratedID: id,
            body: CreateMessageBody(messageType: .text, clientGeneratedId: id, message: "hello"),
            enqueuedAt: Date(timeIntervalSince1970: 1_788_220_800 + second),
            senderID: 1,
            state: state
        )
    }
}
