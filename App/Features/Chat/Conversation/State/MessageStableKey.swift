import ChahuaAPI

/// Keep the sender and conversation context with the client ID so that a receipt
/// retains its pending row's identity without coalescing another sender or topic.
enum ConversationMessageStableKey: Hashable {
    case clientGenerated(String, senderID: Int32, chatID: String, threadID: String?)
    case server(MessageID)
}

extension MessageResponse {
    var timelineClientKey: ConversationMessageStableKey? {
        guard !clientGeneratedId.isEmpty else { return nil }
        return .clientGenerated(
            clientGeneratedId, senderID: sender.uid, chatID: chatId, threadID: replyRootId)
    }

    var timelineStableKey: ConversationMessageStableKey { timelineClientKey ?? .server(id) }
}
