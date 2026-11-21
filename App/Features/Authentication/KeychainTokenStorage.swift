import ChahuaAPI
import CryptoKit
import Foundation

nonisolated struct OfflineSessionBinding: Codable, Sendable {
    let baseURL: String
    let tokenDigest: Data
    let profile: MeResponse

    init(baseURL: String, token: String, profile: MeResponse) {
        self.baseURL = baseURL
        tokenDigest = Self.digest(token)
        self.profile = profile
    }

    func matches(baseURL: String, token: String) -> Bool {
        self.baseURL == baseURL && tokenDigest == Self.digest(token)
    }

    private static func digest(_ token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }
}

nonisolated protocol SessionTokenStorage: Sendable {
    func loadToken() async throws -> String?
    func saveToken(_ token: String) async throws
    func deleteToken() async throws
    func loadOfflineBinding() async throws -> OfflineSessionBinding?
    func saveOfflineBinding(_ binding: OfflineSessionBinding?) async throws
}

actor InMemorySessionTokenStorage: SessionTokenStorage {
    private var token: String?
    private var binding: OfflineSessionBinding?

    init(token: String? = nil, binding: OfflineSessionBinding? = nil) {
        self.token = token
        self.binding = binding
    }
    func loadToken() -> String? { token }
    func saveToken(_ token: String) { self.token = token }
    func deleteToken() { token = nil }
    func loadOfflineBinding() -> OfflineSessionBinding? { binding }
    func saveOfflineBinding(_ binding: OfflineSessionBinding?) { self.binding = binding }
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

    func loadOfflineBinding() throws -> OfflineSessionBinding? {
        guard
            let data = try SharedSessionCredentials.offlineRecord(service: bindingService)
                .loadData()
        else { return nil }
        return try? JSONDecoder().decode(OfflineSessionBinding.self, from: data)
    }

    func saveOfflineBinding(_ binding: OfflineSessionBinding?) throws {
        let store = try SharedSessionCredentials.offlineRecord(service: bindingService)
        if let binding {
            try store.saveData(JSONEncoder().encode(binding))
        } else {
            try store.delete()
        }
    }

    private var bindingService: String { usesDefaultCredential ? service : "\(service).\(account)" }

    private var usesDefaultCredential: Bool {
        service == Self.defaultService && account == Self.defaultAccount
    }
}
