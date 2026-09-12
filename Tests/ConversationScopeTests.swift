import ChahuaAPI
import Foundation
import XCTest
@testable import chahua_apple

@MainActor
final class ConversationScopeTests: XCTestCase {
    func testScopesOverlapWithoutConfusingThreadsWithTheirParentAndRespectDraftActivity() throws {
        let group = ChatListItem(id: "group", name: "Group", lastMessageAt: Date(timeIntervalSince1970: 20), unreadCount: 0, archived: false, kind: .group)
        let dm = ChatListItem(id: "dm", name: "DM", lastMessageAt: Date(timeIntervalSince1970: 30), unreadCount: 0, archived: false, kind: .dm)
        let archived = ChatListItem(id: "archived", unreadCount: 0, archived: true, kind: .group)
        let thread = try ScopeTestFixtures.thread(chatID: "group", id: "root", at: 40)
        let archivedThread = try ScopeTestFixtures.thread(chatID: "group", id: "archived-root", at: 50, archived: true)
        let chats = [group, archived, dm]
        let threads = [archivedThread, thread]
        let parentKey = ConversationKey(chatID: "group")
        let threadKey = ConversationKey(chatID: "group", threadID: "root")
        XCTAssertEqual(ConversationListItem.entries(chats: chats, threads: threads, scope: .messages).map(\.id), [threadKey, .init(chatID: "dm"), parentKey])
        XCTAssertEqual(ConversationListItem.entries(chats: chats, threads: threads, scope: .groups).map(\.id), [parentKey])
        XCTAssertEqual(ConversationListItem.entries(chats: chats, threads: threads, scope: .dms).map(\.id), [.init(chatID: "dm")])
        XCTAssertEqual(ConversationListItem.entries(chats: chats, threads: threads, scope: .threads).map(\.id), [threadKey])
        let reordered = ConversationListItem.entries(chats: chats, threads: threads, scope: .messages, draftUpdatedAt: [parentKey: Date(timeIntervalSince1970: 60)])
        XCTAssertEqual(reordered.map(\.id), [parentKey, threadKey, .init(chatID: "dm")])
    }

    func testPendingThreadRepliesStayInTheirTimelineThroughAcknowledgement() async throws {
        let store = ConversationMessageStore()
        for (id, threadID) in [("parent", nil), ("one", "one"), ("two", "two")] as [(String, String?)] {
            store.enqueue(PendingOutgoingMessage(
                chatID: "chat", threadID: threadID, clientGeneratedID: id,
                body: .init(messageType: .text, clientGeneratedId: id, message: id),
                enqueuedAt: Date(), senderID: 1, state: .queued))
        }
        let parent = store.projection(for: "chat", remoteMessages: [], includePendingOutgoing: true)
        let first = store.projection(for: "chat", threadID: "one", remoteMessages: [], includePendingOutgoing: true)
        XCTAssertEqual(parent.entries.map(\.stableKey), [.clientGenerated("parent")])
        XCTAssertEqual(first.entries.map(\.stableKey), [.clientGenerated("one")])
        let acknowledged = try TimelineTestFixtures.message(id: "remote", at: 1, clientGeneratedID: "one", fields: ["replyRootId": "one"])
        store.apply(.message(acknowledged))
        XCTAssertTrue(store.projection(for: "chat", threadID: "one", remoteMessages: [], includePendingOutgoing: true).entries.isEmpty)
        XCTAssertEqual(store.projection(for: "chat", threadID: "two", remoteMessages: [], includePendingOutgoing: true).entries.map(\.stableKey), [.clientGenerated("two")])
        XCTAssertEqual(store.projection(for: "chat", remoteMessages: [], includePendingOutgoing: true).entries.map(\.stableKey), [.clientGenerated("parent")])
    }
    func testMessagePreviewsExpandMentionsInSharedRenderer() throws {
        let message = try TimelineTestFixtures.message(
            id: "mentioned", at: 1,
            text: "Hi 👋 @[uid:2], @[uid:9], @[uid:2], @[uid:nope]",
            fields: [
                "mentions": [
                    ["uid": 2, "gender": 0, "username": "Grace"],
                    ["uid": 2, "gender": 0, "username": "Ada"],
                    ["uid": 2, "gender": 0, "username": ""],
                ],
            ])
        let preview = message.replyPreview
        let group = ConversationListItem.chat(ChatListItem(
            id: "group", name: "Group", lastMessageAt: message.createdAt,
            unreadCount: 0, lastMessage: preview, archived: false, kind: .group))
        let expected = "Hi 👋 @Ada, @User 9, @Ada, @[uid:nope]"

        XCTAssertEqual(messagePreview(preview), expected)
        XCTAssertEqual(group.preview, expected)
        XCTAssertEqual(group.previewSenderName(), "Ada")
    }

    func testThreadPreviewUsesLatestReplyThenRootMessageFallback() throws {
        let root = try TimelineTestFixtures.message(id: "root", at: 1, text: "Root message").replyPreview
        let reply = try TimelineTestFixtures.message(id: "reply", at: 2, text: "Latest reply").replyPreview

        func thread(lastReply: MessagePreview?) -> ConversationListItem {
            .thread(ThreadListItem(
                chatId: "chat", chatName: "Parent chat", threadRootMessage: root,
                participants: [], lastReply: lastReply, replyCount: 1,
                lastReplyAt: Date(timeIntervalSince1970: 2), unreadCount: 0,
                subscribedAt: .distantPast, archived: false))
        }

        XCTAssertEqual(thread(lastReply: reply).title, "Root message")
        XCTAssertEqual(thread(lastReply: reply).preview, "Latest reply")
        XCTAssertEqual(thread(lastReply: reply).previewSenderName(), "Ada")
        XCTAssertNil(thread(lastReply: reply).previewSenderName(parentKind: .dm))
        XCTAssertEqual(thread(lastReply: nil).preview, "Root message")
    }

}

@MainActor
enum ScopeTestFixtures {
    static func thread(chatID: String = "chat", id: String, at: TimeInterval = 40, archived: Bool = false) throws -> ThreadListItem {
        let message = try TimelineTestFixtures.message(id: id, chatID: chatID, at: 1)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let preview = try decoder.decode(MessagePreview.self, from: encoder.encode(message))
        return ThreadListItem(
            chatId: chatID, chatName: "Parent", chatAvatar: nil, threadRootMessage: preview,
            participants: [], lastReply: nil, replyCount: 1, lastReplyAt: Date(timeIntervalSince1970: at),
            unreadCount: 0, lastReadMessageId: nil, subscribedAt: Date(timeIntervalSince1970: 0), archived: archived)
    }
}
