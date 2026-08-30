public protocol ChahuaAPIClient: Sendable {
    func authenticate(candidateJWT: String) async throws -> MeResponse
    func createDevSession(uid: Int32, clientID: String) async throws -> String

    func me() async throws -> MeResponse
    func listMessages(chatID: Int64, query: ListMessagesQuery) async throws -> ListMessagesResponse
    func sendMessage(chatID: Int64, body: CreateMessageBody) async throws -> MessageResponse
}
