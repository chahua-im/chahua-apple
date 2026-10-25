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

private enum AuthenticationAttemptError: Error {
    case timedOut, invalidCredentials
}

@MainActor
final class AuthSessionModel: ObservableObject {
    @Published private(set) var state: AuthSessionState = .bootstrapping {
        didSet { stateGeneration &+= 1 }
    }
    @Published private(set) var validationMessage: LocalizedStringKey?
    @Published private(set) var isSubmitting = false
    @Published private(set) var isSlow = false
    var prepareForSignOut: (() async throws -> Void)?

    private let apiClient: any ChahuaAPIClient
    private let credentialLoginClient: any CredentialLoginProviding
    private let tokenStorage: any SessionTokenStorage
    private var bootstrapTask: Task<Void, Never>?
    private var bootstrapID: UUID?
    private var slowTask: Task<Void, Never>?
    private var stateGeneration = 0

    private let logger = Logger(subsystem: "app.chahua.chat", category: "authentication")

    init(
        apiClient: any ChahuaAPIClient,
        credentialLoginClient: any CredentialLoginProviding,
        tokenStorage: any SessionTokenStorage
    ) {
        self.apiClient = apiClient
        self.credentialLoginClient = credentialLoginClient
        self.tokenStorage = tokenStorage
    }

    func bootstrap() {
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
            await restore(id: id)
        }
    }

    func retry() {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        bootstrapID = nil
        bootstrap()
    }

    private func restore(id: UUID) async {
        let priorState = state
        validationMessage = nil
        state = .bootstrapping
        startSlowTimer()
        do {
            let profile = try await withAuthenticationDeadline { [apiClient, tokenStorage] in
                guard let storedToken = try await tokenStorage.loadToken() else {
                    return Optional<MeResponse>.none
                }
                return try await apiClient.authenticate(candidateJWT: storedToken)
            }
            try Task.checkCancellation()
            guard bootstrapID == id else { return }
            if let profile {
                state = .authenticated(profile)
            } else {
                state = .signedOut(.initial)
            }
        } catch is CancellationError {
            if bootstrapID == id { state = priorState }
        } catch APIError.invalidToken {
            guard bootstrapID == id else { return }
            logger.notice("Session restoration rejected an invalid credential")
            try? await tokenStorage.deleteToken()
            guard bootstrapID == id else { return }
            state = .signedOut(.invalidOrRevoked)
        } catch {
            guard bootstrapID == id else { return }
            logFailure(operation: "restore", error: error)
            state = .restorationFailed(startupFailure(error))
        }
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
            try await tokenStorage.saveToken(candidate)
            try Task.checkCancellation()
            state = .authenticated(me)
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
        guard case .authenticated = state else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await prepareForSignOut?()
            try await tokenStorage.deleteToken()
            state = .signedOut(.loggedOut)
        } catch {
            logFailure(operation: "logout", error: error)
            validationMessage = "Could not sign out. Try again."
        }
    }

    func sessionDidExpire() async {
        guard case .authenticated = state else { return }
        let expiredGeneration = stateGeneration
        logger.notice("Authenticated session expired")
        try? await tokenStorage.deleteToken()
        guard stateGeneration == expiredGeneration else { return }
        validationMessage = nil
        state = .signedOut(.invalidOrRevoked)
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
                try await tokenStorage.saveToken(candidateJWT)
                state = .authenticated(me)
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
                try await tokenStorage.saveToken(token)
                state = .authenticated(me)
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
