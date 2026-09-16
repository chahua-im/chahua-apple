import Foundation
import XCTest
@testable import chahua_apple
import ChahuaAPI

@MainActor
final class ChatStoreTests: XCTestCase {
    func testArchiveKeepsParentIndependentAndFencesStaleRefresh() async throws {
        let parent = ChatListItem(id: "chat", name: "Group", unreadCount: 7, archived: false, kind: .group)
        let thread = try ScopeTestFixtures.thread(chatID: "chat", id: "root")
        let api = FakeChatAPI(threadResults: [.success(.init(threads: [thread]))],
                              archiveResults: [.success(()), .success(()), .failure(APIError.unavailable), .success(()), .success(())],
                              suspendChatRequests: true)
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        defer { store.cancelRealtimeRecovery() }
        let initial = Task { await store.loadActiveChats() }
        await api.waitForChatRequest()
        await api.resumeChatRequest(with: .success(.init(chats: [parent])))
        await initial.value
        await store.loadActiveThreads()

        await store.performListAction(.archive, conversation: .init(chatID: "chat", threadID: "root"))
        XCTAssertTrue(store.state.threads.isEmpty)
        XCTAssertEqual(store.state.archivedThreads.first?.threadRootMessage.id, "root")
        XCTAssertEqual(store.state.archivedThreads.first?.archived, true)
        XCTAssertEqual(store.state.chats, [parent])

        let refresh = Task { await store.refreshActiveChats() }
        await api.waitForChatRequest()
        await store.performListAction(.archive, conversation: .init(chatID: "chat"))
        XCTAssertTrue(store.state.chats.isEmpty)
        await api.resumeChatRequest(with: .success(.init(chats: [parent])))
        await api.waitForChatRequest()
        XCTAssertTrue(store.state.chats.isEmpty)
        await api.resumeChatRequest(with: .success(.init(chats: [])))
        await refresh.value
        XCTAssertTrue(store.state.chats.isEmpty)
        XCTAssertEqual(store.state.archivedChats.first?.id, "chat")
        XCTAssertEqual(store.state.archivedChats.first?.archived, true)
        XCTAssertNotNil(store.state.archivedChats.first?.mutedUntil)
        await store.performListAction(.unarchive, conversation: .init(chatID: "chat"))
        XCTAssertTrue(store.state.chats.isEmpty)
        XCTAssertEqual(store.state.archivedChats.first?.id, "chat")
        XCTAssertNotNil(store.listActionError)

        await store.performListAction(.unarchive, conversation: .init(chatID: "chat"))
        XCTAssertEqual(store.state.chats, [parent])
        XCTAssertTrue(store.state.archivedChats.isEmpty)
        XCTAssertEqual(store.state.archivedThreads.first?.threadRootMessage.id, "root")
        await store.performListAction(.unarchive, conversation: .init(chatID: "chat", threadID: "root"))
        XCTAssertEqual(store.state.threads, [thread])
        XCTAssertTrue(store.state.archivedThreads.isEmpty)
        XCTAssertEqual(store.state.chats, [parent])
        XCTAssertNil(store.listActionError)
    }

    func testMarkUnreadRewindsOnlyItsArchivedChatAndPreservesStateOnFailure() async throws {
        let message = try TimelineTestFixtures.message(id: "latest", at: 2)
        let chat = ChatListItem(id: "chat", unreadCount: 0, lastReadMessageId: message.id,
                                lastMessage: message.replyPreview, archived: true, kind: .group)
        let other = ChatListItem(id: "other", unreadCount: 4, archived: false, kind: .group)
        let thread = try ScopeTestFixtures.thread(chatID: "chat", id: "root")
        let api = FakeChatAPI(
            chatResults: [.success(.init(chats: [other]))],
            threadResults: [.success(.init(threads: [thread]))],
            archivedChatResults: [.success(.init(chats: [chat]))],
            readResults: [.success(.init(lastReadMessageId: message.id, unreadCount: 0))],
            unreadResults: [.failure(APIError.unavailable), .success(.init(lastReadMessageId: nil, unreadCount: 1))])
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        defer { store.cancelRealtimeRecovery() }
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: true, source: store, messageStore: store.conversationMessages)
        store.registerTimeline(model)
        var readNotifications: [String] = []
        store.onNotificationRead = { _, id in readNotifications.append(id) }
        await store.loadActiveChats()
        await store.loadActiveThreads()
        await store.loadArchivedChats()
        await store.performListAction(.markUnread, conversation: .init(chatID: "chat"))
        XCTAssertEqual(store.state.archivedChats, [chat])
        XCTAssertEqual(store.state.chats, [other])
        XCTAssertEqual(model.jumpUnreadCount, 0)
        XCTAssertNotNil(store.listActionError)

        await store.performListAction(.markUnread, conversation: .init(chatID: "chat"))
        XCTAssertNil(store.state.archivedChats.first?.lastReadMessageId)
        XCTAssertEqual(store.state.archivedChats.first?.unreadCount, 1)
        XCTAssertEqual(model.jumpUnreadCount, 1)
        XCTAssertEqual(store.state.chats.last, other)
        XCTAssertEqual(store.state.threads, [thread])
        XCTAssertTrue(readNotifications.isEmpty)
        XCTAssertNil(store.listActionError)

        await store.performListAction(.markRead, conversation: .init(chatID: "chat"))
        XCTAssertEqual(store.state.archivedChats.first?.unreadCount, 0)
        XCTAssertEqual(model.jumpUnreadCount, 0)
        XCTAssertEqual(readNotifications, [message.id])
    }

    func testReadResponseUpdatesOnlyItsArchivedConversationBadge() async throws {
        let parent = ChatListItem(id: "chat", name: "Group", unreadCount: 7, archived: true, kind: .group)
        let thread = try ScopeTestFixtures.thread(chatID: "chat", id: "root", archived: true)
        let api = FakeChatAPI(
            archivedChatResults: [.success(.init(chats: [parent]))],
            archivedThreadResults: [.success(.init(threads: [thread]))],
            readResults: [.success(.init(lastReadMessageId: "reply", unreadCount: 0)),
                          .success(.init(lastReadMessageId: "message", unreadCount: 2)),
                          .success(.init(lastReadMessageId: "unlisted-reply", unreadCount: 3))])
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let parentModel = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: true, source: store, messageStore: store.conversationMessages)
        let threadModel = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: true, source: store,
            messageStore: store.conversationMessages, threadID: "root")
        let unlistedModel = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: true, source: store,
            messageStore: store.conversationMessages, threadID: "unlisted")
        for model in [parentModel, threadModel, unlistedModel] { store.registerTimeline(model) }
        await store.loadArchivedChats()
        await store.loadArchivedThreads()
        let resolvedParent = try await store.chatForThread(thread)
        XCTAssertEqual(resolvedParent, parent)
        XCTAssertEqual(parentModel.jumpUnreadCount, 7)
        XCTAssertEqual(threadModel.jumpUnreadCount, thread.unreadCount)
        try await store.markRead(chatID: "chat", threadID: "root", messageID: "reply")
        XCTAssertEqual(store.state.archivedThreads.first?.lastReadMessageId, "reply")
        XCTAssertEqual(store.state.archivedThreads.first?.unreadCount, 0)
        XCTAssertEqual(store.state.archivedChats.first, parent)
        XCTAssertEqual(parentModel.jumpUnreadCount, 7)
        XCTAssertEqual(threadModel.jumpUnreadCount, 0)
        try await store.markRead(chatID: "chat", threadID: nil, messageID: "message")
        XCTAssertEqual(store.state.archivedChats.first?.lastReadMessageId, "message")
        XCTAssertEqual(store.state.archivedChats.first?.unreadCount, 2)
        XCTAssertEqual(store.state.archivedThreads.first?.lastReadMessageId, "reply")
        XCTAssertEqual(parentModel.jumpUnreadCount, 2)
        try await store.markRead(chatID: "chat", threadID: "unlisted", messageID: "unlisted-reply")
        XCTAssertEqual(unlistedModel.jumpUnreadCount, 3)
        XCTAssertEqual(threadModel.jumpUnreadCount, 0)
        XCTAssertEqual(parentModel.jumpUnreadCount, 2)
    }

    func testReadReceiptFencesListSnapshotStartedBeforeAcknowledgement() async throws {
        let api = FakeChatAPI(readResults: [.success(.init(lastReadMessageId: "read", unreadCount: 0))], suspendChatRequests: true)
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let refresh = Task { await store.refreshActiveChats() }
        await api.waitForChatRequest()
        try await store.markRead(chatID: "chat", threadID: nil, messageID: "read")
        await api.resumeChatRequest(with: .success(.init(chats: [
            ChatListItem(id: "chat", unreadCount: 9, archived: false, kind: .group)
        ])))
        await api.waitForChatRequest()
        XCTAssertTrue(store.state.chats.isEmpty)
        await api.resumeChatRequest(with: .success(.init(chats: [
            ChatListItem(id: "chat", unreadCount: 0, lastReadMessageId: "read", archived: false, kind: .group)
        ])))
        await refresh.value
        XCTAssertEqual(store.state.chats.first?.unreadCount, 0)
        XCTAssertEqual(store.state.chats.first?.lastReadMessageId, "read")
    }

    func testLoadActiveChatsPreservesServerOrder() async {
        let api = FakeChatAPI(chatResults: [.success(ListChatsResponse(chats: [chat(id: "2"), chat(id: "1")]))])
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})

        await store.loadActiveChats()

        XCTAssertEqual(store.state.chatListLoadPhase, .loaded)
        XCTAssertEqual(store.state.chats.map(\.id), ["2", "1"])
        let recordedQueries = await api.recordedChatQueries()
        XCTAssertEqual(recordedQueries, [ListChatsQuery(archived: false)])
    }

    func testLoadFailureCanRetry() async {
        let api = FakeChatAPI(chatResults: [.failure(FakeChatAPIError.failed), .success(ListChatsResponse(chats: []))])
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})

        await store.loadActiveChats()
        XCTAssertEqual(store.state.chatListLoadPhase, .failed)

        await store.loadActiveChats()
        XCTAssertEqual(store.state.chatListLoadPhase, .loaded)
        XCTAssertTrue(store.state.chats.isEmpty)
    }

    func testInvalidTokenEndsSession() async {
        let api = FakeChatAPI(chatResults: [.failure(APIError.invalidToken)])
        var invalidTokenCalls = 0
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: { invalidTokenCalls += 1 })

        await store.loadActiveChats()

        XCTAssertEqual(store.state.chatListLoadPhase, .failed)
        XCTAssertEqual(invalidTokenCalls, 1)
    }


    func testResetClearsStateAndIgnoresPriorRequest() async {
        let api = FakeChatAPI(suspendChatRequests: true)
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})

        let loadTask = Task { await store.loadActiveChats() }
        await api.waitForChatRequest()
        store.reset()
        await api.resumeChatRequest(with: .success(ListChatsResponse(chats: [chat(id: "stale")])))
        await loadTask.value

        XCTAssertEqual(store.state.chatListLoadPhase, .idle)
        XCTAssertTrue(store.state.chats.isEmpty)
    }

    private func chat(id: String) -> ChatListItem {
        ChatListItem(id: id, name: "Chat \(id)", unreadCount: 0, archived: false, kind: .group)
    }

    func testRefreshReplacesLoadedAndEmptyListsAndRetainsRowsOnFailure() async {
        let api = FakeChatAPI(chatResults: [
            .success(ListChatsResponse(chats: [])),
            .success(ListChatsResponse(chats: [chat(id: "2")], nextCursor: "next")),
            .success(ListChatsResponse(chats: [chat(id: "2"), chat(id: "1")])),
            .failure(FakeChatAPIError.failed),
        ])
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        await store.loadActiveChats()
        await store.refreshActiveChats()
        XCTAssertEqual(store.state.chats.map(\.id), ["2", "1"])
        await store.refreshActiveChats()
        XCTAssertEqual(store.state.chats.map(\.id), ["2", "1"])
        XCTAssertEqual(store.state.chatListLoadPhase, .loaded)
        XCTAssertTrue(store.state.chatListRefreshFailed)
    }

    func testArchivedPaginationAndFailedRefreshPreserveBothModes() async throws {
        let active = chat(id: "active")
        let activeThread = try ScopeTestFixtures.thread(id: "active")
        let first = ChatListItem(id: "first", unreadCount: 2, archived: true, kind: .group)
        let second = ChatListItem(id: "second", unreadCount: 1, archived: true, kind: .group)
        let firstThread = try ScopeTestFixtures.thread(id: "first", archived: true)
        let secondThread = try ScopeTestFixtures.thread(id: "second", archived: true)
        let api = FakeChatAPI(
            chatResults: [.success(.init(chats: [active]))],
            threadResults: [.success(.init(threads: [activeThread]))],
            archivedChatResults: [
                .failure(APIError.unavailable),
                .success(.init(chats: [first], nextCursor: "next")),
                .success(.init(chats: [first, second])),
                .success(.init(chats: [second], nextCursor: "partial")),
                .failure(APIError.unavailable),
            ],
            archivedThreadResults: [
                .success(.init(threads: [firstThread], nextCursor: "next")),
                .success(.init(threads: [firstThread, secondThread])),
                .failure(APIError.unavailable),
            ])
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        await store.refreshActiveConversations()
        await store.loadArchivedChats()
        XCTAssertEqual(store.state.archivedChatListLoadPhase, .failed)
        XCTAssertEqual(store.state.chats, [active])
        XCTAssertEqual(store.state.threads, [activeThread])

        await store.loadArchivedChats()
        await store.loadArchivedThreads()
        XCTAssertEqual(store.state.archivedChats, [first, second])
        XCTAssertEqual(store.state.archivedThreads, [firstThread, secondThread])
        await store.refreshArchivedConversations()
        XCTAssertEqual(store.state.archivedChats, [first, second])
        XCTAssertEqual(store.state.archivedThreads, [firstThread, secondThread])
        XCTAssertEqual(store.state.archivedChatListLoadPhase, .loaded)
        XCTAssertEqual(store.state.archivedThreadListLoadPhase, .loaded)
        XCTAssertTrue(store.state.archivedChatListRefreshFailed)
        XCTAssertTrue(store.state.archivedThreadListRefreshFailed)
        XCTAssertEqual(store.state.chats, [active])
        XCTAssertEqual(store.state.threads, [activeThread])
        XCTAssertFalse(store.state.chatListRefreshFailed)
        XCTAssertFalse(store.state.threadListRefreshFailed)
    }

    func testUnarchiveFencesArchivedSnapshotAndUnmuteAlsoRestoresChat() async throws {
        let archived = ChatListItem(id: "chat", unreadCount: 3, mutedUntil: .distantFuture, archived: true, kind: .group)
        let api = FakeChatAPI(archiveResults: [.success(())], unmuteResults: [.success(())],
                              suspendArchivedChatRequests: true)
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        defer { store.cancelRealtimeRecovery() }
        let initial = Task { await store.loadArchivedChats() }
        await api.waitForChatRequest()
        await api.resumeChatRequest(with: .success(.init(chats: [archived])))
        await initial.value
        let refresh = Task { await store.refreshArchivedChats() }
        await api.waitForChatRequest()
        await store.performListAction(.unarchive, conversation: .init(chatID: "chat"))
        XCTAssertEqual(store.state.chats.first?.id, "chat")
        XCTAssertEqual(store.state.chats.first?.archived, false)
        XCTAssertNil(store.state.chats.first?.mutedUntil)
        XCTAssertTrue(store.state.archivedChats.isEmpty)
        await api.resumeChatRequest(with: .success(.init(chats: [archived])))
        await api.waitForChatRequest()
        XCTAssertTrue(store.state.archivedChats.isEmpty)
        await api.resumeChatRequest(with: .success(.init(chats: [])))
        await refresh.value

        await store.applyRealtimeEvent(.chatArchiveStateChanged(.init(
            chatId: "chat", archived: true, mutedUntil: .distantFuture)), currentUserID: 1)
        XCTAssertTrue(store.state.chats.isEmpty)
        XCTAssertEqual(store.state.archivedChats, [archived])
        await store.performListAction(.unmute, conversation: .init(chatID: "chat"))
        XCTAssertTrue(store.state.archivedChats.isEmpty)
        XCTAssertEqual(store.state.chats.first?.unreadCount, 3)
        XCTAssertEqual(store.state.chats.first?.archived, false)
        XCTAssertNil(store.state.chats.first?.mutedUntil)
    }

    func testResetIgnoresArchivedRequestErrorFromPreviousSession() async {
        let api = FakeChatAPI(suspendArchivedChatRequests: true)
        var expired = false
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: { expired = true })
        let load = Task { await store.loadArchivedChats() }
        await api.waitForChatRequest()
        store.reset()
        await api.resumeChatRequest(with: .failure(APIError.invalidToken))
        await load.value
        XCTAssertFalse(expired)
        XCTAssertEqual(store.state.archivedChatListLoadPhase, .idle)
        XCTAssertFalse(store.state.isRefreshingArchivedChats)
        XCTAssertTrue(store.state.archivedChats.isEmpty)
    }

    func testRepeatedCursorRetainsPreviousSnapshot() async {
        let api = FakeChatAPI(chatResults: [
            .success(ListChatsResponse(chats: [chat(id: "original")])),
            .success(ListChatsResponse(chats: [chat(id: "partial")], nextCursor: "same")),
            .success(ListChatsResponse(chats: [], nextCursor: "same")),
        ])
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        await store.loadActiveChats()
        await store.refreshActiveChats()
        XCTAssertEqual(store.state.chats.map(\.id), ["original"])
        XCTAssertTrue(store.state.chatListRefreshFailed)
    }

    func testEventDuringRefreshRequiresTrailingSnapshot() async throws {
        let api = FakeChatAPI(suspendChatRequests: true)
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let load = Task { await store.refreshActiveChats() }
        await api.waitForChatRequest()
        let event = try JSONDecoder().decode(
            RealtimeServerEvent.self,
            from: Data(#"{"type":"chatArchiveStateChanged","payload":{"chatId":"1","archived":true}}"#.utf8)
        )
        await store.applyRealtimeEvent(event, currentUserID: 1)
        await api.resumeChatRequest(with: .success(ListChatsResponse(chats: [chat(id: "old")])))
        await api.waitForChatRequest()
        await api.resumeChatRequest(with: .success(ListChatsResponse(chats: [chat(id: "new")])))
        await load.value
        XCTAssertEqual(store.state.chats.map(\.id), ["new"])
    }

    func testOldSessionErrorCannotExpireReplacementSession() async {
        let api = FakeChatAPI(suspendChatRequests: true)
        var expired = false
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: { expired = true })
        let load = Task { await store.refreshActiveChats() }
        await api.waitForChatRequest()
        store.reset()
        await api.resumeChatRequest(with: .failure(APIError.invalidToken))
        await load.value
        XCTAssertFalse(expired)
        XCTAssertEqual(store.state.chatListLoadPhase, .idle)
    }

    func testForegroundRefreshDoesNotReuseCanceledBackgroundSnapshot() async {
        let api = FakeChatAPI(suspendChatRequests: true)
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let oldRefresh = Task { await store.refreshActiveChats() }
        await api.waitForChatRequest()
        store.cancelRealtimeRecovery()
        await api.resumeChatRequest(with: .success(ListChatsResponse(chats: [chat(id: "stale")])))
        await oldRefresh.value
        XCTAssertTrue(store.state.chats.isEmpty)
        let foregroundRefresh = Task { await store.refreshActiveChats() }
        await api.waitForChatRequest()
        await api.resumeChatRequest(with: .success(ListChatsResponse(chats: [chat(id: "fresh")])))
        await foregroundRefresh.value
        XCTAssertEqual(store.state.chats.map(\.id), ["fresh"])
    }

    func testDeletionFailureRetainsContentAndSuccessRedactsSharedDraftReferences() async throws {
        let message = try TimelineTestFixtures.message(id: "target", at: 1, text: "private content")
        let api = FakeChatAPI(
            messageResults: ["chat": [.success(try TimelineTestFixtures.page([message]))]],
            deleteResults: [.failure(FakeChatAPIError.failed), .success(())])
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        defer { store.reset() }
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: true, source: store, messageStore: store.conversationMessages)
        await model.loadInitial()
        store.drafts.setDraftReply(message.replyPreview, chatID: "chat")
        store.drafts.setDraftReply(message.replyPreview, chatID: "chat", threadID: "thread")
        let failed = await store.deleteMessage(message)
        XCTAssertFalse(failed)
        XCTAssertEqual(store.drafts.draftReply(chatID: "chat"), message.replyPreview)
        let original = model.rows.compactMap { row -> MessageResponse? in
            guard case .message(let row) = row else { return nil }
            return row.entry.remoteMessage
        }.first
        XCTAssertEqual(original?.message, "private content")
        XCTAssertEqual(original?.isDeleted, false)

        let deleted = await store.deleteMessage(message)
        XCTAssertTrue(deleted)
        let redacted = model.rows.compactMap { row -> MessageResponse? in
            guard case .message(let row) = row else { return nil }
            return row.entry.remoteMessage
        }.first
        XCTAssertEqual(redacted?.isDeleted, true)
        XCTAssertNil(redacted?.message)
        XCTAssertEqual(store.drafts.draftReply(chatID: "chat"), message.replyPreview.redactedForDeletion())
        XCTAssertEqual(store.drafts.draftReply(chatID: "chat", threadID: "thread"), message.replyPreview.redactedForDeletion())
    }

    func testDraftSubmissionIsDurableAndSharedAcrossStoreRestoration() async throws {
        let api = FakeChatAPI()
        let queue = testOutgoingQueue(apiClient: api)
        let store = ChatStore(apiClient: api, outgoingQueue: queue, onInvalidToken: {})
        await queue.activate(uid: 1)
        store.drafts.setDraftText("  hello\n世界  ", chatID: "chat")
        await store.drafts.flushDraft(chatID: "chat")
        let submitted = await store.drafts.submitDraft(chatID: "chat")
        XCTAssertTrue(submitted)
        XCTAssertEqual(store.drafts.draftText(chatID: "chat"), "")
        XCTAssertEqual(queue.pendingMessages(chatID: "chat").map(\.text), ["hello\n世界"])
        store.drafts.setDraftText("unsent draft", chatID: "other")
        await store.drafts.flushDraft(chatID: "other")
        await queue.deactivate()
        store.reset()
        await queue.activate(uid: 1)
        XCTAssertEqual(store.drafts.draftText(chatID: "other"), "unsent draft")
        XCTAssertEqual(store.drafts.draftText(chatID: "chat"), "")
        let entries = store.conversationMessages.projection(for: "chat", remoteMessages: [], includePendingOutgoing: true).entries
        XCTAssertEqual(entries.count, 1)
        await queue.deactivate()
    }

    func testTypingBeforeStorageRestorationIsNotOverwritten() async throws {
        let api = FakeChatAPI()
        let queue = testOutgoingQueue(apiClient: api)
        let store = ChatStore(apiClient: api, outgoingQueue: queue, onInvalidToken: {})
        await queue.activate(uid: 1)
        try await queue.saveDraft(chatID: "chat", text: "old persisted", editRevision: 20, updatedAt: Date())
        await queue.deactivate()
        store.reset()
        store.drafts.setDraftText("new typing", chatID: "chat")
        await queue.activate(uid: 1)
        XCTAssertEqual(store.drafts.draftText(chatID: "chat"), "new typing")
        await store.drafts.flushDraft(chatID: "chat")
        await queue.deactivate()
        store.reset()
        await queue.activate(uid: 1)
        XCTAssertEqual(store.drafts.draftText(chatID: "chat"), "new typing")
        await queue.deactivate()
    }

    func testCompositionCancelsDebouncedSaveAndResumesWhenCommittedTextIsUnchanged() async throws {
        let h = try await openDraftHarness()
        h.store.drafts.setDraftText("already committed", chatID: "chat")
        await Task.yield()
        h.store.drafts.setDraftComposing(true, chatID: "chat")

        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(h.probe.draftWriteAttempts, 0)
        let duringComposition = try await h.localStore.restore()
        XCTAssertTrue(duringComposition.isEmpty)

        h.store.drafts.setDraftText("already committed", chatID: "chat")
        h.store.drafts.setDraftComposing(false, chatID: "chat")
        try await waitForPersistedDraft("already committed", in: h)
    }

    func testCompositionDefersExplicitBackgroundAndRetryFlushesAndRefusesSubmission() async throws {
        let h = try await openDraftHarness()
        h.store.drafts.setDraftText("last persisted", chatID: "chat")
        await h.store.drafts.flushDraft(chatID: "chat")
        h.probe.draftWriteAttempts = 0
        h.probe.failDraftWrites = true
        h.store.drafts.setDraftComposing(true, chatID: "chat")
        h.store.drafts.setDraftText("final committed text", chatID: "chat")

        await h.store.drafts.flushDraft(chatID: "chat")
        await h.store.retryLocalStorage()
        h.store.setForegroundActive(false)
        let submitted = await h.store.drafts.submitDraft(chatID: "chat")
        try await Task.sleep(for: .milliseconds(650))

        XCTAssertFalse(submitted)
        XCTAssertEqual(h.probe.draftWriteAttempts, 0)
        XCTAssertEqual(h.probe.enqueueAttempts, 0)
        XCTAssertFalse(h.store.drafts.draftSaveFailed)
        XCTAssertEqual(h.queue.storageState, .ready)
        let duringComposition = try await h.localStore.restore()
        XCTAssertEqual(duringComposition.first?.draft.text, "last persisted")
        XCTAssertTrue(duringComposition.flatMap(\.outgoing).isEmpty)

        h.probe.failDraftWrites = false
        h.store.drafts.setDraftComposing(false, chatID: "chat")
        try await waitForPersistedDraft("final committed text", in: h)
    }

    func testCompositionCommitAutosavesFinalTextWithoutExplicitFlush() async throws {
        let h = try await openDraftHarness()
        h.store.drafts.setDraftText("previous", chatID: "chat")
        await h.store.drafts.flushDraft(chatID: "chat")
        h.probe.draftWriteAttempts = 0
        h.store.drafts.setDraftComposing(true, chatID: "chat")
        h.store.drafts.setDraftText("你好，世界", chatID: "chat")

        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(h.probe.draftWriteAttempts, 0)
        let duringComposition = try await h.localStore.restore()
        XCTAssertEqual(duringComposition.first?.draft.text, "previous")

        h.store.drafts.setDraftComposing(false, chatID: "chat")
        try await waitForPersistedDraft("你好，世界", in: h)
    }

    func testResetClearsCompositionAndCancelsDeferredSaveAcrossSessionRestoration() async throws {
        let h = try await openDraftHarness()
        h.store.drafts.setDraftComposing(true, chatID: "chat")
        h.store.drafts.setDraftText("discarded session", chatID: "chat")
        await h.store.drafts.flushDraft(chatID: "chat")
        h.store.drafts.setDraftComposing(false, chatID: "chat")
        h.store.reset()
        await h.queue.deactivate()
        await h.queue.activate(uid: 1)
        XCTAssertEqual(h.probe.draftWriteAttempts, 0)

        h.store.drafts.setDraftComposing(true, chatID: "chat")
        h.store.drafts.setDraftText("another discarded session", chatID: "chat")
        await h.store.drafts.flushDraft(chatID: "chat")
        h.store.reset()
        h.store.drafts.setDraftText("replacement session", chatID: "chat")
        try await waitForPersistedDraft("replacement session", in: h)

        let submitted = await h.store.drafts.submitDraft(chatID: "chat")
        XCTAssertTrue(submitted)
        let persisted = try await h.localStore.restore()
        XCTAssertEqual(persisted.first?.draft.text, "")
        XCTAssertEqual(persisted.flatMap(\.outgoing).map(\.text), ["replacement session"])
    }

    func testEditsDuringLocalEnqueueSurviveItsClearedSnapshotAndAutosave() async throws {
        let h = try await openDraftHarness()
        let reply = try TimelineTestFixtures.message(id: "target", at: 0).replyPreview
        h.store.drafts.setDraftReply(reply, chatID: "chat")
        h.store.drafts.setDraftText("send this", chatID: "chat")
        h.probe.onEnqueue = {
            h.store.drafts.setDraftText("next draft", chatID: "chat")
            h.store.drafts.setDraftReply(nil, chatID: "chat")
            await h.store.drafts.flushDraft(chatID: "chat")
            let duplicate = await h.store.drafts.submitDraft(chatID: "chat")
            XCTAssertFalse(duplicate)
        }
        defer { h.probe.onEnqueue = nil }

        let submitted = await h.store.drafts.submitDraft(chatID: "chat")
        XCTAssertTrue(submitted)
        XCTAssertEqual(h.store.drafts.draftText(chatID: "chat"), "next draft")
        XCTAssertNil(h.store.drafts.draftReply(chatID: "chat"))
        try await waitForPersistedDraft("next draft", in: h)
        let persisted = try await h.localStore.restore()
        XCTAssertEqual(persisted.flatMap(\.outgoing).map(\.text), ["send this"])
        XCTAssertEqual(persisted.flatMap(\.outgoing).first?.replyToMessage, reply)
        XCTAssertNil(persisted.first?.draft.replyToMessage)
    }

    func testFailedLocalEnqueueKeepsDraftAndRetryEnqueuesExactlyOnce() async throws {
        let h = try await openDraftHarness()
        let reply = try TimelineTestFixtures.message(id: "target", at: 0).replyPreview
        h.store.drafts.setDraftReply(reply, chatID: "chat")
        h.store.drafts.setDraftText("keep this", chatID: "chat")
        await h.store.drafts.flushDraft(chatID: "chat")
        h.probe.failEnqueue = true
        let failed = await h.store.drafts.submitDraft(chatID: "chat")
        XCTAssertFalse(failed)
        XCTAssertEqual(h.store.drafts.draftText(chatID: "chat"), "keep this")
        XCTAssertEqual(h.store.drafts.draftReply(chatID: "chat"), reply)
        XCTAssertTrue(h.store.drafts.draftSaveFailed)
        XCTAssertFalse(h.store.drafts.committingDrafts.contains(ConversationKey(chatID: "chat")))
        XCTAssertTrue(h.queue.pendingMessages(chatID: "chat").isEmpty)
        let afterFailure = try await h.localStore.restore()
        XCTAssertEqual(afterFailure.first?.draft.text, "keep this")
        XCTAssertEqual(afterFailure.first?.draft.replyToMessage, reply)
        XCTAssertTrue(afterFailure.flatMap(\.outgoing).isEmpty)

        h.probe.failEnqueue = false
        await h.store.retryLocalStorage()
        let retried = await h.store.drafts.submitDraft(chatID: "chat")
        XCTAssertTrue(retried)
        XCTAssertEqual(h.store.drafts.draftText(chatID: "chat"), "")
        XCTAssertNil(h.store.drafts.draftReply(chatID: "chat"))
        XCTAssertFalse(h.store.drafts.draftSaveFailed)
        let afterRetry = try await h.localStore.restore()
        XCTAssertEqual(afterRetry.flatMap(\.outgoing).map(\.text), ["keep this"])
        XCTAssertNil(afterRetry.first?.draft.replyToMessage)
        XCTAssertEqual(afterRetry.flatMap(\.outgoing).first?.replyToMessage, reply)
    }

    func testReplyOnlyDraftRestoresAndLocalReplyChangesSurviveStaleSnapshots() async throws {
        let h = try await openDraftHarness()
        let original = try TimelineTestFixtures.message(id: "original", at: 0).replyPreview
        let replacement = try TimelineTestFixtures.message(id: "replacement", at: 1).replyPreview
        h.store.drafts.setDraftReply(original, chatID: "chat")
        await h.store.drafts.flushAll()
        await h.queue.deactivate()
        h.store.reset()
        await h.queue.activate(uid: 1)
        XCTAssertEqual(h.store.drafts.draftReply(chatID: "chat"), original)
        XCTAssertEqual(h.store.drafts.draftText(chatID: "chat"), "")

        h.store.drafts.setDraftReply(replacement, chatID: "chat")
        let stale = try XCTUnwrap(h.queue.snapshots[ConversationKey(chatID: "chat")])
        h.store.drafts.install(stale)
        XCTAssertEqual(h.store.drafts.draftReply(chatID: "chat"), replacement)
        await h.store.drafts.flushDraft(chatID: "chat")
        let replaced = try await h.localStore.restore()
        XCTAssertEqual(replaced.first?.draft.replyToMessage, replacement)

        h.store.drafts.setDraftText("keep text", chatID: "chat")
        h.store.drafts.setDraftReply(nil, chatID: "chat")
        h.store.drafts.install(try XCTUnwrap(h.queue.snapshots[ConversationKey(chatID: "chat")]))
        XCTAssertNil(h.store.drafts.draftReply(chatID: "chat"))
        XCTAssertEqual(h.store.drafts.draftText(chatID: "chat"), "keep text")
        await h.store.drafts.flushDraft(chatID: "chat")
        let canceled = try await h.localStore.restore()
        XCTAssertNil(canceled.first?.draft.replyToMessage)
        XCTAssertEqual(canceled.first?.draft.text, "keep text")
    }

    func testDeletedReplyTargetsStayRedactedAfterOutboxRefresh() async throws {
        let h = try await openDraftHarness()
        let target = try TimelineTestFixtures.message(id: "target", at: 0, text: "private content")
        h.store.drafts.setDraftReply(target.replyPreview, chatID: "chat")
        h.store.drafts.setDraftText("queued answer", chatID: "chat")
        let submitted = await h.store.drafts.submitDraft(chatID: "chat")
        XCTAssertTrue(submitted)
        h.store.drafts.setDraftReply(target.replyPreview, chatID: "chat")
        h.store.drafts.setDraftText("next answer", chatID: "chat")

        await h.store.applyRealtimeEvent(.messageDeleted(target), currentUserID: 1)
        let redacted = target.replyPreview.redactedForDeletion()
        XCTAssertEqual(h.store.drafts.draftReply(chatID: "chat"), redacted)
        XCTAssertEqual(h.store.drafts.draftText(chatID: "chat"), "next answer")
        await h.store.drafts.flushDraft(chatID: "chat")
        let refreshed = h.store.conversationMessages.projection(for: "chat", remoteMessages: [], includePendingOutgoing: true)
        guard case .pending(let pending) = try XCTUnwrap(refreshed.entries.first) else {
            return XCTFail("Expected the queued reply")
        }
        XCTAssertEqual(pending.replyToMessage, redacted)
        XCTAssertEqual(pending.body.replyToId, target.id)
        h.store.drafts.setDraftReply(target.replyPreview, chatID: "chat")
        XCTAssertEqual(h.store.drafts.draftReply(chatID: "chat"), redacted)
    }

    private func openDraftHarness() async throws -> DraftHarness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatDraft-\(UUID().uuidString)")
        let localStore = try await Task.detached { try ChahuaLocalStore(directory: root) }.value
        let api = FakeChatAPI()
        let probe = DraftStorageProbe()
        let queue = OutgoingMessageQueue(
            apiClient: api,
            localStoreFactory: { _ in localStore },
            onInvalidToken: {},
            beforeStorageOperation: { operation in try await probe.check(operation) }
        )
        let store = ChatStore(apiClient: api, outgoingQueue: queue, onInvalidToken: {})
        addTeardownBlock {
            await MainActor.run { store.reset() }
            await queue.deactivate()
            try FileManager.default.removeItem(at: root)
        }
        await queue.activate(uid: 1)
        return DraftHarness(store: store, queue: queue, localStore: localStore, probe: probe)
    }

    private func waitForPersistedDraft(
        _ text: String, in harness: DraftHarness, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while harness.queue.snapshots[ConversationKey(chatID: "chat")]?.draft.text != text {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out awaiting persisted draft", file: file, line: line)
                throw DraftStorageProbe.Failure.timeout
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        let persisted = try await harness.localStore.restore()
        XCTAssertEqual(persisted.first { $0.chatID == "chat" }?.draft.text, text, file: file, line: line)
    }

    func testHistoryIngressAcknowledgesDurablePendingBeforeReturningSnapshot() async throws {
        let api = FakeChatAPI()
        let queue = testOutgoingQueue(apiClient: api)
        let store = ChatStore(apiClient: api, outgoingQueue: queue, onInvalidToken: {})
        await queue.activate(uid: 1)
        store.drafts.setDraftText("delivered before response", chatID: "chat")
        let submitted = await store.drafts.submitDraft(chatID: "chat")
        XCTAssertTrue(submitted)
        let pending = try XCTUnwrap(queue.pendingMessages(chatID: "chat").first)
        let remote = try TimelineTestFixtures.message(id: "remote", at: 1, text: pending.text, clientGeneratedID: pending.clientGeneratedID)
        await api.appendMessageResult(chatID: "chat", page: try TimelineTestFixtures.page([remote]))
        let page = try await store.fetchMessages(chatID: "chat")
        XCTAssertTrue(queue.pendingMessages(chatID: "chat").isEmpty)
        let projection = store.conversationMessages.projection(for: "chat", remoteMessages: page.messages, includePendingOutgoing: true)
        XCTAssertEqual(projection.entries.map(\.stableKey), [.clientGenerated(pending.clientGeneratedID)])
        await queue.deactivate()
        store.reset()
        await queue.activate(uid: 1)
        XCTAssertTrue(queue.pendingMessages(chatID: "chat").isEmpty)
        await queue.deactivate()
    }
    func testThreadPaginationDeduplicatesAndFailedRefreshRetainsCompleteSnapshot() async throws {
        let first = try ScopeTestFixtures.thread(id: "first")
        let second = try ScopeTestFixtures.thread(id: "second")
        let api = FakeChatAPI(threadResults: [
            .success(.init(threads: [first], nextCursor: "next")),
            .success(.init(threads: [first, second])),
            .success(.init(threads: [second], nextCursor: "loop")),
            .success(.init(threads: [], nextCursor: "loop")),
        ])
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        await store.loadActiveThreads()
        XCTAssertEqual(store.state.threads, [first, second])
        await store.refreshActiveThreads()
        XCTAssertEqual(store.state.threads, [first, second])
        XCTAssertEqual(store.state.threadListLoadPhase, .loaded)
        XCTAssertTrue(store.state.threadListRefreshFailed)
    }

    func testChatsOnlyRefreshDoesNotDiscardPendingRealtimeMembershipRefresh() async throws {
        let first = try ScopeTestFixtures.thread(id: "first")
        let archived = try ScopeTestFixtures.thread(id: "first", archived: true)
        let api = FakeChatAPI(
            chatResults: [.success(.init(chats: [])), .success(.init(chats: []))],
            threadResults: [.success(.init(threads: [first])), .success(.init(threads: []))],
            archivedThreadResults: [.success(.init(threads: [archived]))])
        let store = ChatStore(apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        defer { store.cancelRealtimeRecovery() }
        await store.loadActiveThreads()
        await store.applyRealtimeEvent(.threadMembershipChanged(.init(
            threadRootId: "first", chatId: "chat")), currentUserID: 1)
        await store.refreshActiveChats()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.state.archivedThreads != [archived] || !store.state.threads.isEmpty {
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.state.archivedThreads, [archived])
        XCTAssertTrue(store.state.threads.isEmpty)
    }
}

private enum FakeChatAPIError: Error { case failed }

@MainActor
private struct DraftHarness {
    let store: ChatStore
    let queue: OutgoingMessageQueue
    let localStore: ChahuaLocalStore
    let probe: DraftStorageProbe
}

@MainActor
private final class DraftStorageProbe {
    enum Failure: Error { case storage, timeout }
    var draftWriteAttempts = 0
    var enqueueAttempts = 0
    var failDraftWrites = false
    var failEnqueue = false
    var onEnqueue: (() async -> Void)?

    func check(_ operation: OutgoingMessageQueue.StorageOperation) async throws {
        if operation == .enqueue {
            enqueueAttempts += 1
            await onEnqueue?()
            if failEnqueue { throw Failure.storage }
        }
        if operation == .saveDraft {
            draftWriteAttempts += 1
            if failDraftWrites { throw Failure.storage }
        }
    }
}

private actor FakeChatAPI: ChahuaAPIClient {
    var chatQueries: [ListChatsQuery] = []
    private var chatResults: [Result<ListChatsResponse, Error>]
    private var threadResults: [Result<ListThreadsResponse, Error>]
    private var archivedChatResults: [Result<ListChatsResponse, Error>]
    private var archivedThreadResults: [Result<ListThreadsResponse, Error>]
    private var readResults: [Result<ReadStateResponse, Error>]
    private var unreadResults: [Result<ReadStateResponse, Error>]
    private var archiveResults: [Result<Void, Error>]
    private var unmuteResults: [Result<Void, Error>]
    private var deleteResults: [Result<Void, Error>]
    private var messageResults: [String: [Result<ListMessagesResponse, Error>]]
    private let suspendChatRequests: Bool
    private let suspendArchivedChatRequests: Bool
    private var pendingChatRequest: CheckedContinuation<ListChatsResponse, Error>?
    private var chatRequestObserver: CheckedContinuation<Void, Never>?

    init(
        chatResults: [Result<ListChatsResponse, Error>] = [],
        threadResults: [Result<ListThreadsResponse, Error>] = [],
        archivedChatResults: [Result<ListChatsResponse, Error>] = [],
        archivedThreadResults: [Result<ListThreadsResponse, Error>] = [],
        messageResults: [String: [Result<ListMessagesResponse, Error>]] = [:],
        readResults: [Result<ReadStateResponse, Error>] = [],
        unreadResults: [Result<ReadStateResponse, Error>] = [],
        archiveResults: [Result<Void, Error>] = [],
        unmuteResults: [Result<Void, Error>] = [],
        deleteResults: [Result<Void, Error>] = [],
        suspendChatRequests: Bool = false,
        suspendArchivedChatRequests: Bool = false
    ) {
        self.chatResults = chatResults
        self.threadResults = threadResults
        self.archivedChatResults = archivedChatResults
        self.archivedThreadResults = archivedThreadResults
        self.messageResults = messageResults
        self.readResults = readResults
        self.unreadResults = unreadResults
        self.archiveResults = archiveResults
        self.unmuteResults = unmuteResults
        self.deleteResults = deleteResults
        self.suspendChatRequests = suspendChatRequests
        self.suspendArchivedChatRequests = suspendArchivedChatRequests
    }

    func appendMessageResult(chatID: String, page: ListMessagesResponse) {
        messageResults[chatID, default: []].append(.success(page))
    }

    func authenticate(candidateJWT: String) async throws -> MeResponse { throw APIError.unavailable }
    func createDevSession(uid: Int32, clientID: String) async throws -> String { throw APIError.unavailable }
    func me() async throws -> MeResponse { throw APIError.unavailable }
    func attachmentConfig() async throws -> AttachmentConfigResponse { throw APIError.unavailable }
    func requestAttachmentUpload(fileName: String, contentType: String, size: Int64, width: Int, height: Int, order: Int) async throws -> OutgoingUploadAllocation { throw APIError.unavailable }
    func groupInfo(chatID: String) async throws -> GroupInfoResponse { throw APIError.unavailable }
    func friendRelationship(peerUID: Int32) async throws -> FriendRelationshipResponse { throw APIError.unavailable }
    func getMessage(chatID: String, messageID: String) async throws -> MessageResponse { throw APIError.unavailable }
    func deleteMessage(chatID: String, messageID: String) async throws {
        guard !deleteResults.isEmpty else { throw APIError.unavailable }
        try deleteResults.removeFirst().get()
    }
    func archiveChat(chatID: String) async throws {
        guard !archiveResults.isEmpty else { throw APIError.unavailable }
        try archiveResults.removeFirst().get()
    }
    func archiveThread(chatID: String, threadID: String) async throws {
        guard !archiveResults.isEmpty else { throw APIError.unavailable }
        try archiveResults.removeFirst().get()
    }
    func unarchiveChat(chatID: String) async throws {
        guard !archiveResults.isEmpty else { throw APIError.unavailable }
        try archiveResults.removeFirst().get()
    }
    func unarchiveThread(chatID: String, threadID: String) async throws {
        guard !archiveResults.isEmpty else { throw APIError.unavailable }
        try archiveResults.removeFirst().get()
    }
    func muteChat(chatID: String) async throws -> MuteResponse { throw APIError.unavailable }
    func unmuteChat(chatID: String) async throws {
        guard !unmuteResults.isEmpty else { throw APIError.unavailable }
        try unmuteResults.removeFirst().get()
    }
    func markChatRead(chatID: String, messageID: String) async throws -> ReadStateResponse {
        guard !readResults.isEmpty else { throw APIError.unavailable }
        return try readResults.removeFirst().get()
    }
    func markChatUnread(chatID: String) async throws -> ReadStateResponse {
        guard !unreadResults.isEmpty else { throw APIError.unavailable }
        return try unreadResults.removeFirst().get()
    }
    func markThreadRead(chatID: String, threadID: String, messageID: String) async throws -> ReadStateResponse {
        guard !readResults.isEmpty else { throw APIError.unavailable }
        return try readResults.removeFirst().get()
    }
    func putReaction(chatID: String, messageID: String, emoji: String) async throws { throw APIError.unavailable }
    func deleteReaction(chatID: String, messageID: String, emoji: String) async throws { throw APIError.unavailable }
    func listThreads(query: ListThreadsQuery) async throws -> ListThreadsResponse {
        if query.archived == true {
            guard !archivedThreadResults.isEmpty else { return .init(threads: []) }
            return try archivedThreadResults.removeFirst().get()
        }
        guard !threadResults.isEmpty else { return .init(threads: []) }
        return try threadResults.removeFirst().get()
    }
    func sendThreadMessage(chatID: String, threadID: String, body: CreateMessageBody) async throws -> MessageResponse { throw APIError.unavailable }

    func listChats(query: ListChatsQuery) async throws -> ListChatsResponse {
        chatQueries.append(query)
        if query.archived == true ? suspendArchivedChatRequests : suspendChatRequests {
            chatRequestObserver?.resume()
            chatRequestObserver = nil
            return try await withCheckedThrowingContinuation { pendingChatRequest = $0 }
        }

        if query.archived == true {
            guard !archivedChatResults.isEmpty else { return .init(chats: []) }
            return try archivedChatResults.removeFirst().get()
        }
        guard !chatResults.isEmpty else { throw APIError.unavailable }
        return try chatResults.removeFirst().get()
    }

    func recordedChatQueries() -> [ListChatsQuery] { chatQueries }

    func listMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse {
        guard var results = messageResults[chatID], !results.isEmpty else { throw APIError.unavailable }
        let result = results.removeFirst()
        messageResults[chatID] = results
        return try result.get()
    }

    func sendMessage(chatID: String, body: CreateMessageBody) async throws -> MessageResponse { throw APIError.unavailable }

    func waitForChatRequest() async {
        if pendingChatRequest != nil { return }
        await withCheckedContinuation { chatRequestObserver = $0 }
    }

    func resumeChatRequest(with result: Result<ListChatsResponse, Error>) {
        switch result {
        case .success(let response): pendingChatRequest?.resume(returning: response)
        case .failure(let error): pendingChatRequest?.resume(throwing: error)
        }
        pendingChatRequest = nil
    }
}
