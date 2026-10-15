import ChahuaAPI
import Foundation
import XCTest

@testable import chahua_apple

@MainActor
final class MessageSearchModelTests: XCTestCase {
    func testQueriesShorterThanTwoUnicodeScalarsDoNotSearch() async throws {
        let server = HeldSearchServer()
        let model = server.model()

        model.queryText = "  a  "
        XCTAssertEqual(model.phase, .tooShort)
        model.submit()
        XCTAssertEqual(model.phase, .tooShort)
        model.queryText = "   "
        XCTAssertEqual(model.phase, .idle)

        // Two CJK characters meet the server's two-character minimum.
        model.queryText = " 早上 "
        try await server.waitForRequests(1)
        XCTAssertEqual(server.queries.first?.q, "早上")
        XCTAssertEqual(server.queries.first?.offset, nil)
        XCTAssertEqual(server.queries.first?.limit, MessageSearchModel.pageSize)
    }

    func testWhitespaceOnlyEditsDoNotRepeatTheActiveSearch() async throws {
        let server = HeldSearchServer()
        let model = server.model()

        model.queryText = "hello"
        try await server.waitForRequests(1)
        model.queryText = "hello "
        model.queryText = " hello"
        server.respond(0, .success(try page([1], nextOffset: nil)))
        try await eventually { model.phase == .loaded }
        XCTAssertEqual(server.queries.count, 1)
        model.submit()
        try await server.waitForRequests(2)
        server.respond(1, .success(try page([1], nextOffset: nil)))
        try await server.waitForRequests(2)
    }

    func testSupersededResponseCannotReplaceNewerResults() async throws {
        let server = HeldSearchServer()
        let model = server.model()

        model.queryText = "ab"
        try await server.waitForRequests(1)
        model.queryText = "abc"
        try await server.waitForRequests(2)

        server.respond(1, .success(try page([3], nextOffset: nil)))
        try await eventually { model.phase == .loaded }
        server.respond(0, .success(try page([1, 2], nextOffset: 20)))
        try await settle()

        XCTAssertEqual(model.results.map(\.id), [MessageID(3)])
        XCTAssertNil(model.nextOffset)
    }

    func testLoadMoreAppendsUniqueResultsUntilTheServerStops() async throws {
        let server = HeldSearchServer()
        let model = server.model()

        model.queryText = "hello"
        try await server.waitForRequests(1)
        server.respond(0, .success(try page([10, 9], nextOffset: 20)))
        try await eventually { model.phase == .loaded }

        model.loadMore()
        model.loadMore()
        try await server.waitForRequests(2)
        XCTAssertEqual(server.queries[1].offset, 20)
        XCTAssertEqual(server.queries[1].q, "hello")
        // A new message shifted the offset window: page two repeats message 9.
        server.respond(1, .success(try page([9, 8], nextOffset: nil)))
        try await eventually { !model.isLoadingMore }

        XCTAssertEqual(model.results.map(\.id), [10, 9, 8].map { MessageID($0) })
        XCTAssertNil(model.nextOffset)
        model.loadMore()
        try await settle()
        XCTAssertEqual(server.queries.count, 2)
    }

    func testFailedNextPageKeepsResultsAndRetriesSameOffset() async throws {
        let server = HeldSearchServer()
        let model = server.model()

        model.queryText = "hello"
        try await server.waitForRequests(1)
        server.respond(0, .success(try page([10], nextOffset: 20)))
        try await eventually { model.phase == .loaded }

        model.loadMore()
        try await server.waitForRequests(2)
        server.respond(1, .failure(URLError(.notConnectedToInternet)))
        try await eventually { model.loadMoreFailed }
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.results.map(\.id), [MessageID(10)])
        XCTAssertEqual(model.nextOffset, 20)

        model.loadMore()
        try await server.waitForRequests(3)
        XCTAssertFalse(model.loadMoreFailed)
        XCTAssertEqual(server.queries[2].offset, 20)
    }

    func testSortChangeRestartsFromTheFirstPageAndDropsPendingPage() async throws {
        let server = HeldSearchServer()
        let model = server.model()

        model.queryText = "hello"
        try await server.waitForRequests(1)
        server.respond(0, .success(try page([10], nextOffset: 20)))
        try await eventually { model.phase == .loaded }
        model.loadMore()
        try await server.waitForRequests(2)

        model.sort = .newest
        try await server.waitForRequests(3)
        XCTAssertEqual(server.queries[2].sort, .newest)
        XCTAssertNil(server.queries[2].offset)
        XCTAssertEqual(model.phase, .loading)
        XCTAssertTrue(model.results.isEmpty)

        server.respond(1, .success(try page([9], nextOffset: nil)))
        server.respond(2, .success(try page([42], nextOffset: nil)))
        try await eventually { model.phase == .loaded }
        try await settle()
        XCTAssertEqual(model.results.map(\.id), [MessageID(42)])
    }

    func testServerWithoutSearchReportsUnavailableAndRetryRecovers() async throws {
        let server = HeldSearchServer()
        let model = server.model()

        model.queryText = "hello"
        try await server.waitForRequests(1)
        server.respond(0, .failure(APIError.http(status: 503, body: Data())))
        try await eventually { model.phase == .failed(.unavailable) }

        model.retry()
        try await server.waitForRequests(2)
        server.respond(1, .failure(URLError(.timedOut)))
        try await eventually { model.phase == .failed(.other) }

        model.retry()
        try await server.waitForRequests(3)
        server.respond(2, .success(try page([], nextOffset: nil)))
        try await eventually { model.phase == .loaded }
        XCTAssertTrue(model.results.isEmpty)
    }

    private func page(_ ids: [UInt64], nextOffset: Int?) throws -> SearchMessagesResponse {
        SearchMessagesResponse(
            messages: try ids.map { try TimelineTestFixtures.message(id: $0, at: 0) },
            nextOffset: nextOffset)
    }
}

/// Holds each search request until the test resolves it, in any order.
@MainActor
private final class HeldSearchServer {
    private(set) var queries: [SearchMessagesQuery] = []
    private var pending: [Int: CheckedContinuation<SearchMessagesResponse, Error>] = [:]

    func model() -> MessageSearchModel {
        MessageSearchModel(chatID: "chat", debounce: .zero) { [unowned self] query in
            try await self.search(query)
        }
    }

    func waitForRequests(_ count: Int) async throws {
        try await eventually { self.pending.count + self.resolved >= count }
        XCTAssertEqual(queries.count, count)
    }

    func respond(_ index: Int, _ result: Result<SearchMessagesResponse, Error>) {
        guard let continuation = pending.removeValue(forKey: index) else {
            return XCTFail("No pending search request \(index)")
        }
        resolved += 1
        continuation.resume(with: result)
    }

    private var resolved = 0

    private func search(_ query: SearchMessagesQuery) async throws -> SearchMessagesResponse {
        let index = queries.count
        queries.append(query)
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
}

@MainActor
private func eventually(
    _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
) async throws {
    for _ in 0..<1_000 {
        if condition() { return }
        await Task.yield()
    }
    XCTFail("Condition was not met", file: file, line: line)
    throw CancellationError()
}

/// Lets already-resumed tasks publish before asserting that nothing changed.
@MainActor
private func settle() async throws {
    for _ in 0..<50 { await Task.yield() }
}
