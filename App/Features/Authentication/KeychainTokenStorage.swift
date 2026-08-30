import Foundation
import Security

protocol SessionTokenStorage: Sendable {
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

enum KeychainTokenStorageError: Error, Sendable {
    case operationFailed(operation: String, status: Int32)
}

struct KeychainTokenStorage: SessionTokenStorage {
    static let defaultService = "app.chahua.chat.authentication"
    static let defaultAccount = "session-jwt"

    private let service: String
    private let account: String

    init(service: String = defaultService, account: String = defaultAccount) {
        self.service = service
        self.account = account
    }

    func loadToken() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure("load", status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw failure("load", errSecDecode)
        }
        return token
    }

    func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw failure("save", updateStatus) }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw failure("save", addStatus) }
    }

    func deleteToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure("delete", status) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private func failure(_ operation: String, _ status: OSStatus) -> KeychainTokenStorageError {
        .operationFailed(operation: operation, status: status)
    }
}
