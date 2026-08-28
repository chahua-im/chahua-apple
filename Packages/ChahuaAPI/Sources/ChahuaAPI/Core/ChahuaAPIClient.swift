public protocol ChahuaAPIClient: Sendable {
    func setCredential(_ credential: ChahuaCredential?) async throws
    func currentCredential() async throws -> ChahuaCredential?

    func createDevSession(uid: Int32) async throws -> AuthTokenResponse
    func refreshSession() async throws -> AuthTokenResponse
    func me() async throws -> MeResponse
    func listMessages(chatID: Int64, query: ListMessagesQuery) async throws -> ListMessagesResponse
    func sendMessage(chatID: Int64, body: CreateMessageBody) async throws -> MessageResponse
}
