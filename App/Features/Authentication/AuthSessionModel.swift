import os
import Combine
import ChahuaAPI
import SwiftUI

enum SignedOutReason { case initial, invalidOrRevoked, loggedOut }
enum AuthSessionState { case bootstrapping, signedOut(SignedOutReason), authenticated(MeResponse), networkUnavailable }

@MainActor
final class AuthSessionModel: ObservableObject {
    @Published private(set) var state: AuthSessionState = .bootstrapping
    @Published private(set) var validationMessage: LocalizedStringKey?
    @Published private(set) var isSubmitting = false

    private let apiClient: any ChahuaAPIClient
    private let credentialLoginClient: any CredentialLoginProviding
    private let tokenStorage: any SessionTokenStorage
    private var bootstrapTask: Task<Void, Never>?

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
        guard bootstrapTask == nil else { return }
        bootstrapTask = Task { [weak self] in
            defer { self?.bootstrapTask = nil }
            await self?.restore()
        }
    }

    func retry() { bootstrap() }

    private func restore() async {
        let priorState = state
        state = .bootstrapping
        do {
            guard let storedToken = try await tokenStorage.loadToken() else {
                state = .signedOut(.initial)
                return
            }
            state = .authenticated(try await apiClient.authenticate(candidateJWT: storedToken))
        } catch is CancellationError {
            state = priorState
        } catch APIError.invalidToken {
            logger.notice("Session restoration rejected an invalid credential")
            try? await tokenStorage.deleteToken()
            state = .signedOut(.invalidOrRevoked)
        } catch APIError.unavailable {
            logger.error("Session restoration is unavailable")
            state = .networkUnavailable
        } catch APIError.transport {
            logger.error("Session restoration failed during transport")
            state = .networkUnavailable
        } catch {
            logFailure(operation: "restore", error: error)
            state = .signedOut(.initial)
            validationMessage = "Authentication could not be completed."
        }
    }

    func signIn(username: String, password: String) async {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else {
            validationMessage = "Enter a username and password."
            return
        }
        validationMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            guard let candidate = try await credentialLoginClient.login(username: username, password: password) else {
                logger.notice("Credential sign-in returned no candidate")
                validationMessage = "Invalid credentials."
                return
            }
            let me = try await apiClient.authenticate(candidateJWT: candidate)
            try await tokenStorage.saveToken(candidate)
            state = .authenticated(me)
        } catch is CancellationError { }
        catch APIError.invalidToken {
            logger.notice("Credential sign-in rejected an invalid credential")
            validationMessage = "Invalid credentials."
        }
        catch CredentialLoginError.unavailable {
            logger.error("Credential sign-in provider is unavailable")
            validationMessage = "Authentication service is unavailable."
        }
        catch {
            logFailure(operation: "credential sign-in", error: error)
            validationMessage = "Authentication could not be completed."
        }
    }

    func logout() async {
        guard case .authenticated = state else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await tokenStorage.deleteToken()
            state = .signedOut(.loggedOut)
        } catch {
            logFailure(operation: "logout", error: error)
            validationMessage = "Could not sign out. Try again."
        }
    }

    private func logFailure(operation: String, error: Error) {
        switch error {
        case let APIError.invalidResponse(statusCode):
            logger.error("\(operation, privacy: .public) failed with HTTP status \(statusCode, privacy: .public)")
        case let KeychainTokenStorageError.operationFailed(operation: storageOperation, status: status):
            logger.error("\(operation, privacy: .public) failed while \(storageOperation, privacy: .public) token storage: \(status, privacy: .public)")
        case APIError.unavailable:
            logger.error("\(operation, privacy: .public) is unavailable")
        case APIError.invalidToken:
            logger.notice("\(operation, privacy: .public) rejected an invalid credential")
        case APIError.transport:
            logger.error("\(operation, privacy: .public) failed during transport")
        case CredentialLoginError.unavailable:
            logger.error("\(operation, privacy: .public) provider is unavailable")
        default:
            logger.error("\(operation, privacy: .public) failed with an unexpected non-secret error")
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
