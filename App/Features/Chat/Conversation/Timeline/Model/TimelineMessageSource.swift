import ChahuaAPI

struct TimelinePage: Sendable {
    let response: ListMessagesResponse
    let journalFloor: UInt64?
    let at: String?

    init(response: ListMessagesResponse, journalFloor: UInt64? = nil, at: String? = nil) {
        self.response = response
        self.journalFloor = journalFloor
        self.at = at
    }
}

@MainActor
protocol TimelineMessageSource: AnyObject {
    /// Fetch remote history only; the model owns acceptance, replay and saved paging.
    func fetchMessages(
        chatID: String,
        query: ListMessagesQuery
    ) async throws -> TimelinePage
    func fetchMessages(
        chatID: String, query: ListMessagesQuery, ignoringPath: Bool
    ) async throws -> TimelinePage
    func waitForTimelineSync() async throws
    func canPromoteCachedTail(_ key: ConversationKey) -> Bool

    func isPublishedReadTarget(_ message: MessageResponse) -> Bool
}

extension TimelineMessageSource {
    func fetchMessages(
        chatID: String, query: ListMessagesQuery, ignoringPath: Bool
    ) async throws -> TimelinePage {
        try await fetchMessages(chatID: chatID, query: query)
    }

    func waitForTimelineSync() async throws {}
    func canPromoteCachedTail(_ key: ConversationKey) -> Bool { false }

    func isPublishedReadTarget(_ message: MessageResponse) -> Bool { true }
}

extension ChatStore: TimelineMessageSource {}
