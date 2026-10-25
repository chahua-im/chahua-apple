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
    /// Only the backend's structured speaking denial is classified; other 403s stay generic.
    public var speakingRestriction: SpeakingMode? {
        guard case .http(status: 403, body: let body) = self,
            let restriction = try? JSONDecoder().decode(SpeakingRestriction.self, from: body),
            restriction.code == "speakingRestricted"
        else { return nil }
        return restriction.effectiveSpeakingMode
    }

    private struct SpeakingRestriction: Decodable {
        let code: String
        let effectiveSpeakingMode: SpeakingMode
    }

    /// UTF-8 response body for an `http` error, when the server returned one.
    public var bodyText: String? {
        guard case .http(_, let body) = self else {
            return nil
        }
        return String(data: body, encoding: .utf8)
    }
}
