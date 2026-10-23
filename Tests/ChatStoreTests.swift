import ChahuaAPI
import Foundation
import XCTest

@testable import chahua_apple

@MainActor
final class ChatStoreTests: XCTestCase {
    func testForwardedRecordsUseFullCapturedTimelineAndBundleLocalReplies() async throws {
        let original = try TimelineTestFixtures.message(
            id: 1, chatID: "source", at: 1, text: "Captured original")
        let preview = ForwardedMessagePreviewResponse(
            originalMessageId: original.id, originalChatId: original.chatId,
            message: original.message, messageType: original.messageType,
            sender: original.sender, originalCreatedAt: original.createdAt)
        let captured: [ForwardedMessageResponse] = (1...55).map { index in
            let reply: ForwardedReplyResponse?
            if index == 2 {
                reply = .internal(originalMessageId: original.id, preview: preview)
            } else if index == 3 {
                reply = .redacted
            } else {
                reply = nil
            }
            return ForwardedMessageResponse(
                originalMessageId: MessageID(UInt64(index)), originalChatId: original.chatId,
                message: index == 1
                    ? original.message : index == 4 ? "pendingAudio" : "Captured \(index)",
                messageType: index == 4 ? .placeholder : index == 5 ? .forwarded : .text,
                sender: original.sender,
                originalCreatedAt: original.createdAt.addingTimeInterval(Double(index)),
                reply: reply, forwardedBundleId: index == 5 ? "child" : nil)
        }
        let response = ForwardedMessagesResponse(total: captured.count, messages: captured)
        let child = ForwardedMessagesResponse(total: 1, messages: [captured[0]])
        let api = FakeChatAPI()
        await api.setForwardedResponses([response, child])
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        defer { store.reset() }
        store.currentUserProfile = try JSONDecoder().decode(
            MeResponse.self,
            from: Data(
                #"{"uid":1,"username":"Ada","gender":2,"stickerPackOrder":[],"permissions":[]}"#
                    .utf8))
        let session = ForwardedRecordsSession(
            store: store, root: .chat(chatID: "destination", messageID: MessageID(900)))
        session.load(.root)
        let snapshot = try await waitForForwardedSnapshot(session)
        let rows = snapshot.timeline.rows.compactMap { row -> TimelineMessageRow? in
            if case .message(let message) = row { return message }
            return nil
        }
        XCTAssertEqual(rows.count, 55, "The fixed snapshot must not truncate at live page size")
        XCTAssertEqual(rows.map(\.entry.serverID), captured.map { Optional($0.originalMessageId) })
        XCTAssertTrue(rows.allSatisfy(\.isOutgoing))
        XCTAssertEqual(rows[1].entry.remoteMessage?.replyToMessage?.id, original.id)
        XCTAssertEqual(rows[1].entry.remoteMessage?.replyToMessage?.message, original.message)
        XCTAssertTrue(rows[2].capturedReplyRedacted)
        XCTAssertNil(rows[2].entry.remoteMessage?.replyToMessage)
        XCTAssertEqual(rows[3].entry.remoteMessage?.messageType, .placeholder)
        XCTAssertEqual(rows[3].entry.remoteMessage?.message, "pendingAudio")
        XCTAssertTrue(rows[3].entry.remoteMessage?.attachments.isEmpty == true)
        XCTAssertEqual(snapshot.childBundleIDs, ["child"])
        let internalJump = await snapshot.timeline.jumpToMessage(original.id)
        XCTAssertEqual(internalJump, .reached)
        let absentJump = await snapshot.timeline.jumpToMessage(MessageID(999))
        XCTAssertEqual(absentJump, .missing)

        session.load(.bundle("child"))
        _ = try await waitForForwardedSnapshot(session, key: .bundle("child"))
        session.load(.root)
        let preserved = try await waitForForwardedSnapshot(session)
        XCTAssertTrue(
            preserved === snapshot, "Returning from a child preserves the parent timeline")
        let requests = await api.recordedForwardedRequests()
        XCTAssertEqual(
            requests,
            [
                .chat(chatID: "destination", messageID: MessageID(900), bundleID: nil),
                .chat(chatID: "destination", messageID: MessageID(900), bundleID: "child"),
            ])
        let originalChatRequests = await api.recordedMessageChatIDs()
        XCTAssertTrue(originalChatRequests.isEmpty, "Captured replies must never hydrate originals")
        XCTAssertTrue(store.conversationStateScope.isEmpty, "Record timelines do not subscribe")
    }

    func testForwardedRecordRootDeletionAndAccessLossFenceDelayedChildResponses() async throws {
        for losesMembership in [false, true] {
            let original = try TimelineTestFixtures.message(id: 1, at: 1)
            let card = ForwardedMessageResponse(
                originalMessageId: original.id, originalChatId: original.chatId,
                message: nil, messageType: .forwarded, sender: original.sender,
                originalCreatedAt: original.createdAt, forwardedBundleId: "child")
            let response = ForwardedMessagesResponse(total: 1, messages: [card])
            let api = FakeChatAPI(removeMemberResults: [.success(())])
            await api.setForwardedResponses([response])
            let store = ChatStore(
                apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {}
            )
            defer { store.reset() }
            store.currentUserProfile = try JSONDecoder().decode(
                MeResponse.self,
                from: Data(
                    #"{"uid":1,"username":"Ada","gender":2,"stickerPackOrder":[],"permissions":[]}"#
                        .utf8))
            let session = ForwardedRecordsSession(
                store: store, root: .chat(chatID: "chat", messageID: MessageID(900)))
            session.load(.root)
            let snapshot = try await waitForForwardedSnapshot(session)
            XCTAssertFalse(snapshot.timeline.rows.isEmpty)
            await api.suspendNextForwardedRequest()
            session.load(.bundle("child"))
            await api.waitForForwardedRequest()

            if losesMembership {
                try await store.leaveGroup(chatID: "chat", uid: 1)
            } else {
                let deletedRoot = try TimelineTestFixtures.message(
                    id: 900, at: 2, type: .forwarded, isDeleted: true)
                store.conversationMessages.apply(.messageDeleted(deletedRoot))
            }
            guard case .unavailable = session.phase(for: .root) else {
                return XCTFail("Root authority loss must immediately make all records unavailable")
            }
            XCTAssertTrue(
                snapshot.timeline.rows.isEmpty, "Already captured content must be cleared")
            await api.resumeForwardedRequest(with: response)
            try await Task.sleep(for: .milliseconds(30))
            session.load(.root, retry: true)
            guard case .unavailable = session.phase(for: .bundle("child")) else {
                return XCTFail(
                    "A late authorized-before-revocation result must not restore content")
            }
            XCTAssertTrue(session.records.isEmpty)
            let requests = await api.recordedForwardedRequests()
            XCTAssertEqual(requests.count, 2, "Unavailable roots cannot retry with stale authority")
        }
    }

    func testSavedForwardedRecordsSurviveSourceDeletionAndChatDeparture() async throws {
        let original = try TimelineTestFixtures.message(id: 1, at: 1)
        let captured = ForwardedMessageResponse(
            originalMessageId: original.id, originalChatId: original.chatId,
            message: original.message, messageType: original.messageType,
            sender: original.sender, originalCreatedAt: original.createdAt)
        let response = ForwardedMessagesResponse(total: 1, messages: [captured])
        let card = ForwardedMessageResponse(
            originalMessageId: MessageID(2), originalChatId: original.chatId,
            message: nil, messageType: .forwarded, sender: original.sender,
            originalCreatedAt: original.createdAt, forwardedBundleId: "saved-child")
        let rootResponse = ForwardedMessagesResponse(total: 2, messages: [captured, card])
        let api = FakeChatAPI(removeMemberResults: [.success(())])
        await api.setForwardedResponses([rootResponse])
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        defer { store.reset() }
        store.currentUserProfile = try JSONDecoder().decode(
            MeResponse.self,
            from: Data(
                #"{"uid":1,"username":"Ada","gender":2,"stickerPackOrder":[],"permissions":[]}"#
                    .utf8))
        let session = ForwardedRecordsSession(store: store, root: .saved(messageID: "saved-root"))
        session.load(.root)
        let snapshot = try await waitForForwardedSnapshot(session)
        await api.suspendNextForwardedRequest()
        session.load(.bundle("saved-child"))
        await api.waitForForwardedRequest()
        store.conversationMessages.apply(.messageDeleted(original.redactedForDeletion()))
        let deletedWrapper = try TimelineTestFixtures.message(
            id: 900, at: 2, type: .forwarded, isDeleted: true)
        store.conversationMessages.apply(.messageDeleted(deletedWrapper))
        try await store.leaveGroup(chatID: "chat", uid: 1)
        let preserved = try await waitForForwardedSnapshot(session)
        XCTAssertTrue(preserved === snapshot, "Saved ownership is independent of live chat access")
        XCTAssertEqual(snapshot.timeline.rows.compactMap(\.messageID), [original.id, MessageID(2)])
        await api.resumeForwardedRequest(with: response)
        let child = try await waitForForwardedSnapshot(session, key: .bundle("saved-child"))
        XCTAssertEqual(child.timeline.rows.compactMap(\.messageID), [original.id])
        let requests = await api.recordedForwardedRequests()
        XCTAssertEqual(
            requests,
            [
                .saved(savedMessageID: "saved-root", bundleID: nil),
                .saved(savedMessageID: "saved-root", bundleID: "saved-child"),
            ])
        let originalChatRequests = await api.recordedMessageChatIDs()
        XCTAssertTrue(originalChatRequests.isEmpty)
    }

    private func waitForForwardedSnapshot(
        _ session: ForwardedRecordsSession,
        key: ForwardedRecordsSession.Key = .root,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> ForwardedRecordSnapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            switch session.phase(for: key) {
            case .ready(let snapshot): return snapshot
            case .failed, .unavailable:
                XCTFail("Expected captured records to load", file: file, line: line)
                throw FakeChatAPIError.failed
            case .loading:
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        XCTFail("Timed out loading captured records", file: file, line: line)
        throw FakeChatAPIError.failed
    }

    func testMessageAndReactionReadCursorsRemainIndependentAndBackgroundCannotAcknowledge()
        async throws
    {
        let chat = ChatListItem(
            id: "chat", unreadCount: 8, unreadMentions: 2, unreadReactions: 4,
            lastReadMessageId: MessageID(1), archived: false, kind: .group)
        let api = FakeChatAPI(
            chatResults: [.success(.init(chats: [chat]))],
            readResults: [
                .success(
                    .init(
                        lastReadMessageId: MessageID(9), unreadCount: 0,
                        unreadMentions: 0, unreadReactions: 4))
            ],
            reactionAckResults: [.success(.init(unreadReactions: 1))])
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        defer { store.cancelRealtimeRecovery() }
        await store.loadActiveChats()
        try await store.markRead(chatID: "chat", threadID: nil, messageID: MessageID(9))
        XCTAssertEqual(store.state.chats.first?.unreadCount, 0)
        XCTAssertEqual(store.state.chats.first?.unreadMentions, 0)
        XCTAssertEqual(store.state.chats.first?.unreadReactions, 4)

        _ = try await store.acknowledgeReactions(
            chatID: "chat", threadID: nil, readThrough: "2026-09-01T12:00:00Z")
        XCTAssertEqual(store.state.chats.first?.unreadReactions, 1)
        XCTAssertEqual(store.state.chats.first?.lastReadMessageId, MessageID(9))
        XCTAssertEqual(store.state.chats.first?.unreadCount, 0)
        XCTAssertEqual(store.state.chats.first?.unreadMentions, 0)

        store.setForegroundActive(false)
        do {
            _ = try await store.acknowledgeReactions(
                chatID: "chat", threadID: nil, readThrough: nil)
            XCTFail("Background navigation must not consume newer reactions")
        } catch is CancellationError {
        }
        let requests = await api.recordedReactionAckRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(store.state.chats.first?.unreadReactions, 1)
    }

    func testArchiveKeepsParentIndependentAndFencesStaleRefresh() async throws {
        let parent = ChatListItem(
            id: "chat", name: "Group", unreadCount: 7, archived: false, kind: .group)
        let thread = try ScopeTestFixtures.thread(chatID: "chat", id: 1)
        let api = FakeChatAPI(
            threadResults: [.success(.init(threads: [thread]))],
            archiveResults: [
                .success(()), .success(()), .failure(APIError.unavailable), .success(()),
                .success(()),
            ],
            suspendChatRequests: true)
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        defer { store.cancelRealtimeRecovery() }
        let initial = Task { await store.loadActiveChats() }
        await api.waitForChatRequest()
        await api.resumeChatRequest(with: .success(.init(chats: [parent])))
        await initial.value
        await store.loadActiveThreads()

        await store.performListAction(
            .archive, conversation: .init(chatID: "chat", threadID: "1"))
        XCTAssertTrue(store.state.threads.isEmpty)
        XCTAssertEqual(store.state.archivedThreads.first?.threadRootMessage.id, MessageID(1))
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
        XCTAssertEqual(store.state.archivedThreads.first?.threadRootMessage.id, MessageID(1))
        await store.performListAction(
            .unarchive, conversation: .init(chatID: "chat", threadID: "1"))
        XCTAssertEqual(store.state.threads, [thread])
        XCTAssertTrue(store.state.archivedThreads.isEmpty)
        XCTAssertEqual(store.state.chats, [parent])
        XCTAssertNil(store.listActionError)
    }

    func testLeaveRemovesConversationAndFencesLateListSnapshotWithoutDiscardingDrafts() async throws
    {
        let target = ChatListItem(
            id: "chat", name: "Group", unreadCount: 7, archived: false, kind: .group)
        let other = ChatListItem(
            id: "other", name: "Other", unreadCount: 2, archived: false, kind: .group)
        let archivedTarget = ChatListItem(
            id: "chat", name: "Group", unreadCount: 3, archived: true, kind: .group)
        let activeThread = try ScopeTestFixtures.thread(chatID: "chat", id: 1)
        let archivedThread = try ScopeTestFixtures.thread(
            chatID: "chat", id: 2, archived: true)
        let api = FakeChatAPI(
            threadResults: [.success(.init(threads: [activeThread]))],
            archivedChatResults: [.success(.init(chats: [archivedTarget]))],
            archivedThreadResults: [.success(.init(threads: [archivedThread]))],
            removeMemberResults: [.success(())],
            suspendChatRequests: true)
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        defer { store.cancelRealtimeRecovery() }

        let initial = Task { await store.loadActiveChats() }
        await api.waitForChatRequest()
        await api.resumeChatRequest(with: .success(.init(chats: [target, other])))
        await initial.value
        await store.loadActiveThreads()
        await store.loadArchivedChats()
        await store.loadArchivedThreads()
        store.drafts.setDraftText("Unsaved draft", chatID: "chat")

        let refresh = Task { await store.refreshActiveChats() }
        await api.waitForChatRequest()
        let leave = Task { try await store.leaveGroup(chatID: "chat", uid: 1) }
        try await leave.value

        XCTAssertEqual(store.state.chats, [other])
        XCTAssertTrue(store.state.archivedChats.isEmpty)
        XCTAssertTrue(store.state.threads.isEmpty)
        XCTAssertTrue(store.state.archivedThreads.isEmpty)
        XCTAssertEqual(store.drafts.draftText(chatID: "chat"), "Unsaved draft")

        await api.resumeChatRequest(with: .success(.init(chats: [target, other])))
        await api.waitForChatRequest()
        XCTAssertEqual(store.state.chats, [other])
        await api.resumeChatRequest(with: .success(.init(chats: [other])))
        await refresh.value
        XCTAssertEqual(store.state.chats, [other])
        XCTAssertTrue(store.state.archivedChats.isEmpty)
        XCTAssertTrue(store.state.threads.isEmpty)
        XCTAssertTrue(store.state.archivedThreads.isEmpty)
    }

    func testMuteGroupPreservesPreviewAndReadStateAndUnmuteUnarchives() async throws {
        let message = try TimelineTestFixtures.message(id: 2, at: 2)
        let chat = ChatListItem(
            id: "chat", name: "Group", lastMessageAt: Date(timeIntervalSince1970: 2),
            unreadCount: 7, lastReadMessageId: MessageID(1), lastMessage: message.replyPreview,
            archived: true, kind: .group)
        let mutedUntil = Date(timeIntervalSince1970: 3_600)
        let api = FakeChatAPI(
            archivedChatResults: [.success(.init(chats: [chat]))],
            muteResults: [.success(.init(mutedUntil: mutedUntil))],
            unmuteResults: [.success(())])
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        defer { store.cancelRealtimeRecovery() }
        await store.loadArchivedChats()

        let receivedMutedUntil = try await store.muteGroup(chatID: "chat", durationSeconds: 3_600)
        XCTAssertEqual(receivedMutedUntil, mutedUntil)
        let muted = try XCTUnwrap(store.state.archivedChats.first)
        XCTAssertEqual(muted.unreadCount, chat.unreadCount)
        XCTAssertEqual(muted.lastReadMessageId, chat.lastReadMessageId)
        XCTAssertEqual(muted.lastMessage, chat.lastMessage)
        XCTAssertEqual(muted.mutedUntil, mutedUntil)
        XCTAssertTrue(muted.archived)

        try await store.unmuteGroup(chatID: "chat")
        let unmuted = try XCTUnwrap(store.state.chats.first)
        XCTAssertEqual(unmuted.unreadCount, chat.unreadCount)
        XCTAssertEqual(unmuted.lastReadMessageId, chat.lastReadMessageId)
        XCTAssertEqual(unmuted.lastMessage, chat.lastMessage)
        XCTAssertNil(unmuted.mutedUntil)
        XCTAssertFalse(unmuted.archived)
        XCTAssertTrue(store.state.archivedChats.isEmpty)
    }

    func testMarkUnreadRewindsOnlyItsArchivedChatAndPreservesStateOnFailure() async throws {
        let message = try TimelineTestFixtures.message(id: 2, at: 2)
        let chat = ChatListItem(
            id: "chat", unreadCount: 0, lastReadMessageId: message.id,
            lastMessage: message.replyPreview, archived: true, kind: .group)
        let other = ChatListItem(id: "other", unreadCount: 4, archived: false, kind: .group)
        let thread = try ScopeTestFixtures.thread(chatID: "chat", id: 1)
        let api = FakeChatAPI(
            chatResults: [.success(.init(chats: [other]))],
            threadResults: [.success(.init(threads: [thread]))],
            archivedChatResults: [.success(.init(chats: [chat]))],
            readResults: [.success(.init(lastReadMessageId: message.id, unreadCount: 0))],
            unreadResults: [
                .failure(APIError.unavailable),
                .success(.init(lastReadMessageId: nil, unreadCount: 1)),
            ])
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        defer { store.cancelRealtimeRecovery() }
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: true, source: store,
            messageStore: store.conversationMessages)
        store.registerTimeline(model)
        var readNotifications: [MessageID] = []
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
        let parent = ChatListItem(
            id: "chat", name: "Group", unreadCount: 7, archived: true, kind: .group)
        let thread = try ScopeTestFixtures.thread(chatID: "chat", id: 1, archived: true)
        let api = FakeChatAPI(
            archivedChatResults: [.success(.init(chats: [parent]))],
            archivedThreadResults: [.success(.init(threads: [thread]))],
            readResults: [
                .success(.init(lastReadMessageId: MessageID(2), unreadCount: 0)),
                .success(.init(lastReadMessageId: MessageID(3), unreadCount: 2)),
                .success(.init(lastReadMessageId: MessageID(4), unreadCount: 3)),
            ])
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let parentModel = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: true, source: store,
            messageStore: store.conversationMessages)
        let threadModel = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: true, source: store,
            messageStore: store.conversationMessages, threadID: "1")
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
        try await store.markRead(chatID: "chat", threadID: "1", messageID: MessageID(2))
        XCTAssertEqual(store.state.archivedThreads.first?.lastReadMessageId, MessageID(2))
        XCTAssertEqual(store.state.archivedThreads.first?.unreadCount, 0)
        XCTAssertEqual(store.state.archivedChats.first, parent)
        XCTAssertEqual(parentModel.jumpUnreadCount, 7)
        XCTAssertEqual(threadModel.jumpUnreadCount, 0)
        try await store.markRead(chatID: "chat", threadID: nil, messageID: MessageID(3))
        XCTAssertEqual(store.state.archivedChats.first?.lastReadMessageId, MessageID(3))
        XCTAssertEqual(store.state.archivedChats.first?.unreadCount, 2)
        XCTAssertEqual(store.state.archivedThreads.first?.lastReadMessageId, MessageID(2))
        XCTAssertEqual(parentModel.jumpUnreadCount, 2)
        try await store.markRead(chatID: "chat", threadID: "unlisted", messageID: MessageID(4))
        XCTAssertEqual(unlistedModel.jumpUnreadCount, 3)
        XCTAssertEqual(threadModel.jumpUnreadCount, 0)
        XCTAssertEqual(parentModel.jumpUnreadCount, 2)
    }

    func testReadReceiptFencesListSnapshotStartedBeforeAcknowledgement() async throws {
        let api = FakeChatAPI(
            readResults: [.success(.init(lastReadMessageId: MessageID(1), unreadCount: 0))],
            suspendChatRequests: true)
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let refresh = Task { await store.refreshActiveChats() }
        await api.waitForChatRequest()
        try await store.markRead(chatID: "chat", threadID: nil, messageID: MessageID(1))
        await api.resumeChatRequest(
            with: .success(
                .init(chats: [
                    ChatListItem(id: "chat", unreadCount: 9, archived: false, kind: .group)
                ])))
        await api.waitForChatRequest()
        XCTAssertTrue(store.state.chats.isEmpty)
        await api.resumeChatRequest(
            with: .success(
                .init(chats: [
                    ChatListItem(
                        id: "chat", unreadCount: 0, lastReadMessageId: MessageID(1),
                        archived: false,
                        kind: .group)
                ])))
        await refresh.value
        XCTAssertEqual(store.state.chats.first?.unreadCount, 0)
        XCTAssertEqual(store.state.chats.first?.lastReadMessageId, MessageID(1))
    }

    func testLoadActiveChatsPreservesServerOrder() async {
        let api = FakeChatAPI(chatResults: [
            .success(ListChatsResponse(chats: [chat(id: "2"), chat(id: "1")]))
        ])
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})

        await store.loadActiveChats()

        XCTAssertEqual(store.state.chatListLoadPhase, .loaded)
        XCTAssertEqual(store.state.chats.map(\.id), ["2", "1"])
        let recordedQueries = await api.recordedChatQueries()
        XCTAssertEqual(recordedQueries, [ListChatsQuery(archived: false)])
    }

    func testLoadFailureCanRetry() async {
        let api = FakeChatAPI(chatResults: [
            .failure(FakeChatAPIError.failed), .success(ListChatsResponse(chats: [])),
        ])
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})

        await store.loadActiveChats()
        XCTAssertEqual(store.state.chatListLoadPhase, .failed)

        await store.loadActiveChats()
        XCTAssertEqual(store.state.chatListLoadPhase, .loaded)
        XCTAssertTrue(store.state.chats.isEmpty)
    }

    func testInvalidTokenEndsSession() async {
        let api = FakeChatAPI(chatResults: [.failure(APIError.invalidToken)])
        var invalidTokenCalls = 0
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api),
            onInvalidToken: { invalidTokenCalls += 1 })

        await store.loadActiveChats()

        XCTAssertEqual(store.state.chatListLoadPhase, .failed)
        XCTAssertEqual(invalidTokenCalls, 1)
    }

    func testResetClearsStateAndIgnoresPriorRequest() async {
        let api = FakeChatAPI(suspendChatRequests: true)
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})

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
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
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
        let activeThread = try ScopeTestFixtures.thread(id: 1)
        let first = ChatListItem(id: "first", unreadCount: 2, archived: true, kind: .group)
        let second = ChatListItem(id: "second", unreadCount: 1, archived: true, kind: .group)
        let firstThread = try ScopeTestFixtures.thread(id: 2, archived: true)
        let secondThread = try ScopeTestFixtures.thread(id: 3, archived: true)
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
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
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
        let archived = ChatListItem(
            id: "chat", unreadCount: 3, mutedUntil: .distantFuture, archived: true, kind: .group)
        let api = FakeChatAPI(
            archiveResults: [.success(())], unmuteResults: [.success(())],
            suspendArchivedChatRequests: true)
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
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

        await store.applyRealtimeEvent(
            .chatArchiveStateChanged(
                .init(
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
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api),
            onInvalidToken: { expired = true })
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
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        await store.loadActiveChats()
        await store.refreshActiveChats()
        XCTAssertEqual(store.state.chats.map(\.id), ["original"])
        XCTAssertTrue(store.state.chatListRefreshFailed)
    }

    func testEventDuringRefreshRequiresTrailingSnapshot() async throws {
        let api = FakeChatAPI(suspendChatRequests: true)
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let load = Task { await store.refreshActiveChats() }
        await api.waitForChatRequest()
        let event = try JSONDecoder().decode(
            RealtimeServerEvent.self,
            from: Data(
                #"{"type":"chatArchiveStateChanged","payload":{"chatId":"1","archived":true}}"#.utf8
            )
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
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api),
            onInvalidToken: { expired = true })
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
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
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
        let message = try TimelineTestFixtures.message(id: 1, at: 1, text: "private content")
        let api = FakeChatAPI(
            messageResults: ["chat": [.success(try TimelineTestFixtures.page([message]))]],
            deleteResults: [.failure(FakeChatAPIError.failed), .success(())])
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        defer { store.reset() }
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: true, source: store,
            messageStore: store.conversationMessages)
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
        XCTAssertTrue(
            model.rows.isEmpty,
            "A successfully deleted message leaves neither a bubble nor its date separator")
        XCTAssertEqual(
            store.drafts.draftReply(chatID: "chat"), message.replyPreview.redactedForDeletion())
        XCTAssertEqual(
            store.drafts.draftReply(chatID: "chat", threadID: "thread"),
            message.replyPreview.redactedForDeletion())
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
        XCTAssertEqual(store.conversationMessages.pending(chatID: "chat").count, 1)
        await queue.deactivate()
    }

    func testTypingBeforeStorageRestorationIsNotOverwritten() async throws {
        let api = FakeChatAPI()
        let queue = testOutgoingQueue(apiClient: api)
        let store = ChatStore(apiClient: api, outgoingQueue: queue, onInvalidToken: {})
        await queue.activate(uid: 1)
        try await queue.saveDraft(
            chatID: "chat", text: "old persisted", editRevision: 20, updatedAt: Date())
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
        let reply = try TimelineTestFixtures.message(id: 1, at: 0).replyPreview
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
        let reply = try TimelineTestFixtures.message(id: 1, at: 0).replyPreview
        h.store.drafts.setDraftReply(reply, chatID: "chat")
        h.store.drafts.setDraftText("keep this", chatID: "chat")
        await h.store.drafts.flushDraft(chatID: "chat")
        h.probe.failEnqueue = true
        let failed = await h.store.drafts.submitDraft(chatID: "chat", text: "modal caption")
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
        let retried = await h.store.drafts.submitDraft(chatID: "chat", text: "modal caption")
        XCTAssertTrue(retried)
        XCTAssertEqual(h.store.drafts.draftText(chatID: "chat"), "")
        XCTAssertNil(h.store.drafts.draftReply(chatID: "chat"))
        XCTAssertFalse(h.store.drafts.draftSaveFailed)
        let afterRetry = try await h.localStore.restore()
        XCTAssertEqual(afterRetry.flatMap(\.outgoing).map(\.text), ["modal caption"])
        XCTAssertNil(afterRetry.first?.draft.replyToMessage)
        XCTAssertEqual(afterRetry.flatMap(\.outgoing).first?.replyToMessage, reply)
    }

    func testReplyOnlyDraftRestoresAndLocalReplyChangesSurviveStaleSnapshots() async throws {
        let h = try await openDraftHarness()
        let original = try TimelineTestFixtures.message(id: 1, at: 0).replyPreview
        let replacement = try TimelineTestFixtures.message(id: 2, at: 1).replyPreview
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
        let target = try TimelineTestFixtures.message(id: 1, at: 0, text: "private content")
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
        let pending = try XCTUnwrap(h.store.conversationMessages.pending(chatID: "chat").first)
        XCTAssertEqual(pending.replyToMessage, redacted)
        XCTAssertEqual(pending.body.replyToId, target.id)
        h.store.drafts.setDraftReply(target.replyPreview, chatID: "chat")
        XCTAssertEqual(h.store.drafts.draftReply(chatID: "chat"), redacted)
    }

    private func openDraftHarness() async throws -> DraftHarness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ChatDraft-\(UUID().uuidString)")
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
        XCTAssertEqual(
            persisted.first { $0.chatID == "chat" }?.draft.text, text, file: file, line: line)
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
        let remote = try TimelineTestFixtures.message(
            id: 1, at: 1, text: pending.text, clientGeneratedID: pending.clientGeneratedID)
        await api.appendMessageResult(chatID: "chat", page: try TimelineTestFixtures.page([remote]))
        let page = try await store.fetchMessages(chatID: "chat")
        XCTAssertTrue(queue.pendingMessages(chatID: "chat").isEmpty)
        XCTAssertEqual(page.messages.map(\.clientGeneratedId), [pending.clientGeneratedID])
        XCTAssertTrue(store.conversationMessages.pending(chatID: "chat").isEmpty)
        await queue.deactivate()
        store.reset()
        await queue.activate(uid: 1)
        XCTAssertTrue(queue.pendingMessages(chatID: "chat").isEmpty)
        await queue.deactivate()
    }
    func testThreadPaginationDeduplicatesAndFailedRefreshRetainsCompleteSnapshot() async throws {
        let first = try ScopeTestFixtures.thread(id: 1)
        let second = try ScopeTestFixtures.thread(id: 2)
        let api = FakeChatAPI(threadResults: [
            .success(.init(threads: [first], nextCursor: "next")),
            .success(.init(threads: [first, second])),
            .success(.init(threads: [second], nextCursor: "loop")),
            .success(.init(threads: [], nextCursor: "loop")),
        ])
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        await store.loadActiveThreads()
        XCTAssertEqual(store.state.threads, [first, second])
        await store.refreshActiveThreads()
        XCTAssertEqual(store.state.threads, [first, second])
        XCTAssertEqual(store.state.threadListLoadPhase, .loaded)
        XCTAssertTrue(store.state.threadListRefreshFailed)
    }

    func testChatsOnlyRefreshDoesNotDiscardPendingRealtimeMembershipRefresh() async throws {
        let first = try ScopeTestFixtures.thread(id: 1)
        let archived = try ScopeTestFixtures.thread(id: 1, archived: true)
        let api = FakeChatAPI(
            chatResults: [.success(.init(chats: [])), .success(.init(chats: []))],
            threadResults: [.success(.init(threads: [first])), .success(.init(threads: []))],
            archivedThreadResults: [.success(.init(threads: [archived]))])
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        defer { store.cancelRealtimeRecovery() }
        await store.loadActiveThreads()
        await store.applyRealtimeEvent(
            .threadMembershipChanged(
                .init(
                    threadRootId: "1", chatId: "chat")), currentUserID: 1)
        await store.refreshActiveChats()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.state.archivedThreads != [archived] || !store.state.threads.isEmpty {
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.state.archivedThreads, [archived])
        XCTAssertTrue(store.state.threads.isEmpty)
        let queries = await api.recordedThreadQueries()
        XCTAssertEqual(queries.count, 3)
        XCTAssertEqual(queries.dropFirst().map(\.rootId), [MessageID(1), MessageID(1)])
        XCTAssertEqual(queries.dropFirst().map(\.archived), [false, true])
    }

    func testThreadSubscriptionChangesMoveListsOnlyAfterServerAcceptance() async throws {
        let thread = try ScopeTestFixtures.thread(chatID: "chat", id: 1)
        let api = FakeChatAPI(
            threadResults: [.success(.init(threads: [thread]))],
            archiveResults: [.success(()), .failure(FakeChatAPIError.failed), .success(())])
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        defer { store.cancelRealtimeRecovery() }
        await store.loadActiveThreads()

        let archived = try await store.changeThreadSubscription(
            .archive, chatID: "chat", threadID: "1")
        XCTAssertEqual(archived, ThreadSubscriptionStatus(subscribed: true, archived: true))
        XCTAssertTrue(store.state.threads.isEmpty)
        XCTAssertEqual(store.state.archivedThreads, [thread.withArchived(true)])

        do {
            _ = try await store.changeThreadSubscription(
                .unarchive, chatID: "chat", threadID: "1")
            XCTFail("A rejected unarchive must surface its failure")
        } catch {
            XCTAssertTrue(store.state.threads.isEmpty)
            XCTAssertEqual(store.state.archivedThreads, [thread.withArchived(true)])
        }

        let restored = try await store.changeThreadSubscription(
            .unarchive, chatID: "chat", threadID: "1")
        XCTAssertEqual(restored, ThreadSubscriptionStatus(subscribed: true, archived: false))
        XCTAssertEqual(store.state.threads, [thread])
        XCTAssertTrue(store.state.archivedThreads.isEmpty)
    }

    func testUnreadWatchRequiresFullSnapshotAndUsesServerAppBadge() async throws {
        let api = FakeChatAPI()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        defer { store.reset() }
        func summary(_ key: String, _ count: Int64) -> ConversationUnreadSummary {
            .init(
                key: key, unreadAttentionCount: 0, unreadConversationCount: count,
                unreadMessageCount: count, unreadUnmutedAttentionCount: 0,
                unreadUnmutedConversationCount: count, unreadUnmutedMessageCount: count)
        }
        store.setRealtimeStatus(.connected)
        store.beginConversationUnreadWatch(requestID: 7)
        await store.applyRealtimeEvent(
            .conversationUnread(
                .init(requestId: 7, full: false, summaries: [summary("groups", 9)])),
            currentUserID: 1)
        XCTAssertTrue(store.state.conversationUnreadSummaries.isEmpty)
        await store.applyRealtimeEvent(
            .conversationUnread(
                .init(
                    requestId: 7, full: true, summaries: [summary("groups", 2), summary("dms", 3)],
                    appBadgeCount: 42)), currentUserID: 1)
        XCTAssertEqual(store.state.unreadBadgeCount(), 42, "The badge is not a loaded-list sum")
        await store.applyRealtimeEvent(
            .conversationUnread(
                .init(requestId: 7, full: false, summaries: [summary("groups", 0)])),
            currentUserID: 1)
        XCTAssertEqual(
            store.state.conversationUnreadSummaries.first { $0.key == "groups" }?
                .unreadMessageCount, 0)
        XCTAssertEqual(
            store.state.conversationUnreadSummaries.first { $0.key == "dms" }?.unreadMessageCount, 3
        )
        XCTAssertEqual(store.state.appBadgeCount, 42)
        store.beginConversationUnreadWatch(requestID: 8)
        await store.applyRealtimeEvent(
            .conversationUnread(.init(requestId: 7, full: true, summaries: [], appBadgeCount: 99)),
            currentUserID: 1)
        XCTAssertEqual(store.state.appBadgeCount, 42)
        await store.applyRealtimeEvent(
            .conversationUnread(.init(requestId: 8, full: true, summaries: [summary("groups", 1)])),
            currentUserID: 1)
        XCTAssertEqual(store.state.conversationUnreadSummaries.map(\.key), ["groups"])
        XCTAssertNil(store.state.appBadgeCount, "A full snapshot replaces optional badge state")
        store.setRealtimeStatus(.reconnecting)
        await store.applyRealtimeEvent(
            .conversationUnread(.init(requestId: 8, full: true, summaries: [], appBadgeCount: 99)),
            currentUserID: 1)
        XCTAssertNil(store.state.appBadgeCount)
    }

    func testConversationStatesAreScopedAbsoluteAndFenceLocalWrites() async throws {
        let chat = ChatListItem(id: "chat", unreadCount: 8, archived: false, kind: .group)
        let thread = try ScopeTestFixtures.thread(chatID: "chat", id: 1)
        let api = FakeChatAPI(
            chatResults: [.success(.init(chats: [chat]))],
            threadResults: [.success(.init(threads: [thread]))],
            readResults: [.success(.init(lastReadMessageId: MessageID(9), unreadCount: 0))])
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        defer { store.reset() }
        await store.loadActiveChats()
        await store.loadActiveThreads()
        store.setRealtimeStatus(.connected)
        store.setConversationStateScope(
            [.init(chatId: "chat"), .init(chatId: "chat", threadId: MessageID(1))], for: UUID())
        store.beginConversationStatesWatch(requestID: 5)
        let unread = ConversationState(
            chatId: "chat", accessible: true, lastReadMessageId: MessageID(2),
            unreadCount: 3, unreadMentions: 1, unreadReactions: 2)
        await store.applyRealtimeEvent(
            .conversationStates(.init(requestId: 5, full: false, states: [unread])),
            currentUserID: 1)
        XCTAssertEqual(store.state.chats.first?.unreadCount, 8)
        await store.applyRealtimeEvent(
            .conversationStates(
                .init(
                    requestId: 5, full: true,
                    states: [
                        unread,
                        .init(
                            chatId: "chat", threadId: MessageID(1), accessible: true,
                            unreadCount: 4, unreadMentions: 2, unreadReactions: 3),
                        .init(
                            chatId: "unselected", accessible: true, unreadCount: 99,
                            unreadMentions: 99, unreadReactions: 99),
                    ])), currentUserID: 1)
        XCTAssertEqual(store.state.chats.first?.unreadCount, 3)
        XCTAssertEqual(store.state.chats.first?.unreadReactions, 2)
        XCTAssertEqual(store.state.threads.first?.unreadCount, 4)
        XCTAssertEqual(store.state.chats.count, 1)
        await store.applyRealtimeEvent(
            .conversationStates(
                .init(
                    requestId: 5, full: false,
                    states: [
                        .init(
                            chatId: "chat", accessible: true, lastReadMessageId: MessageID(5),
                            unreadCount: 1, unreadMentions: 0, unreadReactions: 0)
                    ])), currentUserID: 1)
        XCTAssertEqual(store.state.chats.first?.unreadCount, 1)
        XCTAssertEqual(store.state.chats.first?.unreadMentions, 0)
        XCTAssertEqual(store.state.chats.first?.unreadReactions, 0)
        XCTAssertEqual(store.state.threads.first?.unreadCount, 4)
        try await store.markRead(chatID: "chat", threadID: nil, messageID: MessageID(9))
        await store.applyRealtimeEvent(
            .conversationStates(.init(requestId: 5, full: true, states: [unread])), currentUserID: 1
        )
        XCTAssertEqual(store.state.chats.first?.unreadCount, 0)
        XCTAssertEqual(store.state.chats.first?.lastReadMessageId, MessageID(9))
        store.beginConversationStatesWatch(requestID: 6)
        await store.applyRealtimeEvent(
            .conversationStates(
                .init(
                    requestId: 6, full: true,
                    states: [
                        .init(
                            chatId: "chat", threadId: MessageID(1), accessible: false,
                            unreadCount: 0, unreadMentions: 0, unreadReactions: 0)
                    ])), currentUserID: 1)
        XCTAssertTrue(store.state.threads.isEmpty)
        XCTAssertEqual(store.state.chats.first?.lastReadMessageId, MessageID(9))
    }

    func testConversationScopeCapsListsAndPrioritizesAnUnlistedTimeline() async throws {
        let api = FakeChatAPI()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        defer { store.reset() }
        let consumer = UUID()
        store.setConversationStateScope(
            (0..<600).map { .init(chatId: String(format: "%04d", $0)) }, for: consumer)
        XCTAssertEqual(store.conversationStateScope.count, 512)
        let model = ConversationTimelineModel(
            chatID: "unlisted", currentUserID: 1, isGroupChat: true, source: store,
            messageStore: store.conversationMessages)
        store.registerTimeline(model)
        XCTAssertEqual(store.conversationStateScope.count, 512)
        XCTAssertEqual(store.conversationStateScope.first?.chatId, "unlisted")
        store.beginConversationStatesWatch(requestID: 1)
        store.setRealtimeStatus(.connected)
        store.beginConversationStatesWatch(requestID: 2)
        await store.applyRealtimeEvent(
            .conversationStates(
                .init(
                    requestId: 2, full: true,
                    states: [
                        .init(
                            chatId: "unlisted", accessible: true, lastReadMessageId: MessageID(4),
                            unreadCount: 7, unreadMentions: 0, unreadReactions: 0)
                    ])), currentUserID: 1)
        store.unregisterTimeline(model)
        let reopened = ConversationTimelineModel(
            chatID: "unlisted", currentUserID: 1, isGroupChat: true, source: store,
            messageStore: store.conversationMessages)
        store.registerTimeline(reopened)
        XCTAssertEqual(reopened.state.live.unreadCount, 7)
        store.removeConversationStateScope(for: consumer)
        XCTAssertEqual(store.conversationStateScope, [.init(chatId: "unlisted")])
        store.unregisterTimeline(reopened)
        XCTAssertTrue(store.conversationStateScope.isEmpty)
    }

    func testMessagePreviewAndAbsoluteMembershipDoNotReloadUnrelatedLists() async throws {
        let chat = ChatListItem(id: "chat", unreadCount: 2, archived: false, kind: .group)
        let thread = try ScopeTestFixtures.thread(chatID: "chat", id: 1)
        let api = FakeChatAPI(
            chatResults: [.success(.init(chats: [chat]))],
            threadResults: [.success(.init(threads: [thread]))])
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        defer { store.reset() }
        await store.loadActiveChats()
        await store.loadActiveThreads()
        let message = try TimelineTestFixtures.message(id: 10, at: 10)
        await store.applyRealtimeEvent(.message(message), currentUserID: 1)
        XCTAssertEqual(store.state.chats.first?.lastMessage?.id, message.id)
        let archived = ThreadSubscriptionStatus(subscribed: true, archived: true)
        await store.applyRealtimeEvent(
            .threadMembershipChanged(.init(threadRootId: "1", chatId: "chat", status: archived)),
            currentUserID: 1)
        await store.applyRealtimeEvent(
            .threadMembershipChanged(.init(threadRootId: "1", chatId: "chat", status: archived)),
            currentUserID: 1)
        XCTAssertTrue(store.state.threads.isEmpty)
        XCTAssertEqual(store.state.archivedThreads.first?.archived, true)
        let cached = try await store.threadSubscriptionStatus(chatID: "chat", threadID: "1")
        XCTAssertEqual(cached, archived)
        try await Task.sleep(for: .milliseconds(350))
        let queries = await api.recordedChatQueries()
        XCTAssertEqual(queries.count, 1)
    }

    func testStateWatchErrorsFallBackToHTTPWithoutLosingPartialFrameFence() async throws {
        let api = FakeChatAPI(
            chatResults: [
                .success(
                    .init(chats: [
                        .init(id: "chat", unreadCount: 8, archived: false, kind: .group)
                    ]))
            ],
            stateResults: [.success(.init(lastReadMessageId: MessageID(4), unreadCount: 1))])
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        defer { store.reset() }
        await store.loadActiveChats()
        store.setRealtimeStatus(.connected)
        store.setConversationStateScope([.init(chatId: "chat")], for: UUID())
        store.beginConversationStatesWatch(requestID: 4)
        let unread = ConversationState(
            chatId: "chat", accessible: true, unreadCount: 3, unreadMentions: 0, unreadReactions: 0)
        await store.applyRealtimeEvent(
            .conversationStates(.init(requestId: 4, full: true, states: [unread])), currentUserID: 1
        )
        let cached = try await store.conversationReadState(chatID: "chat", threadID: nil)
        XCTAssertEqual(cached.unreadCount, 3)
        let initialRequests = await api.recordedStateRequests()
        XCTAssertTrue(initialRequests.isEmpty)
        await store.applyRealtimeEvent(
            .conversationStatesError(.init(requestId: 3)), currentUserID: 1)
        XCTAssertTrue(store.conversationStateReady(chatID: "chat", threadID: nil))
        await store.applyRealtimeEvent(
            .conversationStatesError(.init(requestId: 4)), currentUserID: 1)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.state.chats.first?.unreadCount != 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.state.chats.first?.unreadCount, 1)
        await store.applyRealtimeEvent(
            .conversationStates(.init(requestId: 4, full: false, states: [unread])),
            currentUserID: 1)
        XCTAssertEqual(store.state.chats.first?.unreadCount, 1)
        let requests = await api.recordedStateRequests()
        XCTAssertEqual(requests, ["chat:"])
    }

    func testHTTPStateStartedBeforeReadCannotReplaceItsCommittedCursor() async throws {
        let api = FakeChatAPI(
            chatResults: [
                .success(
                    .init(chats: [
                        .init(id: "chat", unreadCount: 8, archived: false, kind: .group)
                    ]))
            ],
            readResults: [.success(.init(lastReadMessageId: MessageID(9), unreadCount: 0))],
            suspendStateRequests: true)
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        defer { store.reset() }
        await store.loadActiveChats()
        let loading = Task { try await store.conversationReadState(chatID: "chat", threadID: nil) }
        await api.waitForStateRequest()
        try await store.markRead(chatID: "chat", threadID: nil, messageID: MessageID(9))
        await api.resumeStateRequest(
            with: .init(lastReadMessageId: MessageID(1), unreadCount: 8))
        let response = try await loading.value
        XCTAssertEqual(response.lastReadMessageId, MessageID(9))
        XCTAssertEqual(store.state.chats.first?.unreadCount, 0)
        XCTAssertEqual(store.state.chats.first?.lastReadMessageId, MessageID(9))
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

actor FakeChatAPI: ChahuaAPIClient {
    var chatQueries: [ListChatsQuery] = []
    private var threadQueries: [ListThreadsQuery] = []
    private var receiptVisibility: ReadReceiptVisibility = .friends
    private var receiptOverrides: [Int32: FriendReadReceiptOverride] = [:]

    enum ForwardedRequest: Equatable, Sendable {
        case chat(chatID: String, messageID: MessageID, bundleID: String?)
        case saved(savedMessageID: String, bundleID: String?)
    }
    private var forwardedRequests: [ForwardedRequest] = []
    private var forwardedResponses: [ForwardedMessagesResponse] = []
    private var suspendNextForwarded = false
    private var pendingForwardedRequest: CheckedContinuation<ForwardedMessagesResponse, Error>?
    private var forwardedRequestObserver: CheckedContinuation<Void, Never>?
    private var messageChatIDs: [String] = []

    func setForwardedResponses(_ responses: [ForwardedMessagesResponse]) {
        forwardedResponses = responses
    }

    func suspendNextForwardedRequest() { suspendNextForwarded = true }

    func getForwardedMessages(chatID: String, messageID: MessageID, bundleID: String?)
        async throws -> ForwardedMessagesResponse
    {
        forwardedRequests.append(.chat(chatID: chatID, messageID: messageID, bundleID: bundleID))
        return try await readForwardedResponse()
    }

    func getSavedForwardedMessages(savedMessageID: String, bundleID: String?)
        async throws -> ForwardedMessagesResponse
    {
        forwardedRequests.append(.saved(savedMessageID: savedMessageID, bundleID: bundleID))
        return try await readForwardedResponse()
    }

    private func readForwardedResponse() async throws -> ForwardedMessagesResponse {
        if suspendNextForwarded {
            suspendNextForwarded = false
            // Deliberately ignore cancellation, just like an already delivered
            // transport response, so the session's generation fence is exercised.
            return try await withCheckedThrowingContinuation { continuation in
                pendingForwardedRequest = continuation
                forwardedRequestObserver?.resume()
                forwardedRequestObserver = nil
            }
        }
        guard !forwardedResponses.isEmpty else { throw APIError.unavailable }
        return forwardedResponses.removeFirst()
    }

    func waitForForwardedRequest() async {
        if pendingForwardedRequest != nil { return }
        await withCheckedContinuation { forwardedRequestObserver = $0 }
    }

    func resumeForwardedRequest(with response: ForwardedMessagesResponse) {
        pendingForwardedRequest?.resume(returning: response)
        pendingForwardedRequest = nil
    }

    func recordedForwardedRequests() -> [ForwardedRequest] { forwardedRequests }
    func recordedMessageChatIDs() -> [String] { messageChatIDs }

    func readReceipt(chatID: String, threadID: MessageID?) async throws -> ReadReceiptResponse {
        ReadReceiptResponse()
    }
    func readReceiptSettings() async throws -> ReadReceiptSettingsResponse {
        .init(visibility: receiptVisibility)
    }
    func updateReadReceiptSettings(visibility: ReadReceiptVisibility) async throws
        -> ReadReceiptSettingsResponse
    {
        receiptVisibility = visibility
        return .init(visibility: visibility)
    }
    func friendReadReceiptSettings(peerUID: Int32) async throws -> FriendReadReceiptSettingsResponse
    {
        .init(override: receiptOverrides[peerUID] ?? .inherit)
    }
    func updateFriendReadReceiptSettings(peerUID: Int32, override: FriendReadReceiptOverride)
        async throws -> FriendReadReceiptSettingsResponse
    {
        receiptOverrides[peerUID] = override
        return .init(override: override)
    }
    private var chatResults: [Result<ListChatsResponse, Error>]
    private var threadResults: [Result<ListThreadsResponse, Error>]
    private var archivedChatResults: [Result<ListChatsResponse, Error>]
    private var archivedThreadResults: [Result<ListThreadsResponse, Error>]
    private var removeMemberResults: [Result<Void, Error>]
    private var muteResults: [Result<MuteResponse, Error>]
    private var readResults: [Result<ReadStateResponse, Error>]
    private var stateResults: [Result<ReadStateResponse, Error>]
    private var stateRequests: [String] = []
    private let suspendStateRequests: Bool
    private var pendingStateRequest: CheckedContinuation<ReadStateResponse, Error>?
    private var stateRequestObserver: CheckedContinuation<Void, Never>?
    private var unreadResults: [Result<ReadStateResponse, Error>]
    private var archiveResults: [Result<Void, Error>]
    private var unmuteResults: [Result<Void, Error>]
    private var deleteResults: [Result<Void, Error>]
    private var messageResults: [String: [Result<ListMessagesResponse, Error>]]
    private let suspendChatRequests: Bool
    private let suspendArchivedChatRequests: Bool
    private var pendingChatRequest: CheckedContinuation<ListChatsResponse, Error>?
    private var chatRequestObserver: CheckedContinuation<Void, Never>?
    private var unreadMentionsResults: [Result<UnreadMentionIDsResponse, Error>]
    private var unreadReactionsResults: [Result<UnreadReactionIDsResponse, Error>]
    private var reactionAckResults: [Result<UnreadReactionsAckResponse, Error>]
    struct ReactionAckRequest: Equatable, Sendable {
        let chatID: String
        let threadID: MessageID?
        let readThrough: String?
    }
    private var reactionAckRequests: [ReactionAckRequest] = []
    private enum UnexpectedActivityCall: Error { case missingResult }

    init(
        chatResults: [Result<ListChatsResponse, Error>] = [],
        threadResults: [Result<ListThreadsResponse, Error>] = [],
        archivedChatResults: [Result<ListChatsResponse, Error>] = [],
        archivedThreadResults: [Result<ListThreadsResponse, Error>] = [],
        removeMemberResults: [Result<Void, Error>] = [],
        muteResults: [Result<MuteResponse, Error>] = [],
        messageResults: [String: [Result<ListMessagesResponse, Error>]] = [:],
        readResults: [Result<ReadStateResponse, Error>] = [],
        unreadResults: [Result<ReadStateResponse, Error>] = [],
        archiveResults: [Result<Void, Error>] = [],
        unmuteResults: [Result<Void, Error>] = [],
        deleteResults: [Result<Void, Error>] = [],
        unreadMentionsResults: [Result<UnreadMentionIDsResponse, Error>] = [],
        unreadReactionsResults: [Result<UnreadReactionIDsResponse, Error>] = [],
        reactionAckResults: [Result<UnreadReactionsAckResponse, Error>] = [],
        stateResults: [Result<ReadStateResponse, Error>] = [],
        suspendStateRequests: Bool = false,
        suspendChatRequests: Bool = false,
        suspendArchivedChatRequests: Bool = false
    ) {
        self.chatResults = chatResults
        self.threadResults = threadResults
        self.archivedChatResults = archivedChatResults
        self.archivedThreadResults = archivedThreadResults
        self.removeMemberResults = removeMemberResults
        self.muteResults = muteResults
        self.messageResults = messageResults
        self.readResults = readResults
        self.unreadResults = unreadResults
        self.archiveResults = archiveResults
        self.unmuteResults = unmuteResults
        self.deleteResults = deleteResults
        self.unreadMentionsResults = unreadMentionsResults
        self.unreadReactionsResults = unreadReactionsResults
        self.reactionAckResults = reactionAckResults
        self.stateResults = stateResults
        self.suspendStateRequests = suspendStateRequests
        self.suspendChatRequests = suspendChatRequests
        self.suspendArchivedChatRequests = suspendArchivedChatRequests
    }

    func chatReadState(chatID: String) async throws -> ReadStateResponse {
        try await readState(chatID: chatID, threadID: nil)
    }

    func threadReadState(chatID: String, threadID: String) async throws -> ReadStateResponse {
        try await readState(chatID: chatID, threadID: threadID)
    }

    private func readState(chatID: String, threadID: String?) async throws -> ReadStateResponse {
        stateRequests.append(chatID + ":" + (threadID ?? ""))
        if suspendStateRequests {
            stateRequestObserver?.resume()
            stateRequestObserver = nil
            return try await withCheckedThrowingContinuation { pendingStateRequest = $0 }
        }
        guard !stateResults.isEmpty else { throw APIError.unavailable }
        return try stateResults.removeFirst().get()
    }

    func recordedStateRequests() -> [String] { stateRequests }

    func waitForStateRequest() async {
        if pendingStateRequest != nil { return }
        await withCheckedContinuation { stateRequestObserver = $0 }
    }

    func resumeStateRequest(with response: ReadStateResponse) {
        pendingStateRequest?.resume(returning: response)
        pendingStateRequest = nil
    }

    func unreadMentions(chatID: String, threadID: MessageID?) async throws
        -> UnreadMentionIDsResponse
    {
        guard !unreadMentionsResults.isEmpty else { throw UnexpectedActivityCall.missingResult }
        return try unreadMentionsResults.removeFirst().get()
    }
    func unreadReactions(chatID: String, threadID: MessageID?) async throws
        -> UnreadReactionIDsResponse
    {
        guard !unreadReactionsResults.isEmpty else { throw UnexpectedActivityCall.missingResult }
        return try unreadReactionsResults.removeFirst().get()
    }
    func acknowledgeReactions(chatID: String, threadID: MessageID?, readThrough: String?)
        async throws -> UnreadReactionsAckResponse
    {
        reactionAckRequests.append(
            .init(chatID: chatID, threadID: threadID, readThrough: readThrough))
        guard !reactionAckResults.isEmpty else { throw UnexpectedActivityCall.missingResult }
        return try reactionAckResults.removeFirst().get()
    }
    func recordedReactionAckRequests() -> [ReactionAckRequest] { reactionAckRequests }

    func appendMessageResult(chatID: String, page: ListMessagesResponse) {
        messageResults[chatID, default: []].append(.success(page))
    }

    func authenticate(candidateJWT: String) async throws -> MeResponse {
        throw APIError.unavailable
    }
    func createDevSession(uid: Int32, clientID: String) async throws -> String {
        throw APIError.unavailable
    }
    func me() async throws -> MeResponse { throw APIError.unavailable }
    func attachmentConfig() async throws -> AttachmentConfigResponse { throw APIError.unavailable }
    func requestAttachmentUpload(
        fileName: String, contentType: String, size: Int64, width: Int, height: Int, order: Int
    ) async throws -> OutgoingUploadAllocation { throw APIError.unavailable }
    func groupInfo(chatID: String) async throws -> GroupInfoResponse { throw APIError.unavailable }
    func listMembers(chatID: String, query: ListMembersQuery) async throws -> ListMembersResponse {
        throw APIError.unavailable
    }
    func updateGroupMemberRole(chatID: String, uid: Int32, role: GroupRole) async throws
        -> MemberResponse
    { throw APIError.unavailable }
    func removeGroupMember(chatID: String, uid: Int32) async throws {
        guard !removeMemberResults.isEmpty else { throw APIError.unavailable }
        try removeMemberResults.removeFirst().get()
    }
    func friendRelationship(peerUID: Int32) async throws -> FriendRelationshipResponse {
        throw APIError.unavailable
    }
    func getMessage(chatID: String, messageID: MessageID) async throws -> MessageResponse {
        throw APIError.unavailable
    }

    func getReactionDetails(chatID: String, messageID: MessageID) async throws
        -> ReactionDetailResponse
    {
        throw APIError.unavailable
    }
    func deleteMessage(chatID: String, messageID: MessageID) async throws {
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
    func muteChat(chatID: String, durationSeconds: Int?) async throws -> MuteResponse {
        guard !muteResults.isEmpty else { throw APIError.unavailable }
        return try muteResults.removeFirst().get()
    }
    func unmuteChat(chatID: String) async throws {
        guard !unmuteResults.isEmpty else { throw APIError.unavailable }
        try unmuteResults.removeFirst().get()
    }
    func markChatRead(chatID: String, messageID: MessageID) async throws -> ReadStateResponse {
        guard !readResults.isEmpty else { throw APIError.unavailable }
        return try readResults.removeFirst().get()
    }
    func markChatUnread(chatID: String) async throws -> ReadStateResponse {
        guard !unreadResults.isEmpty else { throw APIError.unavailable }
        return try unreadResults.removeFirst().get()
    }
    func markThreadRead(chatID: String, threadID: String, messageID: MessageID) async throws
        -> ReadStateResponse
    {
        guard !readResults.isEmpty else { throw APIError.unavailable }
        return try readResults.removeFirst().get()
    }
    func putReaction(chatID: String, messageID: MessageID, emoji: String) async throws {
        throw APIError.unavailable
    }
    func deleteReaction(chatID: String, messageID: MessageID, emoji: String) async throws {
        throw APIError.unavailable
    }
    func listOwnedStickerPacks() async throws -> [StickerPackSummary] { throw APIError.unavailable }
    func listSubscribedStickerPacks() async throws -> [StickerPackSummary] {
        throw APIError.unavailable
    }
    func listFavoriteStickers() async throws -> [MessageStickerResponse] {
        throw APIError.unavailable
    }
    func getSticker(id: String) async throws -> StickerDetailResponse { throw APIError.unavailable }
    func getStickerPack(id: String) async throws -> StickerPackDetailResponse {
        throw APIError.unavailable
    }
    func setStickerFavorite(id: String, favorite: Bool) async throws { throw APIError.unavailable }
    func setStickerPackSubscription(id: String, subscribed: Bool) async throws {
        throw APIError.unavailable
    }
    func createStickerPack(name: String, description: String?) async throws -> StickerPackSummary {
        throw APIError.unavailable
    }
    func updateStickerPack(id: String, name: String?, description: String?) async throws
        -> StickerPackSummary
    { throw APIError.unavailable }
    func deleteStickerPack(id: String) async throws { throw APIError.unavailable }
    func uploadStickerToPack(
        id: String, upload: StickerUpload, emoji: String, name: String?, description: String?
    ) async throws -> MessageStickerResponse { throw APIError.unavailable }
    func removeStickerFromPack(id: String, stickerID: String) async throws {
        throw APIError.unavailable
    }
    func updateStickerPackOrder(_ order: [StickerPackOrderUpdate]) async throws {
        throw APIError.unavailable
    }
    func listThreads(query: ListThreadsQuery) async throws -> ListThreadsResponse {
        threadQueries.append(query)
        if query.archived == true {
            guard !archivedThreadResults.isEmpty else { return .init(threads: []) }
            return try archivedThreadResults.removeFirst().get()
        }
        guard !threadResults.isEmpty else { return .init(threads: []) }
        return try threadResults.removeFirst().get()
    }
    func recordedThreadQueries() -> [ListThreadsQuery] { threadQueries }
    func sendThreadMessage(chatID: String, threadID: String, body: CreateMessageBody) async throws
        -> MessageResponse
    { throw APIError.unavailable }

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

    func listMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse
    {
        messageChatIDs.append(chatID)
        guard var results = messageResults[chatID], !results.isEmpty else {
            throw APIError.unavailable
        }
        let result = results.removeFirst()
        messageResults[chatID] = results
        return try result.get()
    }

    func sendMessage(chatID: String, body: CreateMessageBody) async throws -> MessageResponse {
        throw APIError.unavailable
    }

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
