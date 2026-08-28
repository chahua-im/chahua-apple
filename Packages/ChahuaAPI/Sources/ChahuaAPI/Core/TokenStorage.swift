public protocol TokenStorage: Sendable {
    func loadToken() async throws -> String?
    func saveToken(_ token: String) async throws
    func deleteToken() async throws
}

public actor InMemoryTokenStorage: TokenStorage {
    private var token: String?

    public init(token: String? = nil) {
        self.token = token
    }

    public func loadToken() -> String? {
        token
    }

    public func saveToken(_ token: String) {
        self.token = token
    }

    public func deleteToken() {
        token = nil
    }
}
