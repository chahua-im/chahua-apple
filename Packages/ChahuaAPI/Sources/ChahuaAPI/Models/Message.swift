import Foundation

/// Full message record returned by chat message endpoints.
///
/// Cache this value by its opaque `id` under its `chatId`. A list or reply
/// preview is represented by `MessagePreview` and must not be treated as a
/// complete message record.
public struct MessageResponse: Codable, Hashable, Sendable {
    /// Stable server message identifier.
    public let id: String
    /// Opaque identifier of the owning chat.
    public let chatId: String
    /// Caller-provided idempotency identifier from the send request.
    public let clientGeneratedId: String
    public let messageType: MessageType
    public let sender: User
    public let createdAt: Date
    public let isEdited: Bool
    public private(set) var isDeleted: Bool
    public private(set) var hasAttachments: Bool
    public private(set) var attachments: [AttachmentResponse]
    public private(set) var reactions: [ReactionSummary]
    /// Missing wire values decode as an empty array.
    public private(set) var mentions: [MentionInfo]
    public private(set) var message: String?
    public let replyRootId: String?
    public private(set) var replyToMessage: MessagePreview?
    public private(set) var sticker: MessageStickerResponse?
    public private(set) var threadInfo: ThreadInfo?

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

    public func replacingReactions(_ reactions: [ReactionSummary]) -> Self {
        guard !isDeleted else { return self }
        var copy = self
        copy.reactions = reactions
        return copy
    }

    public func replacingThreadReplyCount(_ count: Int64) -> Self {
        var copy = self
        copy.threadInfo = ThreadInfo(replyCount: count)
        return copy
    }

    public func redactedForDeletion() -> Self {
        var copy = self
        copy.isDeleted = true
        copy.message = nil
        copy.sticker = nil
        copy.hasAttachments = false
        copy.attachments = []
        copy.reactions = []
        copy.mentions = []
        return copy
    }

    public func normalizedForRealtime(currentUserID: Int32) -> Self {
        var copy = isDeleted ? redactedForDeletion() : self
        copy.reactions = copy.reactions.map { $0.normalizedForRealtime(currentUserID: currentUserID) }
        copy.sticker = copy.sticker?.normalizedForRealtime()
        return copy
    }

    public func redactingReplyPreview(messageIDs: Set<String>) -> Self {
        guard let preview = replyToMessage, messageIDs.contains(preview.id) else { return self }
        var copy = self
        copy.replyToMessage = preview.redactedForDeletion()
        return copy
    }
}

/// Reduced message projection embedded in chat-list and reply-context responses.
///
/// It carries display context only; fetch `MessageResponse` values for a
/// timeline or cache.
public struct MessagePreview: Codable, Hashable, Sendable {
    public let id: String
    public let clientGeneratedId: String
    public let createdAt: Date
    public let sender: User
    public let messageType: MessageType
    public private(set) var attachments: [MessagePreviewAttachment]
    public private(set) var mentions: [MentionInfo]
    public private(set) var isDeleted: Bool
    public private(set) var message: String?
    public private(set) var sticker: MessagePreviewSticker?

    public func redactedForDeletion() -> Self {
        var copy = self
        copy.isDeleted = true
        copy.message = nil
        copy.sticker = nil
        copy.attachments = []
        copy.mentions = []
        return copy
    }
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
    /// HTTP supplies recipient preference; realtime hydration cannot establish it.
    public private(set) var isFavorited: Bool?
    public let media: MessageStickerMediaResponse
    public let name: String?
    public let description: String?

    fileprivate func normalizedForRealtime() -> Self {
        var copy = self
        copy.isFavorited = nil
        return copy
    }
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
    public private(set) var reactedByMe: Bool?
    public let reactors: [ReactionReactor]?

    public func normalizedForRealtime(currentUserID: Int32) -> Self {
        var copy = self
        // Reactor lists are truncated: absence is unknown, never proof of false.
        copy.reactedByMe = reactors?.contains { $0.uid == currentUserID } == true ? true : nil
        return copy
    }
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

/// One message page returned by `GET /chats/{chatID}/messages`.
///
/// Use `olderCursor` and `newerCursor` for new paging code. `nextCursor` and
/// `prevCursor` remain for backend compatibility only.
public struct ListMessagesResponse: Codable, Hashable, Sendable {
    public let messages: [MessageResponse]
    public let olderCursor: String?
    public let newerCursor: String?
    public let nextCursor: String?
    public let prevCursor: String?
}

/// JSON body accepted by `POST /chats/{chatID}/messages`.
///
/// `messageType` and `clientGeneratedId` are always encoded. Empty
/// `attachmentIds` are omitted; all other optional fields are emitted only when
/// non-`nil`.
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
