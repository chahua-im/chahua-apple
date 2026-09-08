import Foundation
import XCTest
@testable import ChahuaAPI

final class RealtimeModelTests: XCTestCase {
    private let largeID = "9007199254740993"
    private let timestamp = "2026-09-01T12:34:56.123Z"

    func testMessageVariantsPreserveOpaqueIDsAndOptionalContext() throws {
        guard case let .message(created) = try event("message", messageJSON) else { return XCTFail("Expected message") }
        XCTAssertEqual(created.id, largeID)
        XCTAssertEqual(created.mentions, [])
        XCTAssertNil(created.replyRootId)
        XCTAssertNil(created.replyToMessage)
        XCTAssertNil(created.sticker)
        guard case let .messageUpdated(updated) = try event("messageUpdated", messageJSON) else { return XCTFail("Expected update") }
        XCTAssertEqual(updated.message, "original")
        guard case let .messageDeleted(deleted) = try event("messageDeleted", messageJSON.replacingOccurrences(of: "\"isDeleted\":false", with: "\"isDeleted\":true")) else { return XCTFail("Expected delete") }
        XCTAssertTrue(deleted.isDeleted)
    }

    func testMutationAndPresencePayloads() throws {
        guard case let .messagesBulkDeleted(bulk) = try event("messagesBulkDeleted", #"{"chatId":"42","messageIds":["9007199254740993","9"]}"#) else { return XCTFail("Expected bulk delete") }
        XCTAssertEqual(bulk.chatId, "42")
        XCTAssertEqual(bulk.messageIds, [largeID, "9"])
        guard case let .reactionUpdated(reaction) = try event("reactionUpdated", #"{"messageId":"9007199254740993","chatId":"42","reactions":[{"emoji":"like","count":7,"reactors":[{"uid":2}]}]}"#) else { return XCTFail("Expected reactions") }
        XCTAssertEqual(reaction.messageId, largeID)
        XCTAssertEqual(reaction.reactions[0].count, 7)
        XCTAssertNil(reaction.reactions[0].reactedByMe)
        guard case let .threadUpdate(thread) = try event("threadUpdate", "{\"threadRootId\":\"\(largeID)\",\"chatId\":\"42\",\"lastReplyAt\":\"\(timestamp)\",\"replyCount\":12}") else { return XCTFail("Expected thread") }
        XCTAssertEqual(thread.threadRootId, largeID)
        XCTAssertEqual(thread.replyCount, 12)
        XCTAssertEqual(thread.lastReplyAt, try JSONCoding.decoder.decode(Date.self, from: Data("\"\(timestamp)\"".utf8)))
        guard case let .threadMembershipChanged(membership) = try event("threadMembershipChanged", #"{"threadRootId":"9","chatId":"42"}"#) else { return XCTFail("Expected membership") }
        XCTAssertEqual(membership.threadRootId, "9")
        guard case let .chatArchiveStateChanged(archive) = try event("chatArchiveStateChanged", #"{"chatId":"42","archived":false}"#) else { return XCTFail("Expected archive") }
        XCTAssertFalse(archive.archived)
        XCTAssertNil(archive.mutedUntil)
        guard case let .presenceUpdate(presence) = try event("presenceUpdate", #"{"activeConnections":3}"#) else { return XCTFail("Expected presence") }
        XCTAssertEqual(presence.activeConnections, 3)
    }

    func testPinEventsDecodeChatAndThreadScopes() throws {
        let pin = "{\"id\":\"7\",\"chatId\":\"42\",\"message\":\(messageJSON),\"pinnedBy\":2,\"pinnedAt\":\"\(timestamp)\"}"
        guard case let .pinAdded(added) = try event("pinAdded", "{\"chatId\":\"42\",\"pinId\":\"7\",\"messageId\":\"\(largeID)\",\"pin\":\(pin)}") else { return XCTFail("Expected pin added") }
        XCTAssertEqual(added.pin?.message.id, largeID)
        XCTAssertEqual(added.pin?.pinnedBy, 2)
        XCTAssertNil(added.pin?.expiresAt)
        XCTAssertNil(added.threadRootId)
        guard case let .threadPinAdded(threadAdded) = try event("threadPinAdded", "{\"chatId\":\"42\",\"pinId\":\"7\",\"messageId\":\"\(largeID)\",\"threadRootId\":\"9\",\"pin\":\(pin)}") else { return XCTFail("Expected thread pin added") }
        XCTAssertEqual(threadAdded.threadRootId, "9")
        guard case let .pinRemoved(removed) = try event("pinRemoved", #"{"chatId":"42","pinId":"7","messageId":"9007199254740993"}"#) else { return XCTFail("Expected pin removed") }
        XCTAssertEqual(removed.pinId, "7")
        XCTAssertNil(removed.pin)
        guard case let .threadPinRemoved(threadRemoved) = try event("threadPinRemoved", #"{"chatId":"42","pinId":"7","messageId":"9007199254740993","threadRootId":"9","pin":null}"#) else { return XCTFail("Expected thread pin removed") }
        XCTAssertEqual(threadRemoved.threadRootId, "9")
        XCTAssertNil(threadRemoved.pin)
    }

    func testStickerFriendAndControlEvents() throws {
        guard case let .stickerPackOrderUpdated(order) = try event("stickerPackOrderUpdated", #"{"order":[{"stickerPackId":"9007199254740993","lastUsedOn":1725194096}]}"#) else { return XCTFail("Expected sticker order") }
        XCTAssertEqual(order.order[0].stickerPackId, largeID)
        XCTAssertEqual(order.order[0].lastUsedOn, 1725194096)
        guard case let .friendRequestReceived(received) = try event("friendRequestReceived", #"{"fromUid":17}"#) else { return XCTFail("Expected friend request") }
        XCTAssertEqual(received.fromUid, 17)
        for status in [FriendRequestStatus.pending, .archived, .accepted, .rejected] {
            guard case let .friendRequestResolved(resolved) = try event("friendRequestResolved", "{\"requestId\":\"\(largeID)\",\"status\":\"\(status.rawValue)\",\"byUid\":18}") else { return XCTFail("Expected resolution") }
            XCTAssertEqual(resolved.requestId, largeID)
            XCTAssertEqual(resolved.status, status)
            XCTAssertEqual(resolved.byUid, 18)
        }
        guard case let .friendshipRemoved(removed) = try event("friendshipRemoved", #"{"actorUid":19}"#) else { return XCTFail("Expected friendship removed") }
        XCTAssertEqual(removed.actorUid, 19)
        guard case .pong = try decode(#"{"type":"pong"}"#) else { return XCTFail("Expected pong") }
        guard case let .unknown(type) = try decode(#"{"type":"futureFeature","payload":42}"#) else { return XCTFail("Expected unknown") }
        XCTAssertEqual(type, "futureFeature")
    }

    func testKnownMalformedEventsFailRatherThanBecomingUnknown() throws {
        XCTAssertThrowsError(try event("reactionUpdated", #"{"chatId":"42","reactions":[]}"#))
        XCTAssertThrowsError(try event("message", "{}"))
        XCTAssertThrowsError(try event("presenceUpdate", #"{"activeConnections":-1}"#))
        XCTAssertThrowsError(try event("friendRequestResolved", #"{"requestId":"9","status":"cancelled","byUid":1}"#))
        XCTAssertThrowsError(try decode("not JSON"))
    }

    func testRecipientNormalizationAndRedactionCannotRestoreDeletedContent() throws {
        let reactions = try JSONCoding.decoder.decode([ReactionSummary].self, from: Data(#"[{"emoji":"like","count":8,"reactedByMe":false,"reactors":[{"uid":1}]},{"emoji":"heart","count":9,"reactedByMe":true,"reactors":[{"uid":2}]}]"#.utf8))
        XCTAssertEqual(reactions[0].normalizedForRealtime(currentUserID: 1).reactedByMe, true)
        XCTAssertNil(reactions[1].normalizedForRealtime(currentUserID: 1).reactedByMe)
        let sticker = #"{"id":"s","emoji":"sticker","createdAt":"2026-09-01T00:00:00Z","isFavorited":true,"media":{"id":"media","url":"https://example.test/s","contentType":"image/png","size":10}}"#
        let content = messageJSON
            .replacingOccurrences(of: "\"sticker\":null", with: "\"sticker\":\(sticker)")
            .replacingOccurrences(of: "\"hasAttachments\":false", with: "\"hasAttachments\":true")
            .replacingOccurrences(of: "\"attachments\":[]", with: #""attachments":[{"id":"a","url":"https://example.test/a","kind":"image","size":10,"fileName":"image.png"}],"mentions":[{"uid":2,"gender":0}]"#)
        let original = try JSONCoding.decoder.decode(MessageResponse.self, from: Data(content.utf8))
        let normalized = original.replacingReactions(reactions).normalizedForRealtime(currentUserID: 1)
        XCTAssertEqual(normalized.reactions.map(\.reactedByMe), [true, nil])
        XCTAssertEqual(original.reactions, [])
        XCTAssertEqual(original.sticker?.isFavorited, true)
        XCTAssertNil(normalized.sticker?.isFavorited)
        XCTAssertEqual(normalized.replacingReactions([]).reactions, [])
        let deleted = normalized.redactedForDeletion().replacingReactions(reactions).replacingThreadReplyCount(13)
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
        let preview = #"{"id":"8","clientGeneratedId":"client-8","createdAt":"2026-09-01T12:34:56Z","sender":{"uid":1,"gender":0},"messageType":"text","attachments":[{"kind":"image"}],"mentions":[{"uid":2,"gender":0}],"isDeleted":false,"message":"quoted","sticker":{"emoji":"sticker"}}"#
        let data = messageJSON.replacingOccurrences(of: "\"replyToMessage\":null", with: "\"replyToMessage\":\(preview)")
        let original = try JSONCoding.decoder.decode(MessageResponse.self, from: Data(data.utf8))
        let redacted = original.redactingReplyPreview(messageIDs: ["8"])
        XCTAssertEqual(redacted.message, original.message)
        XCTAssertEqual(redacted.replyToMessage?.id, "8")
        XCTAssertEqual(redacted.replyToMessage?.sender, original.replyToMessage?.sender)
        XCTAssertEqual(redacted.replyToMessage?.createdAt, original.replyToMessage?.createdAt)
        XCTAssertEqual(redacted.replyToMessage?.isDeleted, true)
        XCTAssertNil(redacted.replyToMessage?.message)
        XCTAssertNil(redacted.replyToMessage?.sticker)
        XCTAssertEqual(redacted.replyToMessage?.attachments, [])
        XCTAssertEqual(redacted.replyToMessage?.mentions, [])
        XCTAssertEqual(original.redactingReplyPreview(messageIDs: ["unknown"]), original)
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
