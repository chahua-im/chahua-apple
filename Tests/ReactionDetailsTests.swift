import ChahuaAPI
import Foundation
import XCTest

@testable import chahua_apple

@MainActor
final class ReactionDetailsTests: XCTestCase {
    func testTopEmojiCategoriesUseRankSelectionThenEmojiDisplayOrder() throws {
        let groups = [
            group("z", count: 3),
            group("a", count: 3),
            group("m", count: 3),
            group("b", count: 2),
            group("c", count: 2),
            group("d", count: 1),
            group("e", count: 1),
            group("f", count: 1),
            group("g", reactors: [reactor(uid: 91)]),
            group("h", reactors: [reactor(uid: 91)]),
        ]

        let grouping = ReactionDetailsGrouping(groups: groups)

        XCTAssertEqual(
            grouping.categories.map(\.id),
            [
                .all, .emoji("a"), .emoji("m"), .emoji("z"), .emoji("b"), .emoji("c"),
                .emoji("d"), .emoji("e"), .emoji("f"), .more,
            ]
        )
        XCTAssertEqual(grouping.categories.last?.users.map(\.reactor.uid), [91, 91])
        XCTAssertEqual(grouping.categories.last?.users.map(\.emojis), [["g"], ["h"]])
    }

    func testAllDeduplicatesByUserAndUsesMinimumPWAReactionOrder() throws {
        let groups = [
            group("😀", reactors: [reactor(uid: 1, sortIndex: 10), reactor(uid: 2)]),
            group("😂", reactors: [reactor(uid: 1, sortIndex: 3), reactor(uid: 3)]),
            group("🥲", reactors: [reactor(uid: 4, sortIndex: 3)]),
        ]

        let allUsers = ReactionDetailsGrouping(groups: groups).categories[0].users

        XCTAssertEqual(allUsers.map(\.reactor.uid), [2, 3, 1, 4])
        XCTAssertEqual(allUsers.first { $0.reactor.uid == 1 }?.emojis, ["😀", "😂"])
    }

    func testEmptyGroupsDoNotCreateEmojiOrMoreCategories() {
        let populated = (1...8).map { group(String($0), count: 1) }
        let grouping = ReactionDetailsGrouping(
            groups: [group("empty", count: 0)] + populated + [group("also empty", count: 0)])

        XCTAssertEqual(
            grouping.categories.map(\.id),
            [.all] + (1...8).map { .emoji(String($0)) })
        XCTAssertEqual(grouping.categories[0].users.map(\.emojis), [(1...8).map(String.init)])
    }

    func testOnlyEmptyGroupsProduceEmptyState() {
        XCTAssertEqual(
            ReactionDetailsGrouping(groups: [group("empty", count: 0)]).categories.map(\.id),
            [])
    }

    private func group(_ emoji: String, count: Int) -> ReactionDetailGroup {
        group(emoji, reactors: (0..<count).map { reactor(uid: Int32($0 + 1)) })
    }

    private func group(_ emoji: String, reactors: [ReactionReactor]) -> ReactionDetailGroup {
        ReactionDetailGroup(emoji: emoji, reactors: reactors)
    }

    private func reactor(uid: Int32, sortIndex: Int32? = nil) -> ReactionReactor {
        let json: [String: Any] = [
            "uid": NSNumber(value: uid),
            "name": "User \(uid)",
            "avatarUrl": NSNull(),
            "sortIndex": sortIndex.map { NSNumber(value: $0) } ?? NSNull(),
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(ReactionReactor.self, from: data)
    }
}
