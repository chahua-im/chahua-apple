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

public struct LocalOutgoingAttachment: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var generation: String
    public var position: Int
    public var sourcePath: String
    public var preparedPath: String?
    public var previewPath: String
    public var fileName: String
    public var mimeType: String
    public var width: Int
    public var height: Int
    public var byteCount: Int64
    public var attachmentID: String?
    public var error: String?
    public var isUploaded: Bool { attachmentID != nil }
    public var uploadPath: String { preparedPath ?? sourcePath }

    public init(id: String, generation: String, position: Int, sourcePath: String, preparedPath: String? = nil, previewPath: String, fileName: String, mimeType: String, width: Int, height: Int, byteCount: Int64, attachmentID: String? = nil, error: String? = nil) {
        self.id = id
        self.generation = generation
        self.position = position
        self.sourcePath = sourcePath
        self.preparedPath = preparedPath
        self.previewPath = previewPath
        self.fileName = fileName
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.byteCount = byteCount
        self.attachmentID = attachmentID
        self.error = error
    }
}

public struct LocalDraft: Sendable, Equatable {
    public let text: String
    public let replyToMessage: MessagePreview?
    public let editRevision: Int64
    public let updatedAt: Date
    public var itemID: String? = nil
    public var attachments: [LocalOutgoingAttachment] = []
    public var compressionEnabled: Bool = true
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
    public var attachments: [LocalOutgoingAttachment] = []
    public var isBlocked: Bool = false
    public var editRevision: Int64 = 0
    public var compressionEnabled: Bool = true
    /// Once claimed, even an interrupted or failed request must replay the same payload.
    public var dispatchClaimed: Bool = false

    public var isReadyForDispatch: Bool {
        attachments.allSatisfy { $0.attachmentID != nil && $0.error == nil }
    }

    public var body: CreateMessageBody {
        precondition(isReadyForDispatch, "An unresolved attachment must never be omitted from a message")
        return CreateMessageBody(
            messageType: .text, clientGeneratedId: clientGeneratedID, message: text,
            attachmentIds: attachments.sorted { $0.position < $1.position }.map { $0.attachmentID! },
            replyToId: replyToMessage?.id
        )
    }
}

public struct LocalConversationSnapshot: Sendable, Equatable {
    public let chatID: String
    public let threadID: String?
    public var conversationKey: ConversationKey { ConversationKey(chatID: chatID, threadID: threadID) }
    public let revision: Int64
    public let draft: LocalDraft
    public let outgoing: [LocalOutgoingMessage]
    public var composingItem: LocalOutgoingMessage? = nil
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
    case notTail
    case dispatchAlreadyClaimed
    case invalidAttachments
}
