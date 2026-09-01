import Foundation

/// Transport configuration shared by one `ChahuaClient`.
public struct ChahuaConfiguration: Sendable {
    /// API root URL. Endpoint paths are appended to its path component.
    public var baseURL: URL
    /// Optional value sent as the `User-Agent` header.
    public var userAgent: String?
    /// Per-request URL loading timeout in seconds.
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
