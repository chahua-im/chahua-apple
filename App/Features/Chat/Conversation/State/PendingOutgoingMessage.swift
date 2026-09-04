import ChahuaAPI
import Foundation

struct PendingOutgoingMessage: Codable, Hashable, Identifiable, Sendable {
    enum State: String, Codable, Hashable, Sendable {
        case queued
        case sending
        case failed
    }

    let chatID: String
    let clientGeneratedID: String
    let body: CreateMessageBody
    let enqueuedAt: Date
    let senderID: Int32
    var state: State

    var id: String { clientGeneratedID }
}

enum ConversationMessageDisplayState: Hashable {
    case delivered
    case queued
    case sending
    case failed
}
