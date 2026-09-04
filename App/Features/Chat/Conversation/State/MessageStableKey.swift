import ChahuaAPI

/// Stable client-visible identity for one message within a conversation.
///
/// A server acknowledgement may replace a provisional server ID, but it retains
/// the client-generated ID supplied by the sender. Keeping that value as the
/// row identity prevents the acknowledgement from becoming a delete/insert.
enum ConversationMessageStableKey: Hashable {
    case clientGenerated(String)
    case server(String)

    init(_ message: MessageResponse) {
        if message.clientGeneratedId.isEmpty {
            self = .server(message.id)
        } else {
            self = .clientGenerated(message.clientGeneratedId)
        }
    }
}

extension MessageResponse {
    var timelineStableKey: ConversationMessageStableKey { .init(self) }
}
