import Foundation

struct HTTPRequestSpec: Sendable {
    var method: HTTPMethod
    var path: [String]
    var query: [URLQueryItem] = []
    var body: Data?
    var contentType: String?
    var requiresAuth = true
    var allowsTokenRefresh = true
    var headers: [String: String] = [:]

    private static let segmentCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    func encodedPath() throws -> String {
        try "/" + path.map { segment in
            guard let encoded = segment.addingPercentEncoding(withAllowedCharacters: Self.segmentCharacters) else {
                throw APIError.encoding(description: "Unable to encode URL path segment.")
            }
            return encoded
        }.joined(separator: "/")
    }

    static func json<Body: Encodable>(
        _ method: HTTPMethod,
        _ path: [String],
        query: [URLQueryItem] = [],
        body: Body,
        requiresAuth: Bool = true,
        allowsTokenRefresh: Bool = true,
        headers: [String: String] = [:]
    ) throws -> HTTPRequestSpec {
        do {
            return HTTPRequestSpec(
                method: method,
                path: path,
                query: query,
                body: try JSONCoding.encoder.encode(body),
                contentType: "application/json",
                requiresAuth: requiresAuth,
                allowsTokenRefresh: allowsTokenRefresh,
                headers: headers
            )
        } catch {
            throw APIError.encoding(description: String(describing: error))
        }
    }
}
