public enum SystemMessageKind: String, Codable, Hashable, Sendable {
    case memberJoined = "member_joined"
    case memberLeft = "member_left"
    case memberAdded = "member_added"
    case memberRemoved = "member_removed"
    case messagePinned = "message_pinned"
    case messageUnpinned = "message_unpinned"
    case threadMessagePinned = "thread_message_pinned"
    case threadMessageUnpinned = "thread_message_unpinned"
    case friendRequestAccepted = "friend_request_accepted"
    case unknown

    public var isMembership: Bool {
        switch self {
        case .memberJoined, .memberLeft, .memberAdded, .memberRemoved: true
        default: false
        }
    }
}

public struct SystemMessageLinks: Codable, Hashable, Sendable {
    public let messageId: MessageID?
    public let uid: Int32?

    public init(messageId: MessageID? = nil, uid: Int32? = nil) {
        self.messageId = messageId
        self.uid = uid
    }
}
