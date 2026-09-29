nonisolated protocol SessionTokenStorage: Sendable {
    func loadToken() async throws -> String?
    func saveToken(_ token: String) async throws
    func deleteToken() async throws
}

actor InMemorySessionTokenStorage: SessionTokenStorage {
    private var token: String?

    init(token: String? = nil) { self.token = token }
    func loadToken() -> String? { token }
    func saveToken(_ token: String) { self.token = token }
    func deleteToken() { token = nil }
}

struct KeychainTokenStorage: SessionTokenStorage {
    static let defaultService = SharedSessionCredentials.defaultService
    static let defaultAccount = SharedSessionCredentials.defaultAccount

    private let service: String
    private let account: String

    init(service: String = defaultService, account: String = defaultAccount) {
        self.service = service
        self.account = account
    }

    func loadToken() throws -> String? {
        if usesDefaultCredential {
            return try SharedSessionCredentials.migrateLegacyTokenIfNeeded()
        }
        return try SharedSessionCredentials.loadToken(service: service, account: account)
    }

    func saveToken(_ token: String) throws {
        if usesDefaultCredential {
            try SharedSessionCredentials.saveToken(token)
        } else {
            try SharedSessionCredentials.saveToken(token, service: service, account: account)
        }
    }

    func deleteToken() throws {
        if usesDefaultCredential {
            try SharedSessionCredentials.deleteToken()
        } else {
            try SharedSessionCredentials.deleteToken(service: service, account: account)
        }
    }

    private var usesDefaultCredential: Bool {
        service == Self.defaultService && account == Self.defaultAccount
    }
}
