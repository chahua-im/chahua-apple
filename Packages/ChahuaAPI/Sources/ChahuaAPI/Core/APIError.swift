import Foundation

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

    public var bodyText: String? {
        guard case let .http(_, body) = self else {
            return nil
        }
        return String(data: body, encoding: .utf8)
    }
}
