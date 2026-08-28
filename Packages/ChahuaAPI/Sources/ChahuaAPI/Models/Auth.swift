public struct AuthTokenResponse: Codable, Hashable, Sendable {
    public let token: String

    public init(token: String) {
        self.token = token
    }
}

public struct DevSessionRequest: Codable, Hashable, Sendable {
    public var uid: Int32

    public init(uid: Int32) {
        self.uid = uid
    }
}
