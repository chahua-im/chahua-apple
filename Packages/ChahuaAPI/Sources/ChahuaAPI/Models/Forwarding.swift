import Foundation

public struct ForwardedFromInfo: Codable, Hashable, Sendable {
    public let sender: User
    public let originalChatId: String
    public let originalMessageId: MessageID
    public let originalReplyTo: MessagePreview?

    public init(
        sender: User, originalChatId: String, originalMessageId: MessageID,
        originalReplyTo: MessagePreview? = nil
    ) {
        self.sender = sender
        self.originalChatId = originalChatId
        self.originalMessageId = originalMessageId
        self.originalReplyTo = originalReplyTo
    }
}

public struct ForwardMessageBody: Codable, Hashable, Sendable {
    public let sourceChatId: String
    public let clientGeneratedId: String
    public let threadId: String?
    public let allowPlaceholders: Bool

    public init(
        sourceChatId: String, clientGeneratedId: String, threadId: String? = nil,
        allowPlaceholders: Bool = false
    ) {
        self.sourceChatId = sourceChatId
        self.clientGeneratedId = clientGeneratedId
        self.threadId = threadId
        self.allowPlaceholders = allowPlaceholders
    }
}

public struct ForwardMessagesBody: Codable, Hashable, Sendable {
    public let sourceChatId: String
    public let messageIds: [MessageID]
    public let clientGeneratedId: String
    public let threadId: String?
    public let allowPlaceholders: Bool

    public init(
        sourceChatId: String, messageIds: [MessageID], clientGeneratedId: String,
        threadId: String? = nil, allowPlaceholders: Bool = false
    ) {
        self.sourceChatId = sourceChatId
        self.messageIds = messageIds
        self.clientGeneratedId = clientGeneratedId
        self.threadId = threadId
        self.allowPlaceholders = allowPlaceholders
    }
}

public struct ForwardedMessagesPreviewResponse: Codable, Hashable, Sendable {
    public let total: Int
    public let containsForwardedMessages: Bool
    public let messages: [ForwardedMessagePreviewResponse]

    public init(
        total: Int, containsForwardedMessages: Bool, messages: [ForwardedMessagePreviewResponse]
    ) {
        self.total = total
        self.containsForwardedMessages = containsForwardedMessages
        self.messages = messages
    }
}

public struct ForwardedMessagePreviewResponse: Codable, Hashable, Sendable {
    public let originalMessageId: MessageID
    public let originalChatId: String
    public let message: String?
    public let messageType: MessageType
    public let sender: User
    public let originalCreatedAt: Date
    public let attachments: [MessagePreviewAttachment]
    public let sticker: MessagePreviewSticker?
    public let mentions: [MentionInfo]

    public init(
        originalMessageId: MessageID, originalChatId: String, message: String?,
        messageType: MessageType, sender: User, originalCreatedAt: Date,
        attachments: [MessagePreviewAttachment] = [], sticker: MessagePreviewSticker? = nil,
        mentions: [MentionInfo] = []
    ) {
        self.originalMessageId = originalMessageId
        self.originalChatId = originalChatId
        self.message = message
        self.messageType = messageType
        self.sender = sender
        self.originalCreatedAt = originalCreatedAt
        self.attachments = attachments
        self.sticker = sticker
        self.mentions = mentions
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        originalMessageId = try c.decode(MessageID.self, forKey: .originalMessageId)
        originalChatId = try c.decode(String.self, forKey: .originalChatId)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        messageType = try c.decode(MessageType.self, forKey: .messageType)
        sender = try c.decode(User.self, forKey: .sender)
        originalCreatedAt = try c.decode(Date.self, forKey: .originalCreatedAt)
        attachments = try c.decode([MessagePreviewAttachment].self, forKey: .attachments)
        sticker = try c.decodeIfPresent(MessagePreviewSticker.self, forKey: .sticker)
        mentions = try c.decodeIfPresent([MentionInfo].self, forKey: .mentions) ?? []
    }

    public var replyPreview: MessagePreview {
        MessagePreview(
            id: originalMessageId, clientGeneratedId: "captured-\(originalMessageId)",
            createdAt: originalCreatedAt, sender: sender, messageType: messageType,
            attachments: attachments, mentions: mentions, message: message, sticker: sticker)
    }
}

public enum ForwardedReplyResponse: Codable, Hashable, Sendable {
    case redacted
    case `internal`(originalMessageId: MessageID, preview: ForwardedMessagePreviewResponse)

    private enum CodingKeys: String, CodingKey { case kind, originalMessageId, preview }
    private enum Kind: String, Codable { case redacted, `internal` }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .redacted: self = .redacted
        case .internal:
            self = .internal(
                originalMessageId: try c.decode(MessageID.self, forKey: .originalMessageId),
                preview: try c.decode(ForwardedMessagePreviewResponse.self, forKey: .preview))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .redacted: try c.encode(Kind.redacted, forKey: .kind)
        case .internal(let id, let preview):
            try c.encode(Kind.internal, forKey: .kind)
            try c.encode(id, forKey: .originalMessageId)
            try c.encode(preview, forKey: .preview)
        }
    }
}

public struct ForwardedMessagesResponse: Codable, Hashable, Sendable {
    public let total: Int
    public let messages: [ForwardedMessageResponse]

    public init(total: Int, messages: [ForwardedMessageResponse]) {
        self.total = total
        self.messages = messages
    }
}

public struct ForwardedMessageResponse: Codable, Hashable, Sendable {
    public let originalMessageId: MessageID
    public let originalChatId: String
    public let message: String?
    public let messageType: MessageType
    public let sender: User
    public let originalCreatedAt: Date
    public let sticker: MessageStickerResponse?
    public let reply: ForwardedReplyResponse?
    public let attachments: [AttachmentResponse]
    public let mentions: [MentionInfo]
    public let forwardedBundleId: String?
    public let forwardedPreview: ForwardedMessagesPreviewResponse?

    public init(
        originalMessageId: MessageID, originalChatId: String, message: String?,
        messageType: MessageType, sender: User, originalCreatedAt: Date,
        sticker: MessageStickerResponse? = nil, reply: ForwardedReplyResponse? = nil,
        attachments: [AttachmentResponse] = [], mentions: [MentionInfo] = [],
        forwardedBundleId: String? = nil, forwardedPreview: ForwardedMessagesPreviewResponse? = nil
    ) {
        self.originalMessageId = originalMessageId
        self.originalChatId = originalChatId
        self.message = message
        self.messageType = messageType
        self.sender = sender
        self.originalCreatedAt = originalCreatedAt
        self.sticker = sticker
        self.reply = reply
        self.attachments = attachments
        self.mentions = mentions
        self.forwardedBundleId = forwardedBundleId
        self.forwardedPreview = forwardedPreview
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        originalMessageId = try c.decode(MessageID.self, forKey: .originalMessageId)
        originalChatId = try c.decode(String.self, forKey: .originalChatId)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        messageType = try c.decode(MessageType.self, forKey: .messageType)
        sender = try c.decode(User.self, forKey: .sender)
        originalCreatedAt = try c.decode(Date.self, forKey: .originalCreatedAt)
        sticker = try c.decodeIfPresent(MessageStickerResponse.self, forKey: .sticker)
        reply = try c.decodeIfPresent(ForwardedReplyResponse.self, forKey: .reply)
        attachments = try c.decode([AttachmentResponse].self, forKey: .attachments)
        mentions = try c.decodeIfPresent([MentionInfo].self, forKey: .mentions) ?? []
        forwardedBundleId = try c.decodeIfPresent(String.self, forKey: .forwardedBundleId)
        forwardedPreview = try c.decodeIfPresent(
            ForwardedMessagesPreviewResponse.self, forKey: .forwardedPreview)
    }

    /// A captured value only: never resolves or refreshes the original live message.
    public var timelineMessage: MessageResponse {
        let replyPreview: MessagePreview?
        if let reply, case .internal(_, let preview) = reply {
            replyPreview = preview.replyPreview
        } else {
            replyPreview = nil
        }
        return MessageResponse(
            id: originalMessageId, chatId: originalChatId,
            clientGeneratedId: "captured-\(originalMessageId)", messageType: messageType,
            sender: sender, createdAt: originalCreatedAt, hasAttachments: !attachments.isEmpty,
            attachments: attachments, mentions: mentions, message: message,
            replyToMessage: replyPreview, sticker: sticker, forwardedBundleId: forwardedBundleId,
            forwardedPreview: forwardedPreview)
    }
}
