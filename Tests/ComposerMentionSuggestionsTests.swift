import ChahuaAPI
import XCTest

@testable import chahua_apple

@MainActor
final class ComposerMentionSuggestionsTests: XCTestCase {
    func testLateSearchCannotReplaceNewQueryOrReopenDismissedPicker() async throws {
        let input = ComposerInputState()
        let model = ComposerMentionSuggestionsModel()
        let firstStarted = expectation(description: "first search")
        let secondStarted = expectation(description: "second search")
        var first: CheckedContinuation<[MemberResponse], Error>?
        let firstFinished = expectation(description: "first response")
        let secondFinished = expectation(description: "second response")
        var second: CheckedContinuation<[MemberResponse], Error>?
        let search: ComposerMemberSearch = { query in
            defer {
                if query.q == "a" { firstFinished.fulfill() } else { secondFinished.fulfill() }
            }
            return try await withCheckedThrowingContinuation { continuation in
                if query.q == "a" {
                    first = continuation
                    firstStarted.fulfill()
                } else {
                    second = continuation
                    secondStarted.fulfill()
                }
            }
        }
        model.update(
            .init(query: "a", range: NSRange(location: 0, length: 2)), search: search, input: input)
        await fulfillment(of: [firstStarted], timeout: 2)
        model.update(
            .init(query: "b", range: NSRange(location: 0, length: 2)), search: search, input: input)
        await fulfillment(of: [secondStarted], timeout: 2)
        let obsolete = try XCTUnwrap(first)
        let current = try XCTUnwrap(second)
        obsolete.resume(returning: [.init(uid: 1, username: "Ada")])
        await fulfillment(of: [firstFinished], timeout: 2)
        XCTAssertEqual(model.query?.query, "b")
        XCTAssertTrue(model.members.isEmpty)
        model.dismiss()
        current.resume(returning: [.init(uid: 2, username: "Bob")])
        await fulfillment(of: [secondFinished], timeout: 2)
        XCTAssertNil(model.query)
        XCTAssertTrue(model.members.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func testEscapeStaysDismissedUntilTheCaretQueryChanges() {
        let input = ComposerInputState()
        let model = ComposerMentionSuggestionsModel()
        let search: ComposerMemberSearch = { _ in [] }
        let initial = ComposerMentionQuery(query: "", range: NSRange(location: 0, length: 1))
        model.update(initial, search: search, input: input)
        XCTAssertTrue(model.handle(.dismiss, input: input))
        model.update(nil, search: search, input: input, enabled: false)
        model.update(initial, search: search, input: input)
        XCTAssertNil(model.query)
        let changed = ComposerMentionQuery(query: "a", range: NSRange(location: 0, length: 2))
        model.update(changed, search: search, input: input)
        XCTAssertEqual(model.query, changed)
        model.dismiss()
    }
}
