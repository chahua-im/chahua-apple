import ChahuaAPI

@MainActor
protocol TimelineMessageSource: AnyObject {
    func fetchMessages(
        chatID: String,
        query: ListMessagesQuery
    ) async throws -> ListMessagesResponse
}

extension ChatStore: TimelineMessageSource {}
