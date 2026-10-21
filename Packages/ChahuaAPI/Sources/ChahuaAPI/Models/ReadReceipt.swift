/// A DM peer's visible cursor for the requested chat or thread scope.
/// An absent cursor means no receipt is currently authorized or available.
public struct ReadReceiptResponse: Codable, Equatable, Sendable {
    public let lastReadMessageId: MessageID?

    public init(lastReadMessageId: MessageID? = nil) {
        self.lastReadMessageId = lastReadMessageId
    }
}

/// Sharing is reciprocal; groups never expose individual read receipts.
public enum ReadReceiptVisibility: String, Codable, CaseIterable, Sendable {
    case friends
    case nobody
}

/// Authoritative settings from GET/PUT /me/read-receipt-settings.
/// Failed requests must not be interpreted as a default policy.
public struct ReadReceiptSettingsResponse: Codable, Equatable, Sendable {
    public let visibility: ReadReceiptVisibility

    public init(visibility: ReadReceiptVisibility) {
        self.visibility = visibility
    }
}

public enum FriendReadReceiptOverride: String, Codable, CaseIterable, Sendable {
    case inherit
    case share
    case hide
}

/// The current account's refinement for sharing with one current friend.
public struct FriendReadReceiptSettingsResponse: Codable, Equatable, Sendable {
    public let override: FriendReadReceiptOverride

    public init(override: FriendReadReceiptOverride) {
        self.override = override
    }
}
