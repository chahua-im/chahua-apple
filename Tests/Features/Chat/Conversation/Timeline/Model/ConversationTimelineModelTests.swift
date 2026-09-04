import Combine
import XCTest
@testable import chahua_apple
import ChahuaAPI

@MainActor
final class ConversationTimelineModelTests: XCTestCase {
    func testInitialLoadPublishesBottomResetWithRemoteRows() async throws {
        let messages = [
            try TimelineTestFixtures.message(id: "1", at: 1),
            try TimelineTestFixtures.message(id: "2", at: 2),
        ]
        let model = ConversationTimelineModel(
            chatID: "chat",
            currentUserID: 1,
            isGroupChat: true,
            source: StaticTimelineSource(page: try TimelineTestFixtures.page(messages)),
            messageStore: ConversationMessageStore()
        )
        var updates: [TimelineHostUpdate] = []
        let cancellable = model.updates.sink { updates.append($0) }

        await model.loadInitial()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.rows.compactMap(\.messageID), ["1", "2"])
        XCTAssertEqual(updates.last?.change, .reset)
        XCTAssertEqual(updates.last?.scroll, .bottom(animated: false))
        cancellable.cancel()
    }
}

@MainActor
private final class StaticTimelineSource: TimelineMessageSource {
    let page: ListMessagesResponse

    init(page: ListMessagesResponse) {
        self.page = page
    }

    func fetchMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse {
        page
    }
}
