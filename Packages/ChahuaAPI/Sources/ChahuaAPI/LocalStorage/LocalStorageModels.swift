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
    // Optional for compatibility with durable rows written before general-file acquisition.
    public var preservesOriginal: Bool?
    public var isFile: Bool { preservesOriginal == true }
    public var isUploaded: Bool { attachmentID != nil }
    public var isAudio: Bool { !isFile && mimeType.lowercased().hasPrefix("audio/") }
    public var uploadPath: String { preparedPath ?? sourcePath }

    public init(
        id: String, generation: String, position: Int, sourcePath: String,
        preparedPath: String? = nil, previewPath: String, fileName: String, mimeType: String,
        width: Int, height: Int, byteCount: Int64, attachmentID: String? = nil,
        error: String? = nil,
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
        self.error = error
        self.preservesOriginal = preservesOriginal
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

public struct LocalFrozenCreate: Codable, Hashable, Sendable {
    public let body: CreateMessageBody?
    public let forwardRequest: LocalForwardRequest?
    public let revision: Int64

    public init(body: CreateMessageBody?, forwardRequest: LocalForwardRequest?, revision: Int64) {
        self.body = body
        self.forwardRequest = forwardRequest
        self.revision = revision
    }
}

public struct LocalClaimedPatch: Codable, Hashable, Sendable {
    public let text: String
    public let attachmentIDs: [String]
    public let revision: Int64

    public init(text: String, attachmentIDs: [String], revision: Int64) {
        self.text = text
        self.attachmentIDs = attachmentIDs
        self.revision = revision
    }
}

public struct LocalOutgoingMessage: Sendable, Equatable {
    public enum State: String, Sendable { case queued, sending, failed }
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
    public let enqueueSequence: Int64
    public let dispatchOrder: Int64
    public let state: State
    public var attachments: [LocalOutgoingAttachment] = []
    public var isBlocked: Bool = false
    public var editRevision: Int64 = 0
    public var compressionEnabled: Bool = true
    /// Once claimed, even an interrupted or failed request must replay the same payload.
    public var dispatchClaimed: Bool = false
    public var sticker: MessageStickerResponse? = nil
    public var forwardRequest: LocalForwardRequest? = nil
    public var speakingRestriction: SpeakingMode? = nil
    public var frozenCreate: LocalFrozenCreate? = nil
    public var intentAttachments: [LocalEditAttachment]? = nil
    public var confirmedMessage: MessageResponse? = nil
    public var isPublished: Bool = false
    public var isCancelled: Bool = false
    public var acknowledgedRevision: Int64 = -1
    public var claimedPatch: LocalClaimedPatch? = nil
    public var mutationRetryable: Bool = false

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
        if frozenCreate != nil { return true }
        return (intentAttachments ?? attachments.map(LocalEditAttachment.local)).allSatisfy {
            switch $0 {
            case .local(let slot): return slot.attachmentID != nil && slot.error == nil
            case .server: return true
            }
        }
    }

    public var body: CreateMessageBody {
        if let frozenCreate {
            precondition(frozenCreate.body != nil, "Forwarding must use the forwarding endpoints")
            return frozenCreate.body!
        }
        precondition(forwardRequest == nil, "Forwarding must use the forwarding endpoints")
        precondition(
            isReadyForDispatch, "An unresolved attachment must never be omitted from a message")
        return CreateMessageBody(
            messageType: messageType, clientGeneratedId: clientGeneratedID,
            message: messageType == .text ? text : nil,
            attachmentIds: (intentAttachments ?? attachments.map(LocalEditAttachment.local)).map {
                switch $0 {
                case .local(let slot): return slot.attachmentID!
                case .server(let attachment): return attachment.id
                }
            },
            replyToId: replyToMessage?.id, stickerId: sticker?.id
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
    public var composingItem: LocalOutgoingMessage? = nil
}

public struct LocalOutgoingClaim: Sendable {
    public let snapshot: LocalConversationSnapshot
    public let message: LocalOutgoingMessage?
}

public enum LocalOutgoingDisposition: Equatable, Sendable {
    case retained, completed, cancelled
}

public struct LocalOutgoingTransition: Sendable {
    public let snapshot: LocalConversationSnapshot
    public let clientGeneratedID: String
    public let disposition: LocalOutgoingDisposition
}

public struct LocalOutgoingPatchClaim: Sendable {
    public let snapshot: LocalConversationSnapshot
    public let patch: LocalClaimedPatch?
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
    case unsupportedMessageType
}
