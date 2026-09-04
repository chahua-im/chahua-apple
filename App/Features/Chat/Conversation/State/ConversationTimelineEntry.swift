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

    var serverID: String? {
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

    var messageType: MessageType {
        switch self {
        case .remote(let message): message.messageType
        case .pending(let pending): pending.body.messageType
        }
    }

    var text: String? {
        switch self {
        case .remote(let message): message.message
        case .pending(let pending): pending.body.message
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
}

extension ConversationMessageStableKey {
    init(clientGeneratedID: String, fallbackServerID: String? = nil) {
        if clientGeneratedID.isEmpty, let fallbackServerID {
            self = .server(fallbackServerID)
        } else {
            self = .clientGenerated(clientGeneratedID)
        }
    }

    var sortValue: String {
        switch self {
        case .clientGenerated(let value): "c:\(value)"
        case .server(let value): "s:\(value)"
        }
    }
}
