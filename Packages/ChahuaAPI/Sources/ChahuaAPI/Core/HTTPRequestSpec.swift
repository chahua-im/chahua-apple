import Foundation

struct HTTPRequestSpec: Sendable {
    var method: HTTPMethod
    var path: String
    var query: [URLQueryItem] = []
    var body: Data?
    var contentType: String?
    var requiresAuth = true
    var allowsTokenRefresh = true

    static func json<Body: Encodable>(
        _ method: HTTPMethod,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Body,
        requiresAuth: Bool = true
    ) throws -> HTTPRequestSpec {
        do {
            return HTTPRequestSpec(
                method: method,
                path: path,
                query: query,
                body: try JSONCoding.encoder.encode(body),
                contentType: "application/json",
                requiresAuth: requiresAuth
            )
        } catch {
            throw APIError.encoding(description: String(describing: error))
        }
    }
}
