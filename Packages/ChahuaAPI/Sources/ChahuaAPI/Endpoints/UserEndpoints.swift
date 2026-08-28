public extension ChahuaClient {
    func me() async throws -> MeResponse {
        try await send(
            HTTPRequestSpec(method: .get, path: "/users/me"),
            decoding: MeResponse.self
        )
    }
}
