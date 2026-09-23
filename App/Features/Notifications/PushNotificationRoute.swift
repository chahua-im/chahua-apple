import ChahuaAPI
import Foundation

/// The backend's `wettyChat` envelope, not a URL or a locally generated alert.
struct PushNotificationRoute: Identifiable, Equatable, Sendable {
    let id: UUID
    let chatID: String
    let threadID: String?
    let messageID: String

    var conversation: ConversationKey { .init(chatID: chatID, threadID: threadID) }
    var groupingIdentifier: String {
        threadID.map { "chat_\(chatID)_thread_\($0)" } ?? "chat_\(chatID)"
    }
    nonisolated init?(userInfo: [AnyHashable: Any]) {
        guard let data = userInfo["wettyChat"] as? [String: Any],
            let type = data["type"] as? String,
            ["newMessage", "mention", "reply"].contains(type),
            let chatID = data["chatId"] as? String, Self.validID(chatID),
            let messageID = data["messageId"] as? String, Self.validID(messageID)
        else { return nil }
        let threadID: String?
        if let value = data["threadRootId"], !(value is NSNull) {
            guard let value = value as? String, Self.validID(value) else { return nil }
            threadID = value
        } else {
            threadID = nil
        }
        self.id = UUID()
        self.chatID = chatID
        self.messageID = messageID
        self.threadID = threadID
    }

    /// Server IDs are positive decimal i64 strings. Never round them through a
    /// JSON double (snowflake IDs exceed JavaScript's integer precision).
    nonisolated private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
            && Int64(value).map { $0 > 0 } == true
    }

    func isRead(through messageID: String, in conversation: ConversationKey) -> Bool {
        guard self.conversation == conversation,
            let watermark = Int64(messageID), let message = Int64(self.messageID)
        else { return false }
        return message <= watermark
    }
}
