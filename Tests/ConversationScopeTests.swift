import ChahuaAPI
import Foundation
import XCTest

@testable import chahua_apple

@MainActor
final class ConversationScopeTests: XCTestCase {
    func testNativePullRefreshOwnsListProgressDuringLoadingAndConnectionRecovery() {
        let statuses: [RealtimeConnectionStatus] = [
            .idle, .connecting, .connected, .reconnecting, .unavailable,
        ]
        for status in statuses {
            var state = ChatState()
            state.realtimeStatus = status
            state.chatListLoadPhase = .loading
            state.threadListLoadPhase = .loading
            XCTAssertTrue(
                ConversationListLoadStatus(state: state, scope: .messages, onRetry: {}).isVisible)
            XCTAssertFalse(
                ConversationListLoadStatus(
                    state: state, scope: .messages, isPullRefreshing: true, onRetry: {}
                ).isVisible)

            state.chatListLoadPhase = .loaded
            state.threadListLoadPhase = .loaded
            let isRecovering = status != .idle && status != .connected
            XCTAssertEqual(
                ConversationListLoadStatus(state: state, scope: .messages, onRetry: {}).isVisible,
                isRecovering)
            XCTAssertFalse(
                ConversationListLoadStatus(
                    state: state, scope: .messages, isPullRefreshing: true, onRetry: {}
                ).isVisible)
        }
    }

    func testScopesOverlapWithoutConfusingThreadsWithTheirParentAndRespectDraftActivity() throws {
        let group = ChatListItem(
            id: "group", name: "Group", lastMessageAt: Date(timeIntervalSince1970: 20),
            unreadCount: 0, archived: false, kind: .group)
        let dm = ChatListItem(
            id: "dm", name: "DM", lastMessageAt: Date(timeIntervalSince1970: 30), unreadCount: 0,
            archived: false, kind: .dm)
        let archived = ChatListItem(id: "archived", unreadCount: 0, archived: true, kind: .group)
        let archivedDM = ChatListItem(
            id: "archived-dm", lastMessageAt: Date(timeIntervalSince1970: 45), unreadCount: 1,
            archived: true, kind: .dm)
        let thread = try ScopeTestFixtures.thread(chatID: "group", id: 1, at: 40)
        let archivedThread = try ScopeTestFixtures.thread(
            chatID: "group", id: 2, at: 50, archived: true)
        let chats = [group, archived, dm, archivedDM]
        let threads = [archivedThread, thread]
        let parentKey = ConversationKey(chatID: "group")
        let threadKey = ConversationKey(chatID: "group", threadID: "1")
        XCTAssertEqual(
            ConversationListItem.entries(chats: chats, threads: threads, scope: .messages).map(
                \.id), [threadKey, .init(chatID: "dm"), parentKey])
        XCTAssertEqual(
            ConversationListItem.entries(
                chats: chats, threads: threads, scope: .messages, showThreadsInMessages: false
            ).map(\.id), [.init(chatID: "dm"), parentKey])
        XCTAssertEqual(
            ConversationListItem.entries(chats: chats, threads: threads, scope: .groups).map(\.id),
            [parentKey])
        XCTAssertEqual(
            ConversationListItem.entries(chats: chats, threads: threads, scope: .dms).map(\.id),
            [.init(chatID: "dm")])
        XCTAssertEqual(
            ConversationListItem.entries(chats: chats, threads: threads, scope: .threads).map(\.id),
            [threadKey])
        XCTAssertEqual(
            ConversationListItem.entries(
                chats: chats, threads: threads, scope: .threads, showThreadsInMessages: false
            ).map(\.id), [threadKey])
        let reordered = ConversationListItem.entries(
            chats: chats, threads: threads, scope: .messages,
            draftUpdatedAt: [parentKey: Date(timeIntervalSince1970: 60)])
        XCTAssertEqual(reordered.map(\.id), [parentKey, threadKey, .init(chatID: "dm")])
        XCTAssertEqual(
            ConversationListItem.entries(
                chats: chats, threads: threads, scope: .messages, archived: true
            ).map(\.id),
            [
                .init(chatID: "group", threadID: "2"), .init(chatID: "archived-dm"),
                .init(chatID: "archived"),
            ])
        XCTAssertEqual(
            ConversationListItem.entries(
                chats: chats, threads: threads, scope: .messages, archived: true,
                showThreadsInMessages: false
            ).map(\.id), [.init(chatID: "archived-dm"), .init(chatID: "archived")])
        XCTAssertEqual(
            ConversationListItem.entries(
                chats: chats, threads: threads, scope: .groups, archived: true
            ).map(\.id),
            [.init(chatID: "archived")])
        XCTAssertEqual(
            ConversationListItem.entries(
                chats: chats, threads: threads, scope: .dms, archived: true
            ).map(\.id),
            [.init(chatID: "archived-dm")])
    }

    func testAuthoritativeBadgesPrioritizeUnmutedAttentionAndKeepArchiveSeparate() {
        let summaries = [
            ConversationUnreadSummary(
                key: "groups", unreadAttentionCount: 5, unreadConversationCount: 80,
                unreadMessageCount: 99, unreadUnmutedAttentionCount: 0,
                unreadUnmutedConversationCount: 30, unreadUnmutedMessageCount: 40),
            ConversationUnreadSummary(
                key: "messages-with-threads", unreadAttentionCount: 5,
                unreadConversationCount: 90, unreadMessageCount: 100,
                unreadUnmutedAttentionCount: 2, unreadUnmutedConversationCount: 40,
                unreadUnmutedMessageCount: 50),
            ConversationUnreadSummary(
                key: "messages-with-threads-archived", unreadAttentionCount: 1,
                unreadConversationCount: 8, unreadMessageCount: 12,
                unreadUnmutedAttentionCount: 0, unreadUnmutedConversationCount: 0,
                unreadUnmutedMessageCount: 0),
        ]
        let active = ConversationTabBadges(summaries: summaries)
        XCTAssertEqual(active[.groups], 30)
        XCTAssertEqual(active.label(for: .groups), "30", "Muted mentions must not win.")
        XCTAssertEqual(active[.messages], 40)
        XCTAssertEqual(active.label(for: .messages), "@")
        XCTAssertNil(active.label(for: .dms), "Never derive missing summaries from loaded pages.")
        let archived = ConversationTabBadges(summaries: summaries, archived: true)
        XCTAssertEqual(archived[.messages], 8)
        XCTAssertEqual(archived.label(for: .messages), "@")
    }

    func testMessagePreferenceSelectsItsOwnServerSummaryAndAllViewsAreRequested() {
        let summaries = [
            ConversationUnreadSummary(
                key: "messages", unreadAttentionCount: 0, unreadConversationCount: 3,
                unreadMessageCount: 4, unreadUnmutedAttentionCount: 0,
                unreadUnmutedConversationCount: 2, unreadUnmutedMessageCount: 3),
            ConversationUnreadSummary(
                key: "threads", unreadAttentionCount: 0, unreadConversationCount: 7,
                unreadMessageCount: 9, unreadUnmutedAttentionCount: 0,
                unreadUnmutedConversationCount: 6, unreadUnmutedMessageCount: 8),
        ]
        let badges = ConversationTabBadges(summaries: summaries, showThreadsInMessages: false)
        XCTAssertEqual(badges[.messages], 2)
        XCTAssertEqual(badges[.threads], 6)
        XCTAssertEqual(Set(ConversationTabBadges.unreadViews.map(\.key)).count, 10)
        XCTAssertEqual(ConversationTabBadges(summaries: summaries)[.messages], 0)
    }

    func testRowAttentionUsesWireKindAndMutedBadgesRespectTimeBoundary() throws {
        let now = Date(timeIntervalSince1970: 100)
        for kind in [ChatKind.group, .dm] {
            let chat = ConversationListItem.chat(
                ChatListItem(
                    id: "chat", unreadCount: 0, unreadMentions: 2, unreadReactions: 3,
                    mutedUntil: now, archived: false, kind: kind))
            XCTAssertEqual(chat.unreadMentions, kind == .group ? 2 : 0)
            XCTAssertEqual(chat.unreadReactions, 3)
            XCTAssertFalse(chat.hasMutedBadges(now: now))
            XCTAssertTrue(chat.hasMutedBadges(now: now.addingTimeInterval(-1)))
            let archived = ConversationListItem.chat(
                ChatListItem(
                    id: "archived", unreadCount: 0, unreadMentions: 1,
                    unreadReactions: 1, archived: true, kind: kind))
            XCTAssertTrue(archived.hasMutedBadges(now: now))

            let root = try TimelineTestFixtures.message(id: 1, at: 1).replyPreview
            let thread = ConversationListItem.thread(
                ThreadListItem(
                    chatId: "unloaded-parent", chatName: "", threadRootMessage: root,
                    participants: [], replyCount: 0, lastReplyAt: now,
                    unreadCount: 0, unreadMentions: 2, unreadReactions: 3,
                    chatKind: kind, subscribedAt: now, archived: true))
            XCTAssertEqual(thread.unreadMentions, kind == .group ? 2 : 0)
            XCTAssertEqual(thread.unreadReactions, 3)
            XCTAssertTrue(thread.hasMutedBadges(now: now))
        }
    }

    func testPendingThreadRepliesStayInTheirTimelineThroughAcknowledgement() async throws {
        let store = ConversationMessageStore()
        for (id, threadID) in [("parent", nil), ("one", "one"), ("two", "two")]
            as [(String, String?)]
        {
            store.enqueue(
                PendingOutgoingMessage(
                    chatID: "chat", threadID: threadID, clientGeneratedID: id,
                    body: .init(messageType: .text, clientGeneratedId: id, message: id),
                    enqueuedAt: Date(), senderID: 1, state: .queued))
        }
        XCTAssertEqual(store.pending(chatID: "chat").map(\.clientGeneratedID), ["parent"])
        XCTAssertEqual(
            store.pending(chatID: "chat", threadID: "one").map(\.clientGeneratedID), ["one"])
        let acknowledged = try TimelineTestFixtures.message(
            id: 1, at: 1, clientGeneratedID: "one", fields: ["replyRootId": "one"])
        store.apply(.message(acknowledged))
        XCTAssertTrue(store.pending(chatID: "chat", threadID: "one").isEmpty)
        XCTAssertEqual(
            store.pending(chatID: "chat", threadID: "two").map(\.clientGeneratedID), ["two"])
        XCTAssertEqual(store.pending(chatID: "chat").map(\.clientGeneratedID), ["parent"])
    }
    func testMessagePreviewsExpandMentionsInSharedRenderer() throws {
        let message = try TimelineTestFixtures.message(
            id: 1, at: 1,
            text: "Hi 👋 @[uid:2], @[uid:9], @[uid:2], @[uid:nope]",
            fields: [
                "mentions": [
                    ["uid": 2, "gender": 0, "username": "Grace"],
                    ["uid": 2, "gender": 0, "username": "Ada"],
                    ["uid": 2, "gender": 0, "username": ""],
                ]
            ])
        let preview = message.replyPreview
        let group = ConversationListItem.chat(
            ChatListItem(
                id: "group", name: "Group", lastMessageAt: message.createdAt,
                unreadCount: 0, lastMessage: preview, archived: false, kind: .group))
        let expected = "Hi 👋 @Ada, @User 9, @Ada, @[uid:nope]"

        XCTAssertEqual(messagePreview(preview), expected)
        XCTAssertEqual(group.previewMessage, preview)
        XCTAssertEqual(group.previewSenderName(), "Ada")
    }

    func testMessagePreviewCollapsesNewlineRunsWithoutChangingBodyOrOrdinarySpaces() throws {
        let body = "First\nsecond\r\n\r\nthird\n\n\n@[uid:2]\u{2028}\u{2029}last  words"
        let message = try TimelineTestFixtures.message(
            id: 1, at: 1,
            fields: [
                "message": body,
                "mentions": [["uid": 2, "gender": 0, "username": "Ada\n\nLovelace"]],
            ])
        XCTAssertEqual(
            messagePreview(message.replyPreview), "First second third @Ada Lovelace last  words")
        XCTAssertEqual(
            message.replyPreview.message, body,
            "Normalization is presentation-only; retain the original text.")
    }

    func testThreadPreviewUsesLatestReplyThenRootMessageFallback() throws {
        let root = try TimelineTestFixtures.message(id: 1, at: 1, text: "Root message")
            .replyPreview
        let reply = try TimelineTestFixtures.message(id: 2, at: 2, text: "Latest reply")
            .replyPreview

        func thread(lastReply: MessagePreview?) -> ConversationListItem {
            .thread(
                ThreadListItem(
                    chatId: "chat", chatName: "Parent chat", threadRootMessage: root,
                    participants: [], lastReply: lastReply, replyCount: 1,
                    lastReplyAt: Date(timeIntervalSince1970: 2), unreadCount: 0,
                    subscribedAt: .distantPast, archived: false))
        }

        XCTAssertEqual(thread(lastReply: reply).title, "Root message")
        XCTAssertEqual(thread(lastReply: reply).previewMessage, reply)
        XCTAssertEqual(thread(lastReply: reply).previewSenderName(), "Ada")
        XCTAssertNil(thread(lastReply: reply).previewSenderName(parentKind: .dm))
        XCTAssertEqual(thread(lastReply: nil).previewMessage, root)
    }

    func testFormattedSummariesKeepStylesAndConcealSpoilersWithoutEmbeddedActions() throws {
        let message = try TimelineTestFixtures.message(
            id: 1, at: 1,
            text:
                "**bold** __italic__ ~~strike~~ `code` [label](https://example.com) ||secret|| @[uid:2]",
            fields: ["mentions": [["uid": 2, "gender": 0, "username": "**Ada**"]]])
        let preview = message.replyPreview
        let nodes = MessageSummaryContent.summary(preview)
        let attributed = MessageSummaryContent.attributedText(
            nodes, mentions: preview.mentions, font: .systemFont(ofSize: 15), color: .black)
        XCTAssertEqual(attributed.string, "bold italic strike code label secret @**Ada**")
        XCTAssertFalse(messagePreview(preview).contains("secret"))
        XCTAssertTrue(messagePreview(preview).hasSuffix("@**Ada**"))

        let source = attributed.string as NSString
        for value in ["bold", "italic", "code"] {
            let range = source.range(of: value)
            XCTAssertNotEqual(
                attributed.attribute(.font, at: range.location, effectiveRange: nil)
                    as? BubbleNativeFont,
                BubbleNativeFont.systemFont(ofSize: 15))
        }
        let link = source.range(of: "label")
        XCTAssertNotNil(
            attributed.attribute(.underlineStyle, at: link.location, effectiveRange: nil))
        let strike = source.range(of: "strike")
        XCTAssertNotNil(
            attributed.attribute(.strikethroughStyle, at: strike.location, effectiveRange: nil))
        let secret = source.range(of: "secret")
        XCTAssertNotNil(
            attributed.attribute(.bubbleSpoiler, at: secret.location, effectiveRange: nil))
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) {
            value, _, _ in XCTAssertNil(value)
        }
        let layout = MessageSummaryLayout()
        layout.update(attributed, lineLimit: 1)
        XCTAssertTrue(layout.hasSpoilers)
        XCTAssertTrue(layout.manager.revealedSpoilers.isEmpty)
    }

}

@MainActor
enum ScopeTestFixtures {
    static func thread(
        chatID: String = "chat", id: UInt64, at: TimeInterval = 40, archived: Bool = false,
        unreadCount: Int64 = 0
    ) throws -> ThreadListItem {
        let message = try TimelineTestFixtures.message(id: id, chatID: chatID, at: 1)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let preview = try decoder.decode(MessagePreview.self, from: encoder.encode(message))
        return ThreadListItem(
            chatId: chatID, chatName: "Parent", chatAvatar: nil, threadRootMessage: preview,
            participants: [], lastReply: nil, replyCount: 1,
            lastReplyAt: Date(timeIntervalSince1970: at),
            unreadCount: unreadCount, lastReadMessageId: nil,
            subscribedAt: Date(timeIntervalSince1970: 0),
            archived: archived)
    }
}
