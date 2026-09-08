import Foundation

/// Every known server frame is typed; unknown future names do not decode their payload.
public enum RealtimeServerEvent: Decodable, Sendable {
    case pong
    case message(MessageResponse)
    case messageUpdated(MessageResponse)
    case messageDeleted(MessageResponse)
    case messagesBulkDeleted(BulkDeletedPayload)
    case reactionUpdated(ReactionUpdatePayload)
    case presenceUpdate(PresenceUpdatePayload)
    case threadUpdate(ThreadUpdatePayload)
    case threadMembershipChanged(ThreadMembershipChangedPayload)
    case chatArchiveStateChanged(ChatArchiveStateChangedPayload)
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
        case "message": self = .message(try container.decode(MessageResponse.self, forKey: .payload))
        case "messageUpdated": self = .messageUpdated(try container.decode(MessageResponse.self, forKey: .payload))
        case "messageDeleted": self = .messageDeleted(try container.decode(MessageResponse.self, forKey: .payload))
        case "messagesBulkDeleted": self = .messagesBulkDeleted(try container.decode(BulkDeletedPayload.self, forKey: .payload))
        case "reactionUpdated": self = .reactionUpdated(try container.decode(ReactionUpdatePayload.self, forKey: .payload))
        case "presenceUpdate": self = .presenceUpdate(try container.decode(PresenceUpdatePayload.self, forKey: .payload))
        case "threadUpdate": self = .threadUpdate(try container.decode(ThreadUpdatePayload.self, forKey: .payload))
        case "threadMembershipChanged": self = .threadMembershipChanged(try container.decode(ThreadMembershipChangedPayload.self, forKey: .payload))
        case "chatArchiveStateChanged": self = .chatArchiveStateChanged(try container.decode(ChatArchiveStateChangedPayload.self, forKey: .payload))
        case "pinAdded": self = .pinAdded(try container.decode(PinUpdatePayload.self, forKey: .payload))
        case "threadPinAdded": self = .threadPinAdded(try container.decode(PinUpdatePayload.self, forKey: .payload))
        case "pinRemoved": self = .pinRemoved(try container.decode(PinUpdatePayload.self, forKey: .payload))
        case "threadPinRemoved": self = .threadPinRemoved(try container.decode(PinUpdatePayload.self, forKey: .payload))
        case "stickerPackOrderUpdated": self = .stickerPackOrderUpdated(try container.decode(StickerPackOrderUpdatePayload.self, forKey: .payload))
        case "friendRequestReceived": self = .friendRequestReceived(try container.decode(FriendRequestReceivedPayload.self, forKey: .payload))
        case "friendRequestResolved": self = .friendRequestResolved(try container.decode(FriendRequestResolvedPayload.self, forKey: .payload))
        case "friendshipRemoved": self = .friendshipRemoved(try container.decode(FriendshipRemovedPayload.self, forKey: .payload))
        default: self = .unknown(type: type)
        }
    }
}

public struct BulkDeletedPayload: Decodable, Sendable {
    public let chatId: String
    public let messageIds: [String]

    public init(chatId: String, messageIds: [String]) {
        self.chatId = chatId
        self.messageIds = messageIds
    }
}

public struct ReactionUpdatePayload: Decodable, Sendable {
    public let messageId: String
    public let chatId: String
    public let reactions: [ReactionSummary]

    public init(messageId: String, chatId: String, reactions: [ReactionSummary]) {
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

public struct ThreadMembershipChangedPayload: Decodable, Sendable {
    public let threadRootId: String
    public let chatId: String

    public init(threadRootId: String, chatId: String) {
        self.threadRootId = threadRootId
        self.chatId = chatId
    }
}

public struct PinUpdatePayload: Decodable, Sendable {
    public let chatId: String
    public let pinId: String
    public let messageId: String
    public let threadRootId: String?
    public let pin: PinResponse?

    public init(chatId: String, pinId: String, messageId: String, threadRootId: String? = nil, pin: PinResponse? = nil) {
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

    public init(id: String, chatId: String, threadRootId: String? = nil, message: MessageResponse, pinnedBy: Int32, pinnedAt: Date, expiresAt: Date? = nil) {
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
