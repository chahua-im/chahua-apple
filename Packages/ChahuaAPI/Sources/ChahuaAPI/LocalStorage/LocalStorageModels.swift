import CryptoKit
import Foundation

public struct ConversationKey: Hashable, Codable, Sendable {
    public let chatID: String
    public let threadID: String?

    public init(chatID: String, threadID: String? = nil) {
        self.chatID = chatID
        self.threadID = threadID
    }
}

public struct LocalStorageScope: Sendable {
    public let apiBaseURL: URL
    public let userID: Int32

    public init(apiBaseURL: URL, userID: Int32) {
        self.apiBaseURL = apiBaseURL
        self.userID = userID
    }

    public func directory(under root: URL) -> URL {
        let namespace = SHA256.hash(data: Data(apiBaseURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("app.chahua.chat/Accounts", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent(String(userID), isDirectory: true)
    }
}

public struct LocalDraft: Sendable, Equatable {
    public let text: String
    public let replyToMessage: MessagePreview?
    public let editRevision: Int64
    public let updatedAt: Date
}

public struct LocalOutgoingMessage: Sendable, Equatable {
    public enum State: String, Sendable { case queued, sending, failed }
    public let clientGeneratedID: String
    public let chatID: String
    public let threadID: String?
    public var conversationKey: ConversationKey { ConversationKey(chatID: chatID, threadID: threadID) }
    public let senderID: Int32
    public let text: String
    public let replyToMessage: MessagePreview?
    public let enqueuedAt: Date
    public let enqueueSequence: Int64
    public let dispatchOrder: Int64
    public let state: State
}

public struct LocalConversationSnapshot: Sendable, Equatable {
    public let chatID: String
    public let threadID: String?
    public var conversationKey: ConversationKey { ConversationKey(chatID: chatID, threadID: threadID) }
    public let revision: Int64
    public let draft: LocalDraft
    public let outgoing: [LocalOutgoingMessage]
}

public struct LocalOutgoingClaim: Sendable {
    public let snapshot: LocalConversationSnapshot
    public let message: LocalOutgoingMessage?
}

public enum OutgoingRetryScope: Sendable { case message, messageAndSubsequent }

public enum LocalStorageError: Error, Sendable {
    case unsupportedSchema
    case corruptRecord
    case blankMessage
    case staleDraft
}
