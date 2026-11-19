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
    public var failure: OutboxFailure.Reason?
    public var preservesOriginal: Bool?
    public var isFile: Bool { preservesOriginal == true }
    public var isUploaded: Bool { attachmentID != nil }
    public var isAudio: Bool { !isFile && mimeType.lowercased().hasPrefix("audio/") }
    public var uploadPath: String { preparedPath ?? sourcePath }

    public init(
        id: String, generation: String, position: Int, sourcePath: String,
        preparedPath: String? = nil, previewPath: String, fileName: String, mimeType: String,
        width: Int, height: Int, byteCount: Int64, attachmentID: String? = nil,
        failure: OutboxFailure.Reason? = nil,
        preservesOriginal: Bool? = nil
    ) {
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
        self.failure = failure
        self.preservesOriginal = preservesOriginal
    }
}

public struct LocalDraft: Sendable, Equatable {
    public let text: String
    public let replyToMessage: MessagePreview?
    public let editRevision: Int64
    public let updatedAt: Date
    public let attachments: [LocalOutgoingAttachment]
    public let compressionEnabled: Bool
    public let linkPreviews: [LinkPreviewInput]
}

/// Immutable acknowledged source selection captured once before entering the durable outbox.
public struct LocalForwardRequest: Codable, Hashable, Sendable {
    public let sourceChatID: String
    public let sources: [MessageResponse]
    public let allowPlaceholders: Bool

    public init(sourceChatID: String, sources: [MessageResponse], allowPlaceholders: Bool = false) {
        self.sourceChatID = sourceChatID
        self.sources = sources.sorted { $0.id < $1.id }
        self.allowPlaceholders = allowPlaceholders
    }

    public var messageIDs: [MessageID] { sources.map(\.id).sorted() }
}

public enum LocalEditAttachment: Codable, Hashable, Sendable {
    case local(LocalOutgoingAttachment)
    case server(AttachmentResponse)
}

public struct OutboxFailure: Codable, Hashable, Sendable {
    public enum Stage: String, Codable, Hashable, Sendable { case preparation, create }
    public enum Retry: String, Codable, Hashable, Sendable { case automatic, manual }
    public enum Reason: Codable, Hashable, Sendable {
        case unknownOutcome, network, conflict, invalidReceipt, authentication, rejected
        case attachment
        case tooLarge(Int64)
        case speakingRestricted(SpeakingMode)
    }

    public let stage: Stage
    public let reason: Reason
    public let retry: Retry

    public init(stage: Stage, reason: Reason, retry: Retry) {
        self.stage = stage
        self.reason = reason
        self.retry = retry
    }
}

public struct LocalOutgoingMessage: Sendable, Equatable {
    public enum State: String, Sendable { case pending, sending, failed }
    public let clientGeneratedID: String
    public let chatID: String
    public let threadID: String?
    public var conversationKey: ConversationKey {
        ConversationKey(chatID: chatID, threadID: threadID)
    }
    public let senderID: Int32
    public let text: String
    public let replyToMessage: MessagePreview?
    public let enqueuedAt: Date
    public let position: Int64
    public let state: State
    public let attachments: [LocalOutgoingAttachment]
    public let compressionEnabled: Bool
    public let sticker: MessageStickerResponse?
    public let forwardRequest: LocalForwardRequest?
    public let metadata: MessageMetadataInput?
    public let failure: OutboxFailure?

    public var isEditable: Bool {
        guard forwardRequest == nil, sticker == nil, messageType != .audio else { return false }
        return state == .pending || failure?.stage == .preparation
    }

    public var messageType: MessageType {
        if let forwardRequest {
            return forwardRequest.sources.count == 1
                ? forwardRequest.sources[0].messageType : .forwarded
        }
        if sticker != nil { return .sticker }
        if attachments.count == 1, attachments[0].isAudio { return .audio }
        if attachments.contains(where: \.isFile) { return .file }
        return .text
    }

    public var isReadyForDispatch: Bool {
        attachments.allSatisfy { $0.isUploaded && $0.failure == nil }
    }

    public var body: CreateMessageBody {
        precondition(forwardRequest == nil, "Forwarding must use the forwarding endpoints")
        precondition(
            isReadyForDispatch, "An unresolved attachment must never be omitted from a message")
        return CreateMessageBody(
            messageType: messageType, clientGeneratedId: clientGeneratedID,
            message: messageType == .text ? text : nil,
            attachmentIds: attachments.map { $0.attachmentID! },
            replyToId: replyToMessage?.id, stickerId: sticker?.id, metadata: metadata
        )
    }
}

public struct LocalConversationSnapshot: Sendable, Equatable {
    public let chatID: String
    public let threadID: String?
    public var conversationKey: ConversationKey {
        ConversationKey(chatID: chatID, threadID: threadID)
    }
    public let revision: Int64
    public let draft: LocalDraft
    public let outgoing: [LocalOutgoingMessage]
}

public struct LocalOutgoingClaim: Sendable {
    public let snapshot: LocalConversationSnapshot
    public let message: LocalOutgoingMessage?
}

public enum LocalStorageError: Error, Sendable {
    case unsupportedSchema
    case corruptRecord
    case blankMessage
    case staleDraft
    case missingOutgoing
    case outgoingNotEditable
    case outgoingSending
    case invalidAttachments
    case unsupportedMessageType
}
