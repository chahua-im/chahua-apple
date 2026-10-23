import ChahuaAPI
import Foundation

struct PendingOutgoingMessage: Codable, Hashable, Identifiable, Sendable {
    enum State: String, Codable, Hashable, Sendable {
        case queued
        case sending
        case failed
    }

    let chatID: String
    var threadID: String? = nil
    let clientGeneratedID: String
    let body: CreateMessageBody
    let enqueuedAt: Date
    let senderID: Int32
    /// The sender as displayed until acknowledgement, so a row never consults the session.
    var sender: User? = nil
    var state: State
    var replyToMessage: MessagePreview? = nil
    var attachments: [LocalOutgoingAttachment] = []
    var dispatchClaimed = false
    var editRevision: Int64 = 0
    var sticker: MessageStickerResponse? = nil
    /// Captured forwarding content is immutable, including confirmed replacements.
    var forwardRequest: LocalForwardRequest? = nil

    var id: String { clientGeneratedID }
    var messageType: MessageType {
        guard let request = forwardRequest else { return body.messageType }
        return request.sources.count == 1 ? request.sources[0].messageType : .forwarded
    }

    /// Display-only projection. Its source ID must never become a destination action target.
    var optimisticMessage: MessageResponse? {
        guard let request = forwardRequest, let first = request.sources.first else { return nil }
        let single = request.sources.count == 1
        let showsOrigin = single && first.messageType != .sticker && first.messageType != .forwarded
        let origin =
            showsOrigin
            ? first.forwardedFrom
                ?? ForwardedFromInfo(
                    sender: first.sender, originalChatId: first.chatId,
                    originalMessageId: first.id, originalReplyTo: first.replyToMessage)
            : nil
        let preview: ForwardedMessagesPreviewResponse?
        if single {
            preview = first.forwardedPreview
        } else {
            preview = ForwardedMessagesPreviewResponse(
                total: request.sources.count,
                containsForwardedMessages: request.sources.contains {
                    $0.messageType == .forwarded
                },
                messages: request.sources.prefix(3).map { source in
                    ForwardedMessagePreviewResponse(
                        originalMessageId: source.id, originalChatId: source.chatId,
                        message: source.message, messageType: source.messageType,
                        sender: source.sender, originalCreatedAt: source.createdAt,
                        attachments: source.replyPreview.attachments,
                        sticker: source.replyPreview.sticker, mentions: source.mentions)
                })
        }
        let media = single ? first.attachments : []
        return MessageResponse(
            id: first.id, chatId: chatID, clientGeneratedId: clientGeneratedID,
            messageType: messageType,
            sender: sender
                ?? User(uid: senderID, gender: 0, name: nil, avatarUrl: nil, userGroup: nil),
            createdAt: enqueuedAt, hasAttachments: !media.isEmpty, attachments: media,
            mentions: single ? first.mentions : [], message: single ? first.message : nil,
            replyRootId: threadID, sticker: single ? first.sticker : nil,
            forwardedFrom: origin, forwardedBundleId: single ? first.forwardedBundleId : nil,
            forwardedPreview: preview)
    }
}

/// Only the optimistic snapshot is replaced; requests always retain the original server IDs.
enum ForwardPlaceholderProjection {
    static func replacing(_ source: MessageResponse, reason: String) -> MessageResponse {
        MessageResponse(
            id: source.id, chatId: source.chatId, clientGeneratedId: source.clientGeneratedId,
            messageType: .placeholder, sender: source.sender, createdAt: source.createdAt,
            message: reason, replyRootId: source.replyRootId,
            replyToMessage: source.replyToMessage, forwardedFrom: source.forwardedFrom)
    }
}

enum ConversationMessageDisplayState: Hashable {
    case delivered
    case queued
    case sending
    case failed
}
