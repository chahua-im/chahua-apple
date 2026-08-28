public extension ChahuaClient {
    func createDevSession(uid: Int32) async throws -> AuthTokenResponse {
        let spec = try HTTPRequestSpec.json(
            .post,
            "/auth/dev-session",
            body: DevSessionRequest(uid: uid),
            requiresAuth: false
        )
        let response = try await send(spec, decoding: AuthTokenResponse.self)
        try await setCredential(.session(token: response.token))
        return response
    }

    func refreshSession() async throws -> AuthTokenResponse {
        AuthTokenResponse(token: try await refreshedToken())
    }
}
