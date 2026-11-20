import ChahuaAPI

@MainActor
final class SessionCredentialWriter {
    private let storage: any SessionTokenStorage
    private let baseURL: String
    private var tail: Task<Void, Never>?

    init(storage: any SessionTokenStorage, baseURL: String) {
        self.storage = storage
        self.baseURL = baseURL
    }

    func load() async throws -> (String?, OfflineSessionBinding?) {
        try await ordered { storage in
            guard let token = try await storage.loadToken() else { return (nil, nil) }
            return (token, try await storage.loadOfflineBinding())
        }
    }

    func save(_ token: String, profile: MeResponse, replacing expected: String? = nil) async throws {
        try await ordered { [baseURL] storage in
            if let expected, try await storage.loadToken() != expected { throw CancellationError() }
            if expected != token { try await storage.saveToken(token) }
            try await storage.saveOfflineBinding(.init(baseURL: baseURL, token: token, profile: profile))
        }
    }

    func refresh(from old: String, to new: String, retainBinding: Bool) async throws {
        try await ordered { [baseURL] storage in
            guard try await storage.loadToken() == old else { throw CancellationError() }
            let binding = try await storage.loadOfflineBinding()
            try await storage.saveToken(new)
            if retainBinding, let binding, binding.matches(baseURL: baseURL, token: old) {
                try await storage.saveOfflineBinding(.init(baseURL: baseURL, token: new, profile: binding.profile))
            } else {
                try await storage.saveOfflineBinding(nil)
            }
        }
    }

    func delete() async throws {
        try await ordered { storage in
            try await storage.saveOfflineBinding(nil)
            try await storage.deleteToken()
        }
    }

    private func ordered<Value: Sendable>(
        _ operation: @escaping @Sendable (any SessionTokenStorage) async throws -> Value
    ) async throws -> Value {
        let previous = tail
        let task = Task { [storage] in
            await previous?.value
            return try await operation(storage)
        }
        tail = Task { _ = await task.result }
        return try await task.value
    }
}
