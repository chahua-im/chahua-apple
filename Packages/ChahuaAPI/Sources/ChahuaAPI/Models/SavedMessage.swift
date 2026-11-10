import Foundation

/// Immutable server-captured content. Never hydrate these fields from the original message.
public struct SavedMessageResponse: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let originalMessageId: MessageID
    public let originalChatId: String
    public let originalThreadRootId: MessageID?
    public let originalReplyToMessageId: MessageID?
    public let originalSenderUid: Int32
    public let originalCreatedAt: Date
    public let savedAt: Date
    public let messageType: MessageType
    public let message: String?
    public let mentions: [MentionInfo]
    public let attachments: [SavedAttachmentSnapshot]
    public let sender: User
    public let chat: SavedChatSnapshot
    public let sticker: SavedStickerSnapshot?
    public let forwardedBundleId: String?
    public let canLocateContext: Bool
    public let metadata: MessageMetadataResponse?

    public init(
        id: String, originalMessageId: MessageID, originalChatId: String,
        originalThreadRootId: MessageID? = nil, originalReplyToMessageId: MessageID? = nil,
        originalSenderUid: Int32, originalCreatedAt: Date, savedAt: Date,
        messageType: MessageType, message: String? = nil, mentions: [MentionInfo] = [],
        attachments: [SavedAttachmentSnapshot] = [], sender: User, chat: SavedChatSnapshot,
        sticker: SavedStickerSnapshot? = nil, forwardedBundleId: String? = nil,
        canLocateContext: Bool, metadata: MessageMetadataResponse? = nil
    ) {
        self.id = id
        self.originalMessageId = originalMessageId
        self.originalChatId = originalChatId
        self.originalThreadRootId = originalThreadRootId
        self.originalReplyToMessageId = originalReplyToMessageId
        self.originalSenderUid = originalSenderUid
        self.originalCreatedAt = originalCreatedAt
        self.savedAt = savedAt
        self.messageType = messageType
        self.message = message
        self.mentions = mentions
        self.attachments = attachments
        self.sender = sender
        self.chat = chat
        self.sticker = sticker
        self.forwardedBundleId = forwardedBundleId
        self.canLocateContext = canLocateContext
        self.metadata = metadata
    }

    /// Reuses captured-record rendering without reading or subscribing to a live chat.
    public var capturedRecord: ForwardedMessageResponse {
        ForwardedMessageResponse(
            originalMessageId: originalMessageId, originalChatId: originalChatId,
            message: message, messageType: messageType, sender: sender,
            originalCreatedAt: originalCreatedAt,
            sticker: sticker.map {
                MessageStickerResponse(
                    id: $0.id, emoji: $0.emoji, createdAt: originalCreatedAt, isFavorited: nil,
                    media: MessageStickerMediaResponse(
                        id: $0.id, url: $0.mediaUrl, contentType: $0.mediaContentType, size: 0),
                    name: $0.name)
            },
            attachments: attachments.sorted { $0.order < $1.order }.map {
                AttachmentResponse(
                    id: $0.id, url: $0.url, kind: $0.kind, size: $0.size,
                    fileName: $0.fileName, width: $0.width, height: $0.height)
            }, mentions: mentions, forwardedBundleId: forwardedBundleId, metadata: metadata)
    }
}

public struct SavedChatSnapshot: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let avatarUrl: String?
}

public struct SavedAttachmentSnapshot: Codable, Hashable, Sendable {
    public let id: String
    public let externalReference: String
    public let fileName: String
    public let kind: String
    public let size: Int64
    public let url: String
    public let width: Int32?
    public let height: Int32?
    public let order: Int
}

public struct SavedStickerSnapshot: Codable, Hashable, Sendable {
    public let id: String
    public let emoji: String
    public let name: String?
    public let mediaUrl: String
    public let mediaContentType: String
}

public struct ListSavedMessagesResponse: Codable, Hashable, Sendable {
    public let savedMessages: [SavedMessageResponse]
    public let nextCursor: String?
}
