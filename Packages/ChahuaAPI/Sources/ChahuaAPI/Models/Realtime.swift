import Foundation

/// Every known server frame is typed; unknown future names do not decode their payload.
public enum RealtimeServerEvent: Decodable, Sendable {
    case pong
    case message(MessageResponse)
    case messageUpdated(MessageResponse)
    case messageDeleted(MessageResponse)
    case messagesBulkDeleted(BulkDeletedPayload)
    case reactionUpdated(ReactionUpdatePayload)
    case notification(NotificationPayload)
    case presenceUpdate(PresenceUpdatePayload)
    case presenceSnapshot(PresenceSnapshotPayload)
    case conversationUnread(ConversationUnreadPayload)
    case conversationUnreadError(ConversationUnreadErrorPayload)
    case conversationStates(ConversationStatesPayload)
    case conversationStatesError(ConversationUnreadErrorPayload)
    case threadUpdate(ThreadUpdatePayload)
    case threadMembershipChanged(ThreadMembershipChangedPayload)
    case chatArchiveStateChanged(ChatArchiveStateChangedPayload)
    case readReceiptChanged(ReadReceiptChangedPayload)
    case pinAdded(PinUpdatePayload)
    case threadPinAdded(PinUpdatePayload)
    case pinRemoved(PinUpdatePayload)
    case threadPinRemoved(PinUpdatePayload)
    case stickerPackOrderUpdated(StickerPackOrderUpdatePayload)
    case friendRequestReceived(FriendRequestReceivedPayload)
    case friendRequestResolved(FriendRequestResolvedPayload)
    case friendshipRemoved(FriendshipRemovedPayload)
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey { case type, payload }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pong": self = .pong
        case "message":
            self = .message(try container.decode(MessageResponse.self, forKey: .payload))
        case "messageUpdated":
            self = .messageUpdated(try container.decode(MessageResponse.self, forKey: .payload))
        case "messageDeleted":
            self = .messageDeleted(try container.decode(MessageResponse.self, forKey: .payload))
        case "messagesBulkDeleted":
            self = .messagesBulkDeleted(
                try container.decode(BulkDeletedPayload.self, forKey: .payload))
        case "reactionUpdated":
            self = .reactionUpdated(
                try container.decode(ReactionUpdatePayload.self, forKey: .payload))
        case "notification":
            self = .notification(
                try container.decode(NotificationPayload.self, forKey: .payload))
        case "presenceUpdate":
            self = .presenceUpdate(
                try container.decode(PresenceUpdatePayload.self, forKey: .payload))
        case "presenceSnapshot":
            self = .presenceSnapshot(
                try container.decode(PresenceSnapshotPayload.self, forKey: .payload))
        case "conversationUnread":
            self = .conversationUnread(
                try container.decode(ConversationUnreadPayload.self, forKey: .payload))
        case "conversationUnreadError":
            self = .conversationUnreadError(
                try container.decode(ConversationUnreadErrorPayload.self, forKey: .payload))
        case "conversationStates":
            self = .conversationStates(
                try container.decode(ConversationStatesPayload.self, forKey: .payload))
        case "conversationStatesError":
            self = .conversationStatesError(
                try container.decode(ConversationUnreadErrorPayload.self, forKey: .payload))
        case "threadUpdate":
            self = .threadUpdate(try container.decode(ThreadUpdatePayload.self, forKey: .payload))
        case "threadMembershipChanged":
            self = .threadMembershipChanged(
                try container.decode(ThreadMembershipChangedPayload.self, forKey: .payload))
        case "chatArchiveStateChanged":
            self = .chatArchiveStateChanged(
                try container.decode(ChatArchiveStateChangedPayload.self, forKey: .payload))
        case "readReceiptChanged":
            self = .readReceiptChanged(
                try container.decode(ReadReceiptChangedPayload.self, forKey: .payload))
        case "pinAdded":
            self = .pinAdded(try container.decode(PinUpdatePayload.self, forKey: .payload))
        case "threadPinAdded":
            self = .threadPinAdded(try container.decode(PinUpdatePayload.self, forKey: .payload))
        case "pinRemoved":
            self = .pinRemoved(try container.decode(PinUpdatePayload.self, forKey: .payload))
        case "threadPinRemoved":
            self = .threadPinRemoved(try container.decode(PinUpdatePayload.self, forKey: .payload))
        case "stickerPackOrderUpdated":
            self = .stickerPackOrderUpdated(
                try container.decode(StickerPackOrderUpdatePayload.self, forKey: .payload))
        case "friendRequestReceived":
            self = .friendRequestReceived(
                try container.decode(FriendRequestReceivedPayload.self, forKey: .payload))
        case "friendRequestResolved":
            self = .friendRequestResolved(
                try container.decode(FriendRequestResolvedPayload.self, forKey: .payload))
        case "friendshipRemoved":
            self = .friendshipRemoved(
                try container.decode(FriendshipRemovedPayload.self, forKey: .payload))
        default: self = .unknown(type: type)
        }
    }
}

public enum NotificationType: String, Codable, Hashable, Sendable {
    case mention
    case reply
    case reaction
}

/// Recipient-directed activity, distinct from the public reaction summary update.
public struct NotificationPayload: Decodable, Sendable {
    public let actorName: String?
    public let actorUid: Int32
    public let chatId: String
    public let messageId: MessageID
    public let notificationType: NotificationType
    public let threadRootId: MessageID?

    public init(
        actorName: String? = nil, actorUid: Int32, chatId: String, messageId: MessageID,
        notificationType: NotificationType, threadRootId: MessageID? = nil
    ) {
        self.actorName = actorName
        self.actorUid = actorUid
        self.chatId = chatId
        self.messageId = messageId
        self.notificationType = notificationType
        self.threadRootId = threadRootId
    }
}

public struct ReadReceiptChangedPayload: Decodable, Sendable {
    public let chatId: String
    public let privacyChanged: Bool?
    public let readerUid: Int32?
    public let threadRootId: MessageID?

    public init(
        chatId: String, privacyChanged: Bool? = nil, readerUid: Int32? = nil,
        threadRootId: MessageID? = nil
    ) {
        self.chatId = chatId
        self.privacyChanged = privacyChanged
        self.readerUid = readerUid
        self.threadRootId = threadRootId
    }
}

public struct BulkDeletedPayload: Decodable, Sendable {
    public let chatId: String
    public let messageIds: [MessageID]
    public let complete: Bool?
    public let threadRootIds: [MessageID]?

    public init(
        chatId: String, messageIds: [MessageID], complete: Bool? = nil,
        threadRootIds: [MessageID]? = nil
    ) {
        self.chatId = chatId
        self.messageIds = messageIds
        self.complete = complete
        self.threadRootIds = threadRootIds
    }
}

public struct ReactionUpdatePayload: Decodable, Sendable {
    public let messageId: MessageID
    public let chatId: String
    public let reactions: [ReactionSummary]

    public init(messageId: MessageID, chatId: String, reactions: [ReactionSummary]) {
        self.messageId = messageId
        self.chatId = chatId
        self.reactions = reactions
    }
}

public struct ThreadUpdatePayload: Decodable, Sendable {
    public let threadRootId: String
    public let chatId: String
    public let lastReplyAt: Date
    public let replyCount: Int64

    public init(threadRootId: String, chatId: String, lastReplyAt: Date, replyCount: Int64) {
        self.threadRootId = threadRootId
        self.chatId = chatId
        self.lastReplyAt = lastReplyAt
        self.replyCount = replyCount
    }
}

public struct ChatArchiveStateChangedPayload: Decodable, Sendable {
    public let chatId: String
    public let archived: Bool
    public let mutedUntil: Date?

    public init(chatId: String, archived: Bool, mutedUntil: Date? = nil) {
        self.chatId = chatId
        self.archived = archived
        self.mutedUntil = mutedUntil
    }
}

public struct PresenceUpdatePayload: Decodable, Sendable {
    public let activeConnections: UInt32

    public init(activeConnections: UInt32) {
        self.activeConnections = activeConnections
    }
}

/// A watched user's socket presence and optional last recorded HTTP activity.
public struct UserPresenceResponse: Decodable, Equatable, Sendable {
    public let uid: Int32
    public let online: Bool
    public let lastSeenAt: Date?

    public init(uid: Int32, online: Bool, lastSeenAt: Date? = nil) {
        self.uid = uid
        self.online = online
        self.lastSeenAt = lastSeenAt
    }
}

/// Aggregate presence for a regular group; chat IDs remain opaque decimal strings.
public struct GroupPresenceResponse: Decodable, Equatable, Sendable {
    public let chatId: String
    public let memberCount: UInt32
    public let onlineCount: UInt32

    public init(chatId: String, memberCount: UInt32, onlineCount: UInt32) {
        self.chatId = chatId
        self.memberCount = memberCount
        self.onlineCount = onlineCount
    }
}

/// An absolute watch response. Omitted entities are unavailable or unauthorized.
public struct PresenceSnapshotPayload: Decodable, Sendable {
    /// Echoed when supplied by the client; absence is distinct from zero.
    public let requestId: UInt64?
    public let users: [UserPresenceResponse]
    public let groups: [GroupPresenceResponse]

    public init(
        requestId: UInt64? = nil, users: [UserPresenceResponse], groups: [GroupPresenceResponse]
    ) {
        self.requestId = requestId
        self.users = users
        self.groups = groups
    }
}

public struct ThreadMembershipChangedPayload: Decodable, Sendable {
    public let threadRootId: String
    public let chatId: String
    public let status: ThreadSubscriptionStatus?

    public init(threadRootId: String, chatId: String, status: ThreadSubscriptionStatus? = nil) {
        self.threadRootId = threadRootId
        self.chatId = chatId
        self.status = status
    }
}

public struct PinUpdatePayload: Decodable, Sendable {
    public let chatId: String
    public let pinId: String
    public let messageId: MessageID
    public let threadRootId: String?
    public let pin: PinResponse?

    public init(
        chatId: String, pinId: String, messageId: MessageID, threadRootId: String? = nil,
        pin: PinResponse? = nil
    ) {
        self.chatId = chatId
        self.pinId = pinId
        self.messageId = messageId
        self.threadRootId = threadRootId
        self.pin = pin
    }
}

public struct PinResponse: Decodable, Sendable {
    public let id: String
    public let chatId: String
    public let threadRootId: String?
    public let message: MessageResponse
    public let pinnedBy: Int32
    public let pinnedAt: Date
    public let expiresAt: Date?

    public init(
        id: String, chatId: String, threadRootId: String? = nil, message: MessageResponse,
        pinnedBy: Int32, pinnedAt: Date, expiresAt: Date? = nil
    ) {
        self.id = id
        self.chatId = chatId
        self.threadRootId = threadRootId
        self.message = message
        self.pinnedBy = pinnedBy
        self.pinnedAt = pinnedAt
        self.expiresAt = expiresAt
    }
}

public struct StickerPackOrderUpdatePayload: Decodable, Sendable {
    public let order: [StickerPackOrderItem]

    public init(order: [StickerPackOrderItem]) {
        self.order = order
    }
}

public struct FriendRequestReceivedPayload: Decodable, Sendable {
    public let fromUid: Int32

    public init(fromUid: Int32) {
        self.fromUid = fromUid
    }
}

public struct FriendRequestResolvedPayload: Decodable, Sendable {
    public let requestId: String
    public let status: FriendRequestStatus
    public let byUid: Int32

    public init(requestId: String, status: FriendRequestStatus, byUid: Int32) {
        self.requestId = requestId
        self.status = status
        self.byUid = byUid
    }
}

public struct FriendshipRemovedPayload: Decodable, Sendable {
    public let actorUid: Int32

    public init(actorUid: Int32) {
        self.actorUid = actorUid
    }
}

public enum FriendRequestStatus: String, Decodable, Sendable {
    case pending, archived, accepted, rejected
}
