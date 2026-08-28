import Foundation

public struct ChahuaConfiguration: Sendable {
    public var baseURL: URL
    public var userAgent: String?
    public var requestTimeout: TimeInterval

    public init(
        baseURL: URL,
        userAgent: String? = nil,
        requestTimeout: TimeInterval = 30
    ) {
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.requestTimeout = requestTimeout
    }
}
