import XCTest

@testable import chahua_apple

@MainActor
final class MessageMenuPageTests: XCTestCase {
    func testTwoPagesKeepAllActionsReachableWithoutAThirdRow() {
        let actions: [MessageMenuAction] = [
            .reply, .thread, .copy, .forward, .edit, .save, .select,
            .reactionDetails, .copyLink, .pin, .delete,
        ]
        let first = MessageMenuPage(actions: actions, page: 0)
        XCTAssertEqual(Array(first.actions), Array(actions.prefix(9)))
        XCTAssertEqual(first.navigationSlot, 9)
        let second = MessageMenuPage(actions: actions, page: first.nextPage)
        XCTAssertEqual(
            Array(second.actions), [.save, .select, .reactionDetails, .copyLink, .pin, .delete])
        XCTAssertEqual(second.navigationSlot, 4)
        XCTAssertEqual(second.nextPage, 0)
        XCTAssertEqual(Set(first.actions).union(second.actions), Set(actions))
        XCTAssertLessThanOrEqual(second.actions.count + 1, 10)
    }

    func testLiveRemovalOfOverflowReturnsToTheOnlyPage() {
        let actions: [MessageMenuAction] = [.copy, .forward, .select, .copyLink]
        let page = MessageMenuPage(actions: actions, page: 1)
        XCTAssertEqual(Array(page.actions), actions)
        XCTAssertEqual(page.page, 0)
        XCTAssertFalse(page.hasNavigation)
        XCTAssertNil(page.navigationSlot)
    }

    func testAllDistinctActionsRemainReachableWhenBothPagesAreFull() {
        let actions = MessageMenuAction.allCases
        let first = MessageMenuPage(actions: actions, page: 0)
        let second = MessageMenuPage(actions: actions, page: 1)
        XCTAssertEqual(Set(first.actions).union(second.actions), Set(actions))
        XCTAssertLessThanOrEqual(first.actions.count + 1, 10)
        XCTAssertLessThanOrEqual(second.actions.count + 1, 10)
        XCTAssertEqual(second.actions.last, actions.last)
    }
}
