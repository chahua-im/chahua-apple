import Foundation

public struct MessageSyncCheckpoint: Codable, Equatable, Sendable {
    public let chatID: String
    public let cursor: String?

    public init(chatID: String, cursor: String? = nil) {
        self.chatID = chatID
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey {
        case chatID = "chatId"
        case cursor
    }
}

public enum MessageSyncResetReason: String, Decodable, Sendable {
    case noBaseline, expired, tooLarge, visibilityChanged, invalidCursor, epochChanged

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .invalidCursor
    }
}

public enum MessageSyncChange: Decodable, Sendable {
    case upsert(message: MessageResponse, appeared: Bool)
    case delete(messageID: MessageID, threadRootID: MessageID?)

    private enum Kind: String, Decodable { case upsert, delete }
    private enum CodingKeys: String, CodingKey {
        case kind, message, appeared, messageID = "messageId", threadRootID = "threadRootId"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .upsert:
            self = .upsert(
                message: try values.decode(MessageResponse.self, forKey: .message),
                appeared: try values.decode(Bool.self, forKey: .appeared))
        case .delete:
            self = .delete(
                messageID: try values.decode(MessageID.self, forKey: .messageID),
                threadRootID: try values.decodeIfPresent(MessageID.self, forKey: .threadRootID))
        }
    }
}

public struct MessageSyncBatch: Decodable, Sendable {
    public let chatID: String
    public let from: String
    public let to: String
    public let changes: [MessageSyncChange]

    public init(chatID: String, from: String, to: String, changes: [MessageSyncChange]) {
        self.chatID = chatID
        self.from = from
        self.to = to
        self.changes = changes
    }

    private enum CodingKeys: String, CodingKey {
        case chatID = "chatId"
        case from, to, changes
    }
}

public struct MessageSyncPageResult: Decodable, Sendable {
    public let requestID: UInt64
    public let chatID: String
    public let at: String?
    public let page: ListMessagesResponse?

    public init(requestID: UInt64, chatID: String, at: String?, page: ListMessagesResponse?) {
        self.requestID = requestID
        self.chatID = chatID
        self.at = at
        self.page = page
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case chatID = "chatId"
        case at, page
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try values.decode(UInt64.self, forKey: .requestID)
        chatID = try values.decode(String.self, forKey: .chatID)
        at = try values.decode(String?.self, forKey: .at)
        page = try values.decode(ListMessagesResponse?.self, forKey: .page)
    }
}
