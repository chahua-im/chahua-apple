/// Server-defined write scopes. These properties do not establish membership or authorization.
public enum SpeakingMode: String, Codable, CaseIterable, Hashable, Sendable {
    case unrestricted
    case threadsOnly
    case repliesOnly
    case readOnly

    public var allowsMainMessages: Bool { self == .unrestricted }
    public var allowsThreadCreation: Bool { self == .unrestricted || self == .threadsOnly }
    /// Applies only when the root already has a thread.
    public var allowsThreadReplies: Bool { self != .readOnly }
}

public struct UpdateSpeakingModeBody: Codable, Hashable, Sendable {
    public let speakingMode: SpeakingMode

    public init(speakingMode: SpeakingMode) {
        self.speakingMode = speakingMode
    }
}

public struct GroupSpeakingModeResponse: Codable, Hashable, Sendable {
    public let chatId: String
    public let speakingMode: SpeakingMode

    public init(chatId: String, speakingMode: SpeakingMode) {
        self.chatId = chatId
        self.speakingMode = speakingMode
    }
}

public struct MemberSpeakingModeResponse: Codable, Hashable, Sendable {
    public let chatId: String
    public let uid: Int32
    public let role: GroupRole
    public let speakingMode: SpeakingMode
    public let groupSpeakingMode: SpeakingMode
    public let effectiveSpeakingMode: SpeakingMode

    public init(
        chatId: String, uid: Int32, role: GroupRole, speakingMode: SpeakingMode,
        groupSpeakingMode: SpeakingMode, effectiveSpeakingMode: SpeakingMode
    ) {
        self.chatId = chatId
        self.uid = uid
        self.role = role
        self.speakingMode = speakingMode
        self.groupSpeakingMode = groupSpeakingMode
        self.effectiveSpeakingMode = effectiveSpeakingMode
    }
}
