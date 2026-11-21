import ChahuaAPI
import Combine
import Foundation
import XCTest

@testable import chahua_apple

@MainActor
final class AuthSessionModelTests: XCTestCase {
    func testSessionStoresArePreparedBeforeAuthenticationInvalidatesViews() async throws {
        let api = FakeChatAPI()
        let profile = try JSONDecoder().decode(
            MeResponse.self,
            from: Data(
                #"{"uid":1,"username":"Ada","gender":2,"stickerPackOrder":[],"permissions":[]}"#
                    .utf8))
        await api.setAuthenticatedProfile(profile)
        let model = AuthSessionModel(
            apiClient: api, credentialLoginClient: PrototypeCredentialLoginClient(),
            tokenStorage: InMemorySessionTokenStorage(token: "isolated-session"))
        var preparedUID: Int32?
        var publicationCount = 0
        var preparedAtPublication = -1
        var observedPreparedAuthentication = false
        var observedPreparedSignOut = false
        model.willTransitionSession = { state in
            preparedAtPublication = publicationCount
            if case .authenticated(let me) = state {
                preparedUID = me.uid
            } else {
                preparedUID = nil
            }
        }
        let observation = model.objectWillChange.sink { publicationCount += 1 }
        let stateObservation = model.$state.dropFirst().sink { state in
            if case .authenticated(let me) = state {
                observedPreparedAuthentication =
                    preparedUID == me.uid && publicationCount > preparedAtPublication
            } else if case .signedOut = state {
                observedPreparedSignOut =
                    preparedUID == nil && publicationCount > preparedAtPublication
            }
        }
        defer { stateObservation.cancel() }
        defer { observation.cancel() }
        await restore(model)
        XCTAssertTrue(observedPreparedAuthentication)
        await model.logout()
        XCTAssertTrue(observedPreparedSignOut)
        XCTAssertNil(preparedUID)
    }

    func testFailedLocalPurgeKeepsAuthenticatedSessionUntilExplicitRetry() async throws {
        let api = FakeChatAPI()
        let profile = try JSONDecoder().decode(
            MeResponse.self,
            from: Data(
                #"{"uid":1,"username":"Ada","gender":2,"stickerPackOrder":[],"permissions":[]}"#
                    .utf8))
        await api.setAuthenticatedProfile(profile)
        let tokenStorage = InMemorySessionTokenStorage(token: "disposable-session")
        let model = AuthSessionModel(
            apiClient: api, credentialLoginClient: PrototypeCredentialLoginClient(),
            tokenStorage: tokenStorage)
        await restore(model)
        model.prepareForSignOut = { throw CocoaError(.fileWriteNoPermission) }
        await model.logout()
        guard case .authenticated(let retained) = model.state else {
            return XCTFail("A failed purge must not complete sign-out")
        }
        XCTAssertEqual(retained.uid, profile.uid)
        XCTAssertNotNil(model.signOutError)
        let retainedToken = await tokenStorage.loadToken()
        XCTAssertEqual(retainedToken, "disposable-session")
        var purged = false
        model.prepareForSignOut = {
            let token = await tokenStorage.loadToken()
            XCTAssertEqual(token, "disposable-session")
            purged = true
        }
        await model.logout()
        guard case .signedOut(.loggedOut) = model.state else {
            return XCTFail("Successful purge must allow explicit sign-out")
        }
        XCTAssertTrue(purged)
        let removed = await tokenStorage.loadToken()
        XCTAssertNil(removed)
    }

    func testExpirationDoesNotInvokeExplicitSignOutCleanup() async throws {
        let api = FakeChatAPI()
        let profile = try JSONDecoder().decode(
            MeResponse.self,
            from: Data(
                #"{"uid":1,"username":"Ada","gender":2,"stickerPackOrder":[],"permissions":[]}"#
                    .utf8))
        await api.setAuthenticatedProfile(profile)
        let model = AuthSessionModel(
            apiClient: api, credentialLoginClient: PrototypeCredentialLoginClient(),
            tokenStorage: InMemorySessionTokenStorage(token: "disposable-expiring-session"))
        model.prepareForSignOut = { XCTFail("Expiration must never purge local work") }
        await restore(model)
        await model.sessionDidExpire()
        guard case .signedOut(.invalidOrRevoked) = model.state else {
            return XCTFail("Expiration must keep its existing signed-out reason")
        }
    }

    func testRetryableRestoreFailuresRetainCredentialAndRetryAuthenticates() async throws {
        let failures: [(APIError, AuthStartupFailure)] = [
            (.transport(URLError(.notConnectedToInternet)), .network),
            (.http(status: 503, body: Data()), .server),
            (.invalidResponse(statusCode: 503), .server),
            (.http(status: 403, body: Data()), .unknown),
        ]
        let profile = try JSONDecoder().decode(
            MeResponse.self,
            from: Data(
                #"{"uid":1,"username":"Ada","gender":2,"stickerPackOrder":[],"permissions":[]}"#
                    .utf8))
        for (error, expected) in failures {
            let api = FakeChatAPI()
            await api.setAuthenticationFailure(error)
            let storage = InMemorySessionTokenStorage(token: "isolated-startup-token")
            let model = AuthSessionModel(
                apiClient: api, credentialLoginClient: PrototypeCredentialLoginClient(),
                tokenStorage: storage)
            await restore(model)
            guard case .restorationFailed(let actual) = model.state else {
                XCTFail("A non-401 restoration error must remain retryable, not sign out.")
                continue
            }
            XCTAssertEqual(actual, expected)
            let retained = await storage.loadToken()
            XCTAssertEqual(retained, "isolated-startup-token")
            await api.setAuthenticationFailure(nil)
            await api.setAuthenticatedProfile(profile)
            await restore(model, retry: true)
            guard case .authenticated(let restored) = model.state else {
                XCTFail("Retry must authenticate using the retained credential.")
                continue
            }
            XCTAssertEqual(restored.uid, profile.uid)
        }
    }

    func testRejectedRestoredCredentialIsRemovedAndShowsExpiredSignIn() async throws {
        let api = FakeChatAPI()
        await api.setAuthenticationFailure(.invalidToken)
        let storage = InMemorySessionTokenStorage(token: "isolated-rejected-token")
        let model = AuthSessionModel(
            apiClient: api, credentialLoginClient: PrototypeCredentialLoginClient(),
            tokenStorage: storage)
        await restore(model)
        guard case .signedOut(.invalidOrRevoked) = model.state else {
            return XCTFail("A rejected credential must require sign-in, not Retry.")
        }
        let removed = await storage.loadToken()
        XCTAssertNil(removed)
    }

    func testMissingCredentialShowsInitialSignInInsteadOfServiceFailure() async {
        let model = AuthSessionModel(
            apiClient: FakeChatAPI(), credentialLoginClient: PrototypeCredentialLoginClient(),
            tokenStorage: InMemorySessionTokenStorage(token: nil))
        await restore(model)
        guard case .signedOut(.initial) = model.state else {
            return XCTFail("No stored credential should open normal native sign-in.")
        }
    }

    func testMatchingBindingOpensBeforeValidationAndRetryDoesNotResetShell() async throws {
        let api = FakeChatAPI()
        let profile = try JSONDecoder().decode(
            MeResponse.self,
            from: Data(
                #"{"uid":17,"username":"Ada","gender":2,"stickerPackOrder":[],"permissions":[]}"#
                    .utf8))
        let storage = InMemorySessionTokenStorage(
            token: "exact token",
            binding: .init(baseURL: "test", token: "exact token", profile: profile))
        let model = AuthSessionModel(
            apiClient: api, credentialLoginClient: PrototypeCredentialLoginClient(),
            tokenStorage: storage, baseURL: "test")
        await api.setAuthenticationFailure(.transport(URLError(.notConnectedToInternet)))
        await restore(model)
        guard case .authenticated(let cached) = model.state else {
            return XCTFail("Expected cached session")
        }
        XCTAssertEqual(cached.uid, 17)
        XCTAssertEqual(model.sessionValidation, .localOnly)
        let verified = expectation(description: "Verification completes")
        let observation = model.$state.dropFirst().sink { state in
            guard case .authenticated(let account) = state else {
                return XCTFail("Retry must not reset the shell")
            }
            XCTAssertEqual(account.uid, 17)
            if model.sessionValidation == .verified { verified.fulfill() }
        }
        await api.setAuthenticationFailure(nil)
        await api.setAuthenticatedProfile(profile)
        model.retry()
        await fulfillment(of: [verified], timeout: 4)
        observation.cancel()
    }

    func testMismatchedCredentialCannotOpenCachedIdentity() async throws {
        let api = FakeChatAPI()
        let profile = try JSONDecoder().decode(
            MeResponse.self,
            from: Data(
                #"{"uid":17,"username":"Ada","gender":2,"stickerPackOrder":[],"permissions":[]}"#
                    .utf8))
        await api.setAuthenticationFailure(.transport(URLError(.notConnectedToInternet)))
        for (base, token) in [("test", "other token"), ("different", "exact token")] {
            let storage = InMemorySessionTokenStorage(
                token: "exact token", binding: .init(baseURL: base, token: token, profile: profile))
            let model = AuthSessionModel(
                apiClient: api, credentialLoginClient: PrototypeCredentialLoginClient(),
                tokenStorage: storage, baseURL: "test")
            await restore(model)
            guard case .restorationFailed(.network) = model.state else {
                return XCTFail("A different URL or token must not disclose the account")
            }
        }
    }

    func testBackgroundActivationJoinsValidationOfOpenLocalSession() async throws {
        let api = FakeChatAPI()
        let profile = try JSONDecoder().decode(
            MeResponse.self,
            from: Data(
                #"{"uid":17,"username":"Ada","gender":2,"stickerPackOrder":[],"permissions":[]}"#
                    .utf8))
        let model = AuthSessionModel(
            apiClient: api, credentialLoginClient: PrototypeCredentialLoginClient(),
            tokenStorage: InMemorySessionTokenStorage(
                token: "test-token",
                binding: .init(baseURL: "test", token: "test-token", profile: profile)),
            baseURL: "test")
        await api.holdNextMeRequest()
        model.bootstrap()
        await api.waitForMeRequest()
        let backgroundActivation = Task { await model.activateForBackground() }
        XCTAssertEqual(model.sessionValidation, .localOnly)
        if case .authenticated(let cached) = model.state {
            XCTAssertEqual(cached.uid, profile.uid)
        } else {
            XCTFail("The account shell must open before validation completes")
        }
        await api.releaseMeRequest(profile)
        let uid = await backgroundActivation.value
        let requests = await api.meRequestCount
        XCTAssertEqual(uid, 17)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(model.sessionValidation, .verified)
    }

    func testExplicitRetryCanValidateDespiteAnUnsatisfiedPathHint() async throws {
        let api = FakeChatAPI()
        let profile = try JSONDecoder().decode(
            MeResponse.self,
            from: Data(
                #"{"uid":17,"username":"Ada","gender":2,"stickerPackOrder":[],"permissions":[]}"#
                    .utf8))
        let storage = InMemorySessionTokenStorage(
            token: "test-token",
            binding: .init(baseURL: "test", token: "test-token", profile: profile))
        let model = AuthSessionModel(
            apiClient: api, credentialLoginClient: PrototypeCredentialLoginClient(),
            tokenStorage: storage, baseURL: "test")
        await api.setAuthenticatedProfile(profile)
        model.setNetworkOpportunity(false)
        let unavailable = await model.activateForBackground()
        let initialRequests = await api.meRequestCount
        XCTAssertNil(unavailable)
        XCTAssertEqual(initialRequests, 0)
        XCTAssertEqual(model.sessionValidation, .localOnly)
        await restore(model, retry: true)
        let verifiedRequests = await api.meRequestCount
        XCTAssertEqual(verifiedRequests, 1)
        XCTAssertEqual(model.sessionValidation, .verified)
    }

    func testRefreshedStoredSessionReopensOfflineWithNewCredentialBinding() async throws {
        let api = FakeChatAPI()
        let profile = try JSONDecoder().decode(
            MeResponse.self,
            from: Data(
                #"{"uid":17,"username":"Ada","gender":2,"stickerPackOrder":[],"permissions":[]}"#
                    .utf8))
        let old = " old-token "
        let storage = InMemorySessionTokenStorage(
            token: old, binding: .init(baseURL: "test", token: old, profile: profile))
        let model = AuthSessionModel(
            apiClient: api, credentialLoginClient: PrototypeCredentialLoginClient(),
            tokenStorage: storage, baseURL: "test")
        await api.setAuthenticatedProfile(profile)
        await api.refreshOnNextMe("new-token")
        let validatedUID = await model.activateForBackground()
        let savedToken = await storage.loadToken()
        let binding = await storage.loadOfflineBinding()
        XCTAssertEqual(validatedUID, 17)
        XCTAssertEqual(savedToken, "new-token")
        XCTAssertEqual(binding?.matches(baseURL: "test", token: "new-token"), true)
        XCTAssertEqual(binding?.matches(baseURL: "test", token: old), false)

        let relaunched = AuthSessionModel(
            apiClient: api, credentialLoginClient: PrototypeCredentialLoginClient(),
            tokenStorage: storage, baseURL: "test")
        relaunched.setNetworkOpportunity(false)
        _ = await relaunched.activateForBackground()
        guard case .authenticated(let cached) = relaunched.state else {
            return XCTFail("The refreshed credential must still open the account offline")
        }
        XCTAssertEqual(cached.uid, profile.uid)
        XCTAssertEqual(relaunched.sessionValidation, .localOnly)
    }

    private func restore(_ model: AuthSessionModel, retry: Bool = false) async {
        let finished = expectation(description: "Authentication attempt completes")
        let observation = model.$state.dropFirst().filter { state in
            if case .bootstrapping = state { return false }
            return true
        }.prefix(1).sink { _ in finished.fulfill() }
        if retry { model.retry() } else { model.bootstrap() }
        await fulfillment(of: [finished], timeout: 2)
        observation.cancel()
    }
}
