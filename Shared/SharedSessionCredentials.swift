import Foundation
import Security

nonisolated enum KeychainTokenStorageError: Error, Sendable {
    case operationFailed(operation: String, status: Int32)
}

/// The session credential shared by the containing app and its share extension.
nonisolated enum SharedSessionCredentials {
    static let defaultService = "app.chahua.chat.authentication"
    static let defaultAccount = "session-jwt"

    static func loadToken() throws -> String? {
        try loadToken(service: defaultService, account: defaultAccount)
    }

    static func saveToken(_ token: String) throws {
        try saveToken(token, service: defaultService, account: defaultAccount)
        try legacyStore().delete()
    }

    static func deleteToken() throws {
        var failure: KeychainTokenStorageError?

        do {
            try sharedStore().delete()
        } catch let error as KeychainTokenStorageError {
            failure = error
        }
        do {
            try legacyStore().delete()
        } catch let error as KeychainTokenStorageError where failure == nil {
            failure = error
        }

        if let failure {
            throw failure
        }
    }

    static func migrateLegacyTokenIfNeeded() throws -> String? {
        if let sharedToken = try loadToken() {
            return sharedToken
        }

        let legacyStore = try legacyStore()
        guard let legacyToken = try legacyStore.load() else {
            return nil
        }

        try sharedStore().save(legacyToken)
        try legacyStore.delete()
        return legacyToken
    }

    static func loadToken(service: String, account: String) throws -> String? {
        try sharedStore(service: service, account: account).load()
    }

    static func saveToken(_ token: String, service: String, account: String) throws {
        try sharedStore(service: service, account: account).save(token)
    }

    static func deleteToken(service: String, account: String) throws {
        try sharedStore(service: service, account: account).delete()
    }

    private static func sharedStore(
        service: String = defaultService,
        account: String = defaultAccount
    ) throws -> SessionCredentialKeychainStore {
        let accessGroup = try sharedKeychainAccessGroup()
        #if os(macOS)
            return SessionCredentialKeychainStore(
                service: service,
                account: account,
                accessGroup: accessGroup,
                usesDataProtectionKeychain: true
            )
        #else
            return SessionCredentialKeychainStore(
                service: service,
                account: account,
                accessGroup: accessGroup,
                usesDataProtectionKeychain: false
            )
        #endif
    }

    private static func legacyStore() throws -> SessionCredentialKeychainStore {
        #if os(macOS)
            return SessionCredentialKeychainStore(
                service: defaultService,
                account: defaultAccount,
                accessGroup: nil,
                usesDataProtectionKeychain: false
            )
        #else
            return SessionCredentialKeychainStore(
                service: defaultService,
                account: defaultAccount,
                accessGroup: try legacyKeychainAccessGroup(),
                usesDataProtectionKeychain: false
            )
        #endif
    }

    private static func legacyKeychainAccessGroup() throws -> String {
        let sharedGroup = try sharedKeychainAccessGroup()
        guard sharedGroup.hasSuffix(".shared") else {
            throw KeychainTokenStorageError.operationFailed(
                operation: "resolve legacy keychain access group",
                status: errSecParam
            )
        }
        return String(sharedGroup.dropLast(".shared".count))
    }

    private static func sharedKeychainAccessGroup() throws -> String {
        if let configuredGroup = Bundle.main.object(
            forInfoDictionaryKey: "ChahuaSharedKeychainAccessGroup")
            as? String,
            !configuredGroup.isEmpty,
            !configuredGroup.contains("$(")
        {
            return configuredGroup
        }

        #if os(macOS)
            guard let task = SecTaskCreateFromSelf(nil) else {
                throw KeychainTokenStorageError.operationFailed(
                    operation: "resolve shared keychain access group",
                    status: errSecParam
                )
            }
            let entitlementKey = "keychain-access-groups" as CFString
            let groups = SecTaskCopyValueForEntitlement(task, entitlementKey, nil) as? [String]
            guard
                let sharedGroup = groups?.first(where: { $0.hasSuffix(".app.chahua.chat.shared") })
            else {
                throw KeychainTokenStorageError.operationFailed(
                    operation: "resolve shared keychain access group",
                    status: errSecMissingEntitlement
                )
            }
            return sharedGroup
        #else
            throw KeychainTokenStorageError.operationFailed(
                operation: "resolve shared keychain access group",
                status: errSecMissingEntitlement
            )
        #endif
    }
}

nonisolated private struct SessionCredentialKeychainStore {
    let service: String
    let account: String
    let accessGroup: String?
    let usesDataProtectionKeychain: Bool

    func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw failure("load", status)
        }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw failure("load", errSecDecode)
        }
        return token
    }

    func save(_ token: String) throws {
        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw failure("save", updateStatus)
        }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if retryStatus == errSecSuccess {
                return
            }
            throw failure("save", retryStatus)
        }
        throw failure("save", addStatus)
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw failure("delete", status)
        }
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        #if os(macOS)
            query[kSecUseDataProtectionKeychain as String] =
                usesDataProtectionKeychain ? kCFBooleanTrue : kCFBooleanFalse
        #endif
        return query
    }

    private func failure(_ operation: String, _ status: OSStatus) -> KeychainTokenStorageError {
        .operationFailed(operation: operation, status: status)
    }
}
