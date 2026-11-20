import ChahuaAPI

@MainActor
protocol TimelineMessageSource: AnyObject {
    /// Fetch remote history only; the model owns acceptance, replay and saved paging.
    func fetchMessages(
        chatID: String,
        query: ListMessagesQuery
    ) async throws -> ListMessagesResponse
    func fetchMessages(
        chatID: String, query: ListMessagesQuery, ignoringPath: Bool
    ) async throws -> ListMessagesResponse

    func isPublishedReadTarget(_ message: MessageResponse) -> Bool
}

extension TimelineMessageSource {
    func fetchMessages(
        chatID: String, query: ListMessagesQuery, ignoringPath: Bool
    ) async throws -> ListMessagesResponse {
        try await fetchMessages(chatID: chatID, query: query)
    }

    func isPublishedReadTarget(_ message: MessageResponse) -> Bool { true }
}

extension ChatStore: TimelineMessageSource {}
