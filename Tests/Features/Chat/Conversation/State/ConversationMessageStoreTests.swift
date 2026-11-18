import ChahuaAPI
import Combine
import Foundation
import XCTest

@testable import chahua_apple

@MainActor
final class ConversationMessageStoreTests: XCTestCase {
    func testQueuedMessageImmediatelyAppearsAsSendingPendingEntry() throws {
        let store = ConversationMessageStore()
        let queued = TimelineTestFixtures.pending(id: "send-1")
        store.replacePending(chatID: "chat", with: [queued])
        var sending = queued
        sending.phase = .sending
        store.replacePending(chatID: "chat", with: [sending])

        let entries = store.pending(chatID: "chat").map(ConversationTimelineEntry.pending)

        XCTAssertEqual(entries.map(\.stableKey), [TimelineTestFixtures.stableKey("send-1")])
        XCTAssertEqual(entries.first?.displayState, .sending)
        XCTAssertNil(entries.first?.serverID)
    }

    func testPendingSendsKeepOutboxOrderRegardlessOfEnqueueTime() throws {
        let store = ConversationMessageStore()
        store.replacePending(
            chatID: "chat",
            with: [
                TimelineTestFixtures.pending(id: "first", at: 20, phase: .sending),
                TimelineTestFixtures.pending(id: "second", at: 10),
            ])

        XCTAssertEqual(store.pending(chatID: "chat").map(\.clientGeneratedID), ["first", "second"])
    }

    func testAcknowledgementRemovesPendingAndKeepsTheClientStableKey() throws {
        let store = ConversationMessageStore()
        let pending = TimelineTestFixtures.pending(id: "send-1", phase: .sending)
        store.replacePending(chatID: "chat", with: [pending])
        let acknowledgement = try TimelineTestFixtures.message(
            id: 2,
            at: 2,
            clientGeneratedID: "send-1"
        )

        store.replacePending(chatID: "chat", with: [], acknowledging: acknowledgement)

        XCTAssertTrue(store.pending(chatID: "chat").isEmpty)
        XCTAssertEqual(
            acknowledgement.timelineStableKey,
            ConversationTimelineEntry.pending(pending).stableKey)
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
        store.replacePending(
            chatID: "chat", with: [TimelineTestFixtures.pending(id: "send-1", phase: .sending)])
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
        store.replacePending(chatID: "chat", with: [], acknowledging: acknowledgement)
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
                TimelineTestFixtures.pending(id: "send-1", phase: .sending),
                TimelineTestFixtures.pending(id: "send-2"),
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

        let failed: OutboxPhase = .failed(
            .init(stage: .create, reason: .rejected, retry: .manual), nextRetry: nil)

        store.replacePending(
            chatID: "chat", with: [TimelineTestFixtures.pending(id: "send-2", phase: failed)],
            acknowledging: acknowledgement)

        XCTAssertEqual(observed.count, 1)
        let state = try XCTUnwrap(observed.first)
        XCTAssertEqual(state.acknowledged, MessageID(2))
        XCTAssertEqual(state.pending.map(\.clientGeneratedID), ["send-2"])
        XCTAssertEqual(state.pending.first?.phase, failed)
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
}
