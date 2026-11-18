import ChahuaAPI
import Foundation

enum OutboxPhase: Codable, Hashable, Sendable {
    case preparing(progress: [String: Double])
    case queued(blockedBy: String?)
    case sending
    case failed(OutboxFailure, nextRetry: Date?)

    var preparationProgress: [String: Double] {
        if case .preparing(let progress) = self { return progress }
        return [:]
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

extension OutboxFailure.Reason {
    var displayDetail: String {
        switch self {
        case .unknownOutcome:
            AppLanguage.localized("Delivery could not be confirmed. The message may already have been sent.")
        case .network:
            AppLanguage.localized("A network or server error interrupted this message.")
        case .conflict:
            AppLanguage.localized("A message with this ID already exists, but its delivery could not be verified.")
        case .invalidReceipt:
            AppLanguage.localized("The server returned a response that did not match this message.")
        case .authentication:
            AppLanguage.localized("Sign in again to send this message.")
        case .rejected:
            AppLanguage.localized("The server rejected this message.")
        case .attachment:
            AppLanguage.localized("An attachment could not be prepared or uploaded.")
        case .tooLarge(let bytes):
            AppLanguage.localized(
                "The attachment exceeds the \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) limit.")
        case .speakingRestricted(let mode):
            mode.restrictionExplanation
        }
    }
}

extension LocalOutgoingAttachment {
    func timelinePreparationStatus(progress: Double?) -> String? {
        if failure != nil { return AppLanguage.localized("Upload failed") }
        if let progress, progress > 0, !isUploaded {
            return progress.formatted(.percent.precision(.fractionLength(0)))
        }
        return nil
    }
}

struct PendingOutgoingMessage: Codable, Hashable, Identifiable, Sendable {
    let chatID: String
    var threadID: String? = nil
    let clientGeneratedID: String
    let body: CreateMessageBody
    let enqueuedAt: Date
    let senderID: Int32
    /// The sender as displayed until acknowledgement, so a row never consults the session.
    var sender: User? = nil
    var phase: OutboxPhase
    var replyToMessage: MessagePreview? = nil
    var attachments: [LocalOutgoingAttachment] = []
    var sticker: MessageStickerResponse? = nil
    /// Captured forwarding content is immutable, including confirmed replacements.
    var forwardRequest: LocalForwardRequest? = nil

    var id: String { clientGeneratedID }
    var messageType: MessageType {
        guard let request = forwardRequest else { return body.messageType }
        return request.sources.count == 1 ? request.sources[0].messageType : .forwarded
    }

    var canEdit: Bool {
        guard forwardRequest == nil, messageType == .text || messageType == .file else {
            return false
        }
        switch phase {
        case .preparing, .queued: return true
        case .failed(let failure, _): return failure.stage == .preparation
        case .sending: return false
        }
    }

    var canRemove: Bool { phase != .sending }

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
                        sticker: source.replyPreview.sticker, mentions: source.mentions,
                        metadata: source.replyPreview.metadata)
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
            forwardedPreview: preview,
            metadata: single
                ? first.metadata.map {
                    MessageMetadataResponse(
                        linkPreviews: $0.linkPreviews.filter { $0.status == .ready })
                } : nil)
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
    case preparing
    case queued
    case sending
    case failed
}
