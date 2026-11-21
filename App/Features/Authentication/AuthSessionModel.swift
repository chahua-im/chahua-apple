import ChahuaAPI
import Combine
import SwiftUI
import os

enum SignedOutReason { case initial, invalidOrRevoked, loggedOut }
enum AuthStartupFailure: Equatable {
    case network, server, unknown
}

enum AuthSessionState {
    case bootstrapping
    case signedOut(SignedOutReason)
    case authenticated(MeResponse)
    case restorationFailed(AuthStartupFailure)
}

enum SessionValidation: Equatable { case localOnly, verified }

private enum AuthenticationAttemptError: Error {
    case timedOut, invalidCredentials
}

@MainActor
final class AuthSessionModel: ObservableObject {
    @Published private(set) var state: AuthSessionState = .bootstrapping {
        // Bind/clear dependent stores before authentication invalidates the view tree.
        // A $state sink runs after objectWillChange has already begun that invalidation.
        willSet { willTransitionSession?(newValue) }
    }
    @Published private(set) var validationMessage: LocalizedStringKey?
    @Published private(set) var isSubmitting = false
    @Published private(set) var isSlow = false
    @Published var signOutError: LocalizedStringKey?
    var prepareForSignOut: (() async throws -> Void)?
    var willTransitionSession: ((AuthSessionState) -> Void)?
    @Published private(set) var sessionValidation: SessionValidation = .localOnly

    private let apiClient: any SessionAuthenticating
    private let credentialLoginClient: any CredentialLoginProviding
    private let credentials: SessionCredentialWriter
    private let baseURL: String
    private var credentialGeneration = UUID()
    private var currentToken: String?
    private var validationRetry: Task<Void, Never>?
    private var validationFailures = 0
    private var networkOpportunity = true
    private var bootstrapTask: Task<Void, Never>?
    private var bootstrapID: UUID?
    private var slowTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "app.chahua.chat", category: "authentication")

    init(
        apiClient: any SessionAuthenticating,
        credentialLoginClient: any CredentialLoginProviding,
        tokenStorage: any SessionTokenStorage,
        baseURL: String = "injected"
    ) {
        self.apiClient = apiClient
        self.credentialLoginClient = credentialLoginClient
        self.baseURL = baseURL
        credentials = SessionCredentialWriter(storage: tokenStorage, baseURL: baseURL)
    }

    func bootstrap(allowStalePath: Bool = false) {
        guard bootstrapTask == nil, !isSubmitting else { return }
        let id = UUID()
        bootstrapID = id
        bootstrapTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if bootstrapID == id {
                    bootstrapTask = nil
                    bootstrapID = nil
                    stopSlowTimer()
                }
            }
            await restore(id: id, allowStalePath: allowStalePath)
        }
    }

    func retry() {
        validationRetry?.cancel()
        validationRetry = nil
        if case .authenticated = state {
            guard sessionValidation == .localOnly, bootstrapTask == nil else { return }
        } else {
            bootstrapTask?.cancel()
            bootstrapTask = nil
            bootstrapID = nil
        }
        bootstrap(allowStalePath: true)
    }

    func retryValidationIfNeeded() {
        guard networkOpportunity, bootstrapTask == nil, !isSubmitting else { return }
        switch state {
        case .authenticated where sessionValidation == .localOnly:
            validationRetry?.cancel()
            validationRetry = nil
            bootstrap()
        case .restorationFailed:
            bootstrap()
        default:
            break
        }
    }

    func setNetworkOpportunity(_ available: Bool) {
        networkOpportunity = available
    }

    /// A system refresh joins the same validation as foreground launch. An
    /// authenticated shell opened from disk is not a dispatch credential.
    func activateForBackground() async -> Int32? {
        guard !isSubmitting, !Task.isCancelled else { return nil }
        if bootstrapTask == nil {
            if case .bootstrapping = state { bootstrap() } else { retryValidationIfNeeded() }
        }
        await bootstrapTask?.value
        guard !isSubmitting, !Task.isCancelled, sessionValidation == .verified,
            case .authenticated(let profile) = state
        else { return nil }
        return profile.uid
    }

    private func restore(id: UUID, allowStalePath: Bool) async {
        let locallyOpen: Bool
        if case .authenticated = state { locallyOpen = true } else { locallyOpen = false }
        if !locallyOpen {
            validationMessage = nil
            state = .bootstrapping
            startSlowTimer()
        }
        do {
            if !locallyOpen || currentToken == nil {
                let (token, binding) = try await credentials.load()
                try checkBootstrap(id)
                guard let token else {
                    state = .signedOut(.initial)
                    return
                }
                await install(token)
                try checkBootstrap(id)
                if let binding, binding.matches(baseURL: baseURL, token: token) {
                    sessionValidation = .localOnly
                    state = .authenticated(binding.profile)
                    stopSlowTimer()
                }
            }
            guard networkOpportunity || allowStalePath else {
                if case .bootstrapping = state { state = .restorationFailed(.network) }
                return
            }
            let profile = try await withAuthenticationDeadline { [apiClient] in
                try await apiClient.me()
            }
            try checkBootstrap(id)
            guard let token = currentToken else { throw CancellationError() }
            try await credentials.save(token, profile: profile, replacing: token)
            try checkBootstrap(id)
            if case .authenticated(let cached) = state, cached.uid != profile.uid {
                // Fence the old stores before this token can authorize any
                // feature request as a different account.
                state = .authenticated(profile)
            }
            try await apiClient.authorizeStoredSession(expectedToken: token)
            try checkBootstrap(id)
            validationFailures = 0
            sessionValidation = .verified
            state = .authenticated(profile)
        } catch is CancellationError {
        } catch APIError.invalidToken {
            guard bootstrapID == id else { return }
            isSubmitting = true
            defer { isSubmitting = false }
            logger.notice("Session restoration rejected an invalid credential")
            await invalidate(reason: .invalidOrRevoked)
        } catch {
            guard bootstrapID == id else { return }
            logFailure(operation: "restore", error: error)
            if case .authenticated = state {
                validationFailures += 1
                let seconds = min(60, 1 << min(validationFailures, 6))
                validationRetry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    self?.retryValidationIfNeeded()
                }
            } else {
                state = .restorationFailed(startupFailure(error))
            }
        }
    }

    private func checkBootstrap(_ id: UUID) throws {
        try Task.checkCancellation()
        guard bootstrapID == id, !isSubmitting else { throw CancellationError() }
    }

    private func install(_ token: String) async {
        let generation = UUID()
        credentialGeneration = generation
        currentToken = token
        await apiClient.installStoredSession(token) { [weak self] old, new in
            guard let self else { throw CancellationError() }
            try await self.persistRefresh(from: old, to: new, generation: generation)
        }
    }

    private func persistRefresh(from old: String, to new: String, generation: UUID) async throws {
        guard credentialGeneration == generation, currentToken == old else {
            throw CancellationError()
        }
        try await credentials.refresh(
            from: old, to: new, retainBinding: sessionValidation == .verified)
        guard credentialGeneration == generation else { throw CancellationError() }
        currentToken = new
    }

    private func finishSignIn(_ token: String, profile: MeResponse) async throws {
        try await credentials.save(token, profile: profile)
        await install(token)
        try await apiClient.authorizeStoredSession(expectedToken: token)
        sessionValidation = .verified
        state = .authenticated(profile)
    }

    private func invalidate(reason: SignedOutReason) async {
        await lockSession(reason: reason)
        try? await credentials.delete()
    }

    private func lockSession(reason: SignedOutReason) async {
        credentialGeneration = UUID()
        currentToken = nil
        validationRetry?.cancel()
        validationRetry = nil
        sessionValidation = .localOnly
        state = .signedOut(reason)
        await apiClient.installStoredSession(nil, onRefresh: nil)
    }

    private func startSlowTimer() {
        slowTask?.cancel()
        isSlow = false
        slowTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
                self?.isSlow = true
            } catch is CancellationError {} catch {}
        }
    }

    private func stopSlowTimer() {
        slowTask?.cancel()
        slowTask = nil
        isSlow = false
    }

    private func withAuthenticationDeadline<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw AuthenticationAttemptError.timedOut
            }
            defer { group.cancelAll() }
            // Two installed children ensure next() cannot return nil.
            return try await group.next()!
        }
    }

    private func startupFailure(_ error: Error) -> AuthStartupFailure {
        switch error {
        case AuthenticationAttemptError.timedOut, APIError.transport, is URLError:
            return .network
        case APIError.unavailable:
            return .server
        case APIError.http(let status, _) where status >= 500:
            return .server
        case APIError.invalidResponse(let status) where status >= 500:
            return .server
        default:
            return .unknown
        }
    }

    func signIn(username: String, password: String) async {
        guard !isSubmitting else { return }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else {
            validationMessage = "Enter a username and password."
            return
        }
        validationMessage = nil
        isSubmitting = true
        startSlowTimer()
        defer {
            isSubmitting = false
            stopSlowTimer()
        }
        do {
            let (candidate, me) = try await withAuthenticationDeadline {
                [apiClient, credentialLoginClient] in
                guard
                    let candidate = try await credentialLoginClient.login(
                        username: username, password: password)
                else { throw AuthenticationAttemptError.invalidCredentials }
                let me = try await apiClient.authenticate(candidateJWT: candidate)
                return (candidate, me)
            }
            try Task.checkCancellation()
            try await finishSignIn(candidate, profile: me)
        } catch is CancellationError {
        } catch APIError.invalidToken, AuthenticationAttemptError.invalidCredentials {
            logger.notice("Credential sign-in rejected an invalid credential")
            validationMessage = "Invalid credentials."
        } catch AuthenticationAttemptError.timedOut {
            validationMessage = "Sign-in timed out. Try again."
        } catch CredentialLoginError.unavailable {
            logger.error("Credential sign-in provider is unavailable")
            validationMessage = "Authentication service is unavailable."
        } catch {
            logFailure(operation: "credential sign-in", error: error)
            switch startupFailure(error) {
            case .network: validationMessage = "Check your connection and try again."
            case .server: validationMessage = "Authentication service is unavailable."
            case .unknown: validationMessage = "Authentication could not be completed."
            }
        }
    }

    func logout() async {
        guard case .authenticated = state, !isSubmitting else { return }
        signOutError = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await prepareForSignOut?()
            bootstrapTask?.cancel()
            bootstrapID = nil
            bootstrapTask = nil
            try await credentials.delete()
            await lockSession(reason: .loggedOut)
        } catch {
            logFailure(operation: "logout", error: error)
            signOutError = "Could not sign out. Your session is still active. Try again."
        }
    }

    func sessionDidExpire() async {
        guard case .authenticated = state, !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        bootstrapTask?.cancel()
        bootstrapID = nil
        bootstrapTask = nil
        logger.notice("Authenticated session expired")
        validationMessage = nil
        await invalidate(reason: .invalidOrRevoked)
    }

    private func logFailure(operation: String, error: Error) {
        switch error {
        case APIError.invalidResponse(let statusCode):
            logger.error(
                "\(operation, privacy: .public) failed with HTTP status \(statusCode, privacy: .public)"
            )
        case KeychainTokenStorageError.operationFailed(let storageOperation, let status):
            logger.error(
                "\(operation, privacy: .public) failed while \(storageOperation, privacy: .public) token storage: \(status, privacy: .public)"
            )
        case APIError.unavailable:
            logger.error("\(operation, privacy: .public) is unavailable")
        case APIError.invalidToken:
            logger.notice("\(operation, privacy: .public) rejected an invalid credential")
        case APIError.transport:
            logger.error("\(operation, privacy: .public) failed during transport")
        case CredentialLoginError.unavailable:
            logger.error("\(operation, privacy: .public) provider is unavailable")
        default:
            logger.error(
                "\(operation, privacy: .public) failed with an unexpected non-secret error")
        }
    }

    #if DEBUG
        func signIn(candidateJWT: String) async {
            isSubmitting = true
            defer { isSubmitting = false }
            do {
                let me = try await apiClient.authenticate(candidateJWT: candidateJWT)
                try await finishSignIn(candidateJWT, profile: me)
            } catch {
                logFailure(operation: "manual JWT sign-in", error: error)
                validationMessage = "Invalid credentials."
            }
        }

        func createDevSession(uid: Int32) async {
            isSubmitting = true
            defer { isSubmitting = false }
            do {
                let token = try await apiClient.createDevSession(uid: uid, clientID: clientID)
                let me = try await apiClient.authenticate(candidateJWT: token)
                try await finishSignIn(token, profile: me)
            } catch {
                logFailure(operation: "development session", error: error)
                validationMessage = "Authentication could not be completed."
            }
        }

        private var clientID: String {
            let key = "AuthenticationClientID"
            if let existing = UserDefaults.standard.string(forKey: key) { return existing }
            let identifier = UUID().uuidString
            UserDefaults.standard.set(identifier, forKey: key)
            return identifier
        }
    #endif
}
