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

        let projection = store.projection(for: "chat", remoteMessages: [], includeDeferredLive: false)

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
        let projection = store.projection(for: "chat", remoteMessages: [], includeDeferredLive: true)

        XCTAssertEqual(projection.entries.count, 1)
        XCTAssertEqual(projection.entries[0].stableKey, .clientGenerated("send-1"))
        XCTAssertEqual(projection.entries[0].serverID, "server-2")
        XCTAssertEqual(projection.entries[0].displayState, .delivered)
    }

    func testDeferredLiveMessagesStayOutOfHistoryProjectionUntilLiveEdge() throws {
        let store = ConversationMessageStore()
        let remote = try TimelineTestFixtures.message(id: "server-1", at: 1)
        let live = try TimelineTestFixtures.message(id: "server-2", at: 2)
        store.receiveLive(live)

        let history = store.projection(for: "chat", remoteMessages: [remote], includeDeferredLive: false)
        XCTAssertEqual(history.entries.map(\.serverID), ["server-1"])
        XCTAssertEqual(store.bufferedLiveEventCountForTesting(chatID: "chat"), 1)

        let liveEdge = store.projection(for: "chat", remoteMessages: [remote], includeDeferredLive: true)
        XCTAssertEqual(liveEdge.entries.map(\.serverID), ["server-1", "server-2"])
        store.consumeDeferredLive(chatID: "chat", projectedKeys: Set(liveEdge.entries.map(\.stableKey)))

        XCTAssertEqual(store.bufferedLiveEventCountForTesting(chatID: "chat"), 0)
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
