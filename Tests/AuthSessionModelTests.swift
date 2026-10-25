import ChahuaAPI
import Combine
import Foundation
import XCTest

@testable import chahua_apple

@MainActor
final class AuthSessionModelTests: XCTestCase {
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
