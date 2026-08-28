import Foundation

public struct MessageResponse: Codable, Hashable, Sendable {
    public let id: String
    public let chatId: String
    public let clientGeneratedId: String
    public let messageType: MessageType
    public let sender: User
    public let createdAt: Date
    public let isEdited: Bool
    public let isDeleted: Bool
    public let hasAttachments: Bool
    public let attachments: [AttachmentResponse]
    public let reactions: [ReactionSummary]
    public let mentions: [MentionInfo]
    public let message: String?
    public let replyRootId: String?
    public let replyToMessage: MessagePreview?
    public let sticker: MessageStickerResponse?
    public let threadInfo: ThreadInfo?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        chatId = try container.decode(String.self, forKey: .chatId)
        clientGeneratedId = try container.decode(String.self, forKey: .clientGeneratedId)
        messageType = try container.decode(MessageType.self, forKey: .messageType)
        sender = try container.decode(User.self, forKey: .sender)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isEdited = try container.decode(Bool.self, forKey: .isEdited)
        isDeleted = try container.decode(Bool.self, forKey: .isDeleted)
        hasAttachments = try container.decode(Bool.self, forKey: .hasAttachments)
        attachments = try container.decode([AttachmentResponse].self, forKey: .attachments)
        reactions = try container.decode([ReactionSummary].self, forKey: .reactions)
        mentions = try container.decodeIfPresent([MentionInfo].self, forKey: .mentions) ?? []
        message = try container.decodeIfPresent(String.self, forKey: .message)
        replyRootId = try container.decodeIfPresent(String.self, forKey: .replyRootId)
        replyToMessage = try container.decodeIfPresent(MessagePreview.self, forKey: .replyToMessage)
        sticker = try container.decodeIfPresent(MessageStickerResponse.self, forKey: .sticker)
        threadInfo = try container.decodeIfPresent(ThreadInfo.self, forKey: .threadInfo)
    }
}

public struct MessagePreview: Codable, Hashable, Sendable {
    public let id: String
    public let clientGeneratedId: String
    public let createdAt: Date
    public let sender: User
    public let messageType: MessageType
    public let attachments: [MessagePreviewAttachment]
    public let mentions: [MentionInfo]
    public let isDeleted: Bool
    public let message: String?
    public let sticker: MessagePreviewSticker?
}

public struct MessagePreviewAttachment: Codable, Hashable, Sendable {
    public let kind: String
}

public struct MessagePreviewSticker: Codable, Hashable, Sendable {
    public let emoji: String
}

public struct AttachmentResponse: Codable, Hashable, Sendable {
    public let id: String
    public let url: String
    public let kind: String
    public let size: Int64
    public let fileName: String
    public let width: Int32?
    public let height: Int32?
}

public struct MessageStickerResponse: Codable, Hashable, Sendable {
    public let id: String
    public let emoji: String
    public let createdAt: Date
    public let isFavorited: Bool
    public let media: MessageStickerMediaResponse
    public let name: String?
    public let description: String?
}

public struct MessageStickerMediaResponse: Codable, Hashable, Sendable {
    public let id: String
    public let url: String
    public let contentType: String
    public let size: Int64
    public let width: Int32?
    public let height: Int32?
}

public struct ReactionSummary: Codable, Hashable, Sendable {
    public let emoji: String
    public let count: Int64
    public let reactedByMe: Bool?
    public let reactors: [ReactionReactor]?
}

public struct ReactionReactor: Codable, Hashable, Sendable {
    public let uid: Int32
    public let name: String?
    public let avatarUrl: String?
    public let sortIndex: Int32?
}

public struct ThreadInfo: Codable, Hashable, Sendable {
    public let replyCount: Int64
}

public struct ListMessagesResponse: Codable, Hashable, Sendable {
    public let messages: [MessageResponse]
    /// Use `olderCursor` and `newerCursor`; these fields are retained for backend compatibility.
    public let olderCursor: String?
    public let newerCursor: String?
    public let nextCursor: String?
    public let prevCursor: String?
}

public struct CreateMessageBody: Codable, Hashable, Sendable {
    public var messageType: MessageType
    public var clientGeneratedId: String
    public var message: String?
    public var attachmentIds: [String]
    public var replyToId: String?
    public var stickerId: String?

    public init(
        messageType: MessageType,
        clientGeneratedId: String,
        message: String? = nil,
        attachmentIds: [String] = [],
        replyToId: String? = nil,
        stickerId: String? = nil
    ) {
        self.messageType = messageType
        self.clientGeneratedId = clientGeneratedId
        self.message = message
        self.attachmentIds = attachmentIds
        self.replyToId = replyToId
        self.stickerId = stickerId
    }

    private enum CodingKeys: String, CodingKey {
        case messageType
        case clientGeneratedId
        case message
        case attachmentIds
        case replyToId
        case stickerId
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(messageType, forKey: .messageType)
        try container.encode(clientGeneratedId, forKey: .clientGeneratedId)
        try container.encodeIfPresent(message, forKey: .message)
        if !attachmentIds.isEmpty {
            try container.encode(attachmentIds, forKey: .attachmentIds)
        }
        try container.encodeIfPresent(replyToId, forKey: .replyToId)
        try container.encodeIfPresent(stickerId, forKey: .stickerId)
    }
}
