import ChahuaAPI
import Foundation

enum ConversationTimelineEntry: Hashable {
    case remote(MessageResponse)
    case pending(PendingOutgoingMessage)

    var stableKey: ConversationMessageStableKey {
        switch self {
        case .remote(let message): message.timelineStableKey
        case .pending(let pending): .clientGenerated(pending.clientGeneratedID)
        }
    }

    var serverID: MessageID? {
        guard case .remote(let message) = self else { return nil }
        return message.id
    }

    var createdAt: Date {
        switch self {
        case .remote(let message): message.createdAt
        case .pending(let pending): pending.enqueuedAt
        }
    }

    var senderID: Int32 {
        switch self {
        case .remote(let message): message.sender.uid
        case .pending(let pending): pending.senderID
        }
    }

    /// Display identity of the sender; nil only for a pending send without a known profile.
    var sender: User? {
        switch self {
        case .remote(let message): message.sender
        case .pending(let pending): pending.sender
        }
    }

    var messageType: MessageType {
        switch self {
        case .remote(let message): message.messageType
        case .pending(let pending): pending.messageType
        }
    }

    var text: String? {
        switch self {
        case .remote(let message): message.message
        case .pending(let pending): pending.optimisticMessage?.message ?? pending.body.message
        }
    }

    var sticker: MessageStickerResponse? {
        switch self {
        case .remote(let message): message.isDeleted ? nil : message.sticker
        case .pending(let pending): pending.optimisticMessage?.sticker ?? pending.sticker
        }
    }

    var replyToMessage: MessagePreview? {
        switch self {
        case .remote(let message): message.replyToMessage
        case .pending(let pending): pending.replyToMessage
        }
    }

    var displayState: ConversationMessageDisplayState {
        switch self {
        case .remote: .delivered
        case .pending(let pending):
            switch pending.state {
            case .queued: .queued
            case .sending: .sending
            case .failed: .failed
            }
        }
    }

    var remoteMessage: MessageResponse? {
        guard case .remote(let message) = self else { return nil }
        return message
    }

    /// Rendering may use optimistic forwarding content without granting it remote identity.
    var presentationMessage: MessageResponse? {
        switch self {
        case .remote(let message): message
        case .pending(let pending): pending.optimisticMessage
        }
    }

    var forwardedFrom: ForwardedFromInfo? { presentationMessage?.forwardedFrom }
    var forwardedPreview: ForwardedMessagesPreviewResponse? {
        presentationMessage?.forwardedPreview
    }
    var attachments: [AttachmentResponse] { presentationMessage?.attachments ?? [] }
}

extension ConversationMessageStableKey {
    init(clientGeneratedID: String, fallbackServerID: MessageID? = nil) {
        if clientGeneratedID.isEmpty, let fallbackServerID {
            self = .server(fallbackServerID)
        } else {
            self = .clientGenerated(clientGeneratedID)
        }
    }
}
