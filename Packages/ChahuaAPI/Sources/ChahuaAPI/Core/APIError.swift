import Foundation

/// Error surface for HTTP transport, authentication, and protocol failures.
///
/// `invalidToken` means no authenticated session remains after refresh handling.
/// `transport` and `unavailable` are recoverable only according to the calling
/// feature's retry policy. `decoding` must be treated as a wire-contract defect,
/// not silently coerced.
public enum APIError: Error, Sendable {
    case invalidBaseURL(URL)
    case unauthorized
    case invalidToken
    case unavailable
    case invalidResponse(statusCode: Int)
    case http(status: Int, body: Data)
    case decoding(statusCode: Int, description: String)
    case encoding(description: String)
    case transport(URLError)
    case unexpectedResponse

    /// UTF-8 response body for an `http` error, when the server returned one.
    public var bodyText: String? {
        guard case let .http(_, body) = self else {
            return nil
        }
        return String(data: body, encoding: .utf8)
    }
}
