import Foundation
import XCTest

@testable import ChahuaAPI

final class RealtimeModelTests: XCTestCase {
    private let largeID = "9007199254740993"
    /// Above 2^53: exact only if the wire string is parsed as an integer, not a Double.
    private let largeMessageID = MessageID(9_007_199_254_740_993)
    private let timestamp = "2026-09-01T12:34:56.123Z"

    func testConversationWatchesDecodeAbsoluteSnapshotsAndPartialUpdates() throws {
        guard
            case .conversationUnread(let summary) = try event(
                "conversationUnread",
                #"{"requestId":4294967295,"full":true,"appBadgeCount":12,"summaries":[{"key":"groups","unreadMessageCount":19,"unreadUnmutedMessageCount":11,"unreadConversationCount":3,"unreadUnmutedConversationCount":2,"unreadAttentionCount":7,"unreadUnmutedAttentionCount":5}]}"#
            )
        else { return XCTFail("Expected unread snapshot") }
        XCTAssertEqual(summary.requestId, UInt32.max)
        XCTAssertTrue(summary.full)
        XCTAssertEqual(summary.appBadgeCount, 12)
        XCTAssertEqual(
            summary.summaries,
            [
                .init(
                    key: "groups", unreadAttentionCount: 7, unreadConversationCount: 3,
                    unreadMessageCount: 19, unreadUnmutedAttentionCount: 5,
                    unreadUnmutedConversationCount: 2, unreadUnmutedMessageCount: 11)
            ])
        guard
            case .conversationUnread(let partial) = try event(
                "conversationUnread", #"{"requestId":0,"full":false,"summaries":[]}"#
            )
        else { return XCTFail("Expected unread partial") }
        XCTAssertFalse(partial.full)
        XCTAssertNil(partial.appBadgeCount)
        guard
            case .conversationStates(let states) = try event(
                "conversationStates",
                #"{"requestId":7,"full":false,"states":[{"chatId":"9223372036854775807","threadId":"9007199254740993","accessible":true,"lastReadMessageId":"9007199254740993","unreadCount":4,"unreadMentions":2,"unreadReactions":1},{"chatId":"42","threadId":null,"accessible":false,"lastReadMessageId":null,"unreadCount":0,"unreadMentions":0,"unreadReactions":0}]}"#
            )
        else { return XCTFail("Expected states") }
        XCTAssertEqual(states.requestId, 7)
        XCTAssertFalse(states.full)
        XCTAssertEqual(
            states.states[0],
            .init(
                chatId: "9223372036854775807", threadId: largeMessageID, accessible: true,
                lastReadMessageId: largeMessageID, unreadCount: 4, unreadMentions: 2,
                unreadReactions: 1))
        XCTAssertFalse(states.states[1].accessible)
        XCTAssertNil(states.states[1].threadId)
        XCTAssertNil(states.states[1].lastReadMessageId)
        guard
            case .conversationUnreadError(let unreadError) = try event(
                "conversationUnreadError", #"{"requestId":8}"#
            )
        else { return XCTFail("Expected unread error") }
        XCTAssertEqual(unreadError.requestId, 8)
        guard
            case .conversationStatesError(let statesError) = try event(
                "conversationStatesError", #"{"requestId":9}"#
            )
        else { return XCTFail("Expected states error") }
        XCTAssertEqual(statesError.requestId, 9)
    }

    func testMalformedConversationWatchFramesFailInsteadOfBecomingUnknown() throws {
        for (name, payload) in [
            ("conversationUnread", #"{"requestId":1,"full":true}"#),
            ("conversationUnread", #"{"requestId":4294967296,"full":true,"summaries":[]}"#),
            ("conversationUnreadError", #"{"requestId":-1}"#),
            ("conversationStatesError", "{}"),
            (
                "conversationStates",
                #"{"requestId":1,"full":true,"states":[{"chatId":"42","accessible":true,"unreadCount":0,"unreadMentions":0}]}"#
            ),
        ] {
            XCTAssertThrowsError(try event(name, payload))
        }
    }

    func testScopedReceiptsMembershipAndBulkReconciliationDecodeOptionalFields() throws {
        guard
            case .readReceiptChanged(let receipt) = try event(
                "readReceiptChanged",
                #"{"chatId":"42","readerUid":17,"threadRootId":"9007199254740993"}"#
            )
        else { return XCTFail("Expected scoped receipt") }
        XCTAssertEqual(receipt.readerUid, 17)
        XCTAssertEqual(receipt.threadRootId, largeMessageID)
        guard
            case .threadMembershipChanged(let membership) = try event(
                "threadMembershipChanged",
                #"{"chatId":"42","threadRootId":"9","status":{"subscribed":true,"archived":false}}"#
            )
        else { return XCTFail("Expected absolute membership") }
        XCTAssertEqual(membership.status, .init(subscribed: true, archived: false))
        for complete in [false, true] {
            guard
                case .messagesBulkDeleted(let batch) = try event(
                    "messagesBulkDeleted",
                    #"{"chatId":"42","messageIds":[],"complete":\#(complete),"threadRootIds":["9007199254740993"]}"#
                )
            else { return XCTFail("Expected reconciliation batch") }
            XCTAssertEqual(batch.complete, complete)
            XCTAssertEqual(batch.threadRootIds, [largeMessageID])
        }
    }

    func testDirectedActivityNotificationsDecodeKindsAndExactScopes() throws {
        for kind in [NotificationType.mention, .reply, .reaction] {
            guard
                case .notification(let payload) = try event(
                    "notification",
                    #"{"actorUid":2,"actorName":"Ada","chatId":"42","messageId":"9007199254740993","notificationType":"\#(kind.rawValue)","threadRootId":"9"}"#
                )
            else { return XCTFail("Expected directed activity") }
            XCTAssertEqual(payload.notificationType, kind)
            XCTAssertEqual(payload.actorUid, 2)
            XCTAssertEqual(payload.actorName, "Ada")
            XCTAssertEqual(payload.chatId, "42")
            XCTAssertEqual(payload.messageId, largeMessageID)
            XCTAssertEqual(payload.threadRootId, MessageID(9))
        }
        guard
            case .notification(let mainChat) = try event(
                "notification",
                #"{"actorUid":3,"chatId":"42","messageId":"9","notificationType":"reaction"}"#
            )
        else { return XCTFail("Expected main chat activity") }
        XCTAssertNil(mainChat.threadRootId)
        XCTAssertNil(mainChat.actorName)
        XCTAssertThrowsError(
            try event(
                "notification",
                #"{"actorUid":3,"chatId":"42","messageId":"9","notificationType":"unknown"}"#))
    }

    func testReadReceiptInvalidationDistinguishesPrivacyRevocationFromProgress() throws {
        guard
            case .readReceiptChanged(let progress) = try event(
                "readReceiptChanged", #"{"chatId":"42"}"#)
        else { return XCTFail("Expected receipt progress") }
        XCTAssertEqual(progress.chatId, "42")
        XCTAssertNil(progress.privacyChanged)
        XCTAssertNil(progress.readerUid)
        XCTAssertNil(progress.threadRootId)
        guard
            case .readReceiptChanged(let privacy) = try event(
                "readReceiptChanged", #"{"chatId":"42","privacyChanged":true}"#)
        else { return XCTFail("Expected receipt privacy revocation") }
        XCTAssertEqual(privacy.chatId, "42")
        XCTAssertEqual(privacy.privacyChanged, true)
    }

    func testMessageVariantsPreserveOpaqueIDsAndOptionalContext() throws {
        guard case .message(let created) = try event("message", messageJSON) else {
            return XCTFail("Expected message")
        }
        XCTAssertEqual(created.id, largeMessageID)
        XCTAssertEqual(created.mentions, [])
        XCTAssertNil(created.replyRootId)
        XCTAssertNil(created.replyToMessage)
        XCTAssertNil(created.sticker)
        guard case .messageUpdated(let updated) = try event("messageUpdated", messageJSON) else {
            return XCTFail("Expected update")
        }
        XCTAssertEqual(updated.message, "original")
        guard
            case .messageDeleted(let deleted) = try event(
                "messageDeleted",
                messageJSON.replacingOccurrences(
                    of: "\"isDeleted\":false", with: "\"isDeleted\":true"))
        else { return XCTFail("Expected delete") }
        XCTAssertTrue(deleted.isDeleted)
    }

    func testMutationAndPresencePayloads() throws {
        guard
            case .messagesBulkDeleted(let bulk) = try event(
                "messagesBulkDeleted", #"{"chatId":"42","messageIds":["9007199254740993","9"]}"#)
        else { return XCTFail("Expected bulk delete") }
        XCTAssertEqual(bulk.chatId, "42")
        XCTAssertEqual(bulk.messageIds, [largeMessageID, MessageID(9)])
        XCTAssertNil(bulk.complete)
        XCTAssertNil(bulk.threadRootIds)
        guard
            case .reactionUpdated(let reaction) = try event(
                "reactionUpdated",
                #"{"messageId":"9007199254740993","chatId":"42","reactions":[{"emoji":"like","count":7,"reactors":[{"uid":2}]}]}"#
            )
        else { return XCTFail("Expected reactions") }
        XCTAssertEqual(reaction.messageId, largeMessageID)
        XCTAssertEqual(reaction.reactions[0].count, 7)
        XCTAssertNil(reaction.reactions[0].reactedByMe)
        guard
            case .threadUpdate(let thread) = try event(
                "threadUpdate",
                "{\"threadRootId\":\"\(largeID)\",\"chatId\":\"42\",\"lastReplyAt\":\"\(timestamp)\",\"replyCount\":12}"
            )
        else { return XCTFail("Expected thread") }
        XCTAssertEqual(thread.threadRootId, largeID)
        XCTAssertEqual(thread.replyCount, 12)
        XCTAssertEqual(
            thread.lastReplyAt,
            try JSONCoding.decoder.decode(Date.self, from: Data("\"\(timestamp)\"".utf8)))
        guard
            case .threadMembershipChanged(let membership) = try event(
                "threadMembershipChanged", #"{"threadRootId":"9","chatId":"42"}"#)
        else { return XCTFail("Expected membership") }
        XCTAssertEqual(membership.threadRootId, "9")
        XCTAssertNil(membership.status)
        guard
            case .chatArchiveStateChanged(let archive) = try event(
                "chatArchiveStateChanged", #"{"chatId":"42","archived":false}"#)
        else { return XCTFail("Expected archive") }
        XCTAssertFalse(archive.archived)
        XCTAssertNil(archive.mutedUntil)
        guard
            case .presenceUpdate(let presence) = try event(
                "presenceUpdate", #"{"activeConnections":3}"#)
        else { return XCTFail("Expected presence") }
        XCTAssertEqual(presence.activeConnections, 3)
    }

    func testPinEventsDecodeChatAndThreadScopes() throws {
        let pin =
            "{\"id\":\"7\",\"chatId\":\"42\",\"message\":\(messageJSON),\"pinnedBy\":2,\"pinnedAt\":\"\(timestamp)\"}"
        guard
            case .pinAdded(let added) = try event(
                "pinAdded",
                "{\"chatId\":\"42\",\"pinId\":\"7\",\"messageId\":\"\(largeID)\",\"pin\":\(pin)}")
        else { return XCTFail("Expected pin added") }
        XCTAssertEqual(added.pin?.message.id, largeMessageID)
        XCTAssertEqual(added.pin?.pinnedBy, 2)
        XCTAssertNil(added.pin?.expiresAt)
        XCTAssertNil(added.threadRootId)
        guard
            case .threadPinAdded(let threadAdded) = try event(
                "threadPinAdded",
                "{\"chatId\":\"42\",\"pinId\":\"7\",\"messageId\":\"\(largeID)\",\"threadRootId\":\"9\",\"pin\":\(pin)}"
            )
        else { return XCTFail("Expected thread pin added") }
        XCTAssertEqual(threadAdded.threadRootId, "9")
        guard
            case .pinRemoved(let removed) = try event(
                "pinRemoved", #"{"chatId":"42","pinId":"7","messageId":"9007199254740993"}"#)
        else { return XCTFail("Expected pin removed") }
        XCTAssertEqual(removed.pinId, "7")
        XCTAssertNil(removed.pin)
        guard
            case .threadPinRemoved(let threadRemoved) = try event(
                "threadPinRemoved",
                #"{"chatId":"42","pinId":"7","messageId":"9007199254740993","threadRootId":"9","pin":null}"#
            )
        else { return XCTFail("Expected thread pin removed") }
        XCTAssertEqual(threadRemoved.threadRootId, "9")
        XCTAssertNil(threadRemoved.pin)
    }

    func testStickerFriendAndControlEvents() throws {
        guard
            case .stickerPackOrderUpdated(let order) = try event(
                "stickerPackOrderUpdated",
                #"{"order":[{"stickerPackId":"9007199254740993","lastUsedOn":1725194096}]}"#)
        else { return XCTFail("Expected sticker order") }
        XCTAssertEqual(order.order[0].stickerPackId, largeID)
        XCTAssertEqual(order.order[0].lastUsedOn, 1_725_194_096)
        guard
            case .friendRequestReceived(let received) = try event(
                "friendRequestReceived", #"{"fromUid":17}"#)
        else { return XCTFail("Expected friend request") }
        XCTAssertEqual(received.fromUid, 17)
        for status in [FriendRequestStatus.pending, .archived, .accepted, .rejected] {
            guard
                case .friendRequestResolved(let resolved) = try event(
                    "friendRequestResolved",
                    "{\"requestId\":\"\(largeID)\",\"status\":\"\(status.rawValue)\",\"byUid\":18}")
            else { return XCTFail("Expected resolution") }
            XCTAssertEqual(resolved.requestId, largeID)
            XCTAssertEqual(resolved.status, status)
            XCTAssertEqual(resolved.byUid, 18)
        }
        guard
            case .friendshipRemoved(let removed) = try event(
                "friendshipRemoved", #"{"actorUid":19}"#)
        else { return XCTFail("Expected friendship removed") }
        XCTAssertEqual(removed.actorUid, 19)
        guard case .pong = try decode(#"{"type":"pong"}"#) else { return XCTFail("Expected pong") }
        guard case .unknown(let type) = try decode(#"{"type":"futureFeature","payload":42}"#) else {
            return XCTFail("Expected unknown")
        }
        XCTAssertEqual(type, "futureFeature")
    }

    func testPresenceSnapshotDecodesCamelCaseAndExactIdentifiers() throws {
        guard
            case .presenceSnapshot(let snapshot) = try event(
                "presenceSnapshot",
                """
                {"requestId":18446744073709551615,"users":[{"uid":7,"online":true,"lastSeenAt":"\(timestamp)"},{"uid":8,"online":false},{"uid":9,"online":false,"lastSeenAt":null}],"groups":[{"chatId":"\(largeID)","memberCount":4294967295,"onlineCount":2}]}
                """)
        else { return XCTFail("Expected presence snapshot") }
        XCTAssertEqual(snapshot.requestId, UInt64.max)
        XCTAssertEqual(snapshot.users.map(\.uid), [7, 8, 9])
        XCTAssertTrue(snapshot.users[0].online)
        XCTAssertEqual(
            snapshot.users[0].lastSeenAt,
            try JSONCoding.decoder.decode(Date.self, from: Data("\"\(timestamp)\"".utf8)))
        XCTAssertEqual(snapshot.users[1], UserPresenceResponse(uid: 8, online: false))
        XCTAssertNil(snapshot.users[2].lastSeenAt)
        XCTAssertEqual(
            snapshot.groups,
            [GroupPresenceResponse(chatId: largeID, memberCount: UInt32.max, onlineCount: 2)])
    }

    func testPresenceSnapshotOptionalCorrelationDoesNotSubstituteZero() throws {
        for payload in [
            #"{"users":[],"groups":[]}"#,
            #"{"requestId":null,"users":[],"groups":[]}"#,
        ] {
            guard case .presenceSnapshot(let snapshot) = try event("presenceSnapshot", payload)
            else { return XCTFail("Expected presence snapshot") }
            XCTAssertNil(snapshot.requestId)
            XCTAssertTrue(snapshot.users.isEmpty)
            XCTAssertTrue(snapshot.groups.isEmpty)
        }
        guard
            case .presenceSnapshot(let snapshot) = try event(
                "presenceSnapshot", #"{"requestId":0,"users":[],"groups":[]}"#)
        else { return XCTFail("Expected presence snapshot") }
        XCTAssertEqual(snapshot.requestId, 0)
    }

    func testMalformedKnownPresenceSnapshotsFailRatherThanBecomingUnknown() throws {
        for payload in [
            "{}",
            #"{"users":[]}"#,
            #"{"requestId":-1,"users":[],"groups":[]}"#,
            #"{"requestId":"1","users":[],"groups":[]}"#,
            #"{"users":[{"uid":2147483648,"online":true}],"groups":[]}"#,
            #"{"users":[{"uid":7,"online":"true"}],"groups":[]}"#,
            #"{"users":[{"uid":7,"online":false,"lastSeenAt":"invalid"}],"groups":[]}"#,
            #"{"users":[],"groups":[{"chatId":42,"memberCount":2,"onlineCount":1}]}"#,
            #"{"users":[],"groups":[{"chatId":"42","memberCount":-1,"onlineCount":0}]}"#,
            #"{"users":[],"groups":[{"chatId":"42","memberCount":2,"onlineCount":4294967296}]}"#,
        ] {
            XCTAssertThrowsError(try event("presenceSnapshot", payload), payload)
        }
    }

    func testKnownMalformedEventsFailRatherThanBecomingUnknown() throws {
        XCTAssertThrowsError(try event("reactionUpdated", #"{"chatId":"42","reactions":[]}"#))
        XCTAssertThrowsError(try event("message", "{}"))
        XCTAssertThrowsError(try event("presenceUpdate", #"{"activeConnections":-1}"#))
        XCTAssertThrowsError(
            try event("friendRequestResolved", #"{"requestId":"9","status":"cancelled","byUid":1}"#)
        )
        XCTAssertThrowsError(try decode("not JSON"))
    }

    func testRecipientNormalizationAndRedactionCannotRestoreDeletedContent() throws {
        let reactions = try JSONCoding.decoder.decode(
            [ReactionSummary].self,
            from: Data(
                #"[{"emoji":"like","count":8,"reactedByMe":false,"reactors":[{"uid":1}]},{"emoji":"heart","count":9,"reactedByMe":true,"reactors":[{"uid":2}]}]"#
                    .utf8))
        XCTAssertEqual(reactions[0].normalizedForRealtime(currentUserID: 1).reactedByMe, true)
        XCTAssertNil(reactions[1].normalizedForRealtime(currentUserID: 1).reactedByMe)
        let sticker =
            #"{"id":"s","emoji":"sticker","createdAt":"2026-09-01T00:00:00Z","isFavorited":true,"media":{"id":"media","url":"https://example.test/s","contentType":"image/png","size":10}}"#
        let content =
            messageJSON
            .replacingOccurrences(of: "\"sticker\":null", with: "\"sticker\":\(sticker)")
            .replacingOccurrences(of: "\"hasAttachments\":false", with: "\"hasAttachments\":true")
            .replacingOccurrences(
                of: "\"attachments\":[]",
                with:
                    #""attachments":[{"id":"a","url":"https://example.test/a","kind":"image","size":10,"fileName":"image.png"}],"mentions":[{"uid":2,"gender":0}]"#
            )
        let original = try JSONCoding.decoder.decode(MessageResponse.self, from: Data(content.utf8))
        let normalized = original.replacingReactions(reactions).normalizedForRealtime(
            currentUserID: 1)
        XCTAssertEqual(normalized.reactions.map(\.reactedByMe), [true, nil])
        XCTAssertEqual(original.reactions, [])
        XCTAssertEqual(original.sticker?.isFavorited, true)
        XCTAssertNil(normalized.sticker?.isFavorited)
        XCTAssertEqual(normalized.replacingReactions([]).reactions, [])
        let deleted = normalized.redactedForDeletion().replacingReactions(reactions)
            .replacingThreadReplyCount(13)
        XCTAssertTrue(deleted.isDeleted)
        XCTAssertNil(deleted.message)
        XCTAssertNil(deleted.sticker)
        XCTAssertFalse(deleted.hasAttachments)
        XCTAssertEqual(deleted.attachments, [])
        XCTAssertEqual(deleted.mentions, [])
        XCTAssertEqual(deleted.reactions, [])
        XCTAssertEqual(deleted.threadInfo?.replyCount, 13)
        XCTAssertEqual(deleted.id, original.id)
        XCTAssertEqual(deleted.createdAt, original.createdAt)
    }

    func testDeletionRedactsReplyPreviewWithoutChangingIdentity() throws {
        let preview =
            #"{"id":"8","clientGeneratedId":"client-8","createdAt":"2026-09-01T12:34:56Z","sender":{"uid":1,"gender":0},"messageType":"text","attachments":[{"kind":"image"}],"mentions":[{"uid":2,"gender":0}],"isDeleted":false,"message":"quoted","sticker":{"emoji":"sticker"}}"#
        let data = messageJSON.replacingOccurrences(
            of: "\"replyToMessage\":null", with: "\"replyToMessage\":\(preview)")
        let original = try JSONCoding.decoder.decode(MessageResponse.self, from: Data(data.utf8))
        let redacted = original.redactingReplyPreview(messageIDs: [MessageID(8)])
        XCTAssertEqual(redacted.message, original.message)
        XCTAssertEqual(redacted.replyToMessage?.id, MessageID(8))
        XCTAssertEqual(redacted.replyToMessage?.sender, original.replyToMessage?.sender)
        XCTAssertEqual(redacted.replyToMessage?.createdAt, original.replyToMessage?.createdAt)
        XCTAssertEqual(redacted.replyToMessage?.isDeleted, true)
        XCTAssertNil(redacted.replyToMessage?.message)
        XCTAssertNil(redacted.replyToMessage?.sticker)
        XCTAssertEqual(redacted.replyToMessage?.attachments, [])
        XCTAssertEqual(redacted.replyToMessage?.mentions, [])
        XCTAssertEqual(original.redactingReplyPreview(messageIDs: [MessageID(9)]), original)
    }

    private var messageJSON: String {
        "{\"id\":\"\(largeID)\",\"chatId\":\"42\",\"clientGeneratedId\":\"client-1\",\"messageType\":\"text\",\"sender\":{\"uid\":1,\"gender\":0},\"createdAt\":\"\(timestamp)\",\"isEdited\":false,\"isDeleted\":false,\"hasAttachments\":false,\"attachments\":[],\"reactions\":[],\"message\":\"original\",\"replyRootId\":null,\"replyToMessage\":null,\"sticker\":null}"
    }

    private func event(_ type: String, _ payload: String) throws -> RealtimeServerEvent {
        try decode("{\"type\":\"\(type)\",\"payload\":\(payload)}")
    }

    private func decode(_ json: String) throws -> RealtimeServerEvent {
        try JSONCoding.decoder.decode(RealtimeServerEvent.self, from: Data(json.utf8))
    }
}
