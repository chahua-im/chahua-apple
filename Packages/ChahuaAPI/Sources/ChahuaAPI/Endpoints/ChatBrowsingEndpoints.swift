import Foundation

public enum ChatAttachmentKind: String, Codable, CaseIterable, Sendable {
    case image, video, other
}

/// Chat-wide attachment projection, including replies. Cursors remain message IDs.
public struct ChatAttachmentResponse: Codable, Hashable, Sendable {
    public let id: String
    public let messageId: MessageID
    public let messageCreatedAt: Date
    public let sender: User
    public let url: String
    public let kind: String
    public let fileName: String
    public let size: Int64
    public let width: Int32?
    public let height: Int32?
    public let order: Int
}

public struct ListChatAttachmentsResponse: Codable, Hashable, Sendable {
    public let attachments: [ChatAttachmentResponse]
    public let olderCursor: MessageID?
    public let newerCursor: MessageID?
}

extension ChahuaClient {
    public func listChatAttachments(chatID: String, kind: ChatAttachmentKind, before: MessageID?)
        async throws -> ListChatAttachmentsResponse
    {
        try await send(
            HTTPRequestSpec(
                method: .get, path: ["chats", chatID, "attachments"],
                query: [
                    URLQueryItem(name: "kind", value: kind.rawValue),
                    URLQueryItem(name: "limit", value: "36"),
                    before.map { URLQueryItem(name: "before", value: $0.description) },
                ].compactMap { $0 }),
            decoding: ListChatAttachmentsResponse.self)
    }
}
