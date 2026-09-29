import ChahuaAPI
import Foundation

/// Mirrors the PWA reaction-details category selection and ordering rules.
struct ReactionDetailsGrouping {
    static let maximumEmojiCategories = 8

    let categories: [ReactionDetailsCategory]

    init(groups: [ReactionDetailGroup]) {
        // Empty server groups must not create tabs or an empty More category.
        let rankedGroups = groups.enumerated().lazy.filter { !$0.element.reactors.isEmpty }.sorted {
            lhs, rhs in
            if lhs.element.reactors.count != rhs.element.reactors.count {
                return lhs.element.reactors.count > rhs.element.reactors.count
            }
            return lhs.offset < rhs.offset
        }
        guard !rankedGroups.isEmpty else {
            categories = []
            return
        }

        let topGroups =
            rankedGroups
            .prefix(Self.maximumEmojiCategories)
            .sorted { lhs, rhs in
                if lhs.element.reactors.count != rhs.element.reactors.count {
                    return lhs.element.reactors.count > rhs.element.reactors.count
                }
                if lhs.element.emoji != rhs.element.emoji {
                    return lhs.element.emoji.utf16.lexicographicallyPrecedes(
                        rhs.element.emoji.utf16)
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        let moreGroups = rankedGroups.dropFirst(Self.maximumEmojiCategories).map(\.element)

        var allUsersByID: [Int32: AggregatedReactor] = [:]
        var fallbackReactionIndex: Int32 = 0
        var encounterOrder = 0

        for group in groups {
            for reactor in group.reactors {
                let reactionIndex: Int32
                if let sortIndex = reactor.sortIndex {
                    reactionIndex = sortIndex
                } else {
                    reactionIndex = fallbackReactionIndex
                    fallbackReactionIndex += 1
                }

                if var existing = allUsersByID[reactor.uid] {
                    existing.emojis.append(group.emoji)
                    existing.firstReactionIndex = min(existing.firstReactionIndex, reactionIndex)
                    allUsersByID[reactor.uid] = existing
                } else {
                    allUsersByID[reactor.uid] = AggregatedReactor(
                        reactor: reactor,
                        emojis: [group.emoji],
                        firstReactionIndex: reactionIndex,
                        encounterOrder: encounterOrder
                    )
                }
                encounterOrder += 1
            }
        }

        let allUsers = allUsersByID.values
            .sorted { lhs, rhs in
                if lhs.firstReactionIndex != rhs.firstReactionIndex {
                    return lhs.firstReactionIndex < rhs.firstReactionIndex
                }
                return lhs.encounterOrder < rhs.encounterOrder
            }
            .map(\.groupedReactor)

        var categories = [
            ReactionDetailsCategory(
                id: .all,
                count: allUsers.count,
                users: allUsers
            )
        ]

        for group in topGroups {
            categories.append(
                ReactionDetailsCategory(
                    id: .emoji(group.emoji),
                    count: group.reactors.count,
                    users: group.reactors.map {
                        ReactionDetailsGroupedReactor(reactor: $0, emojis: [group.emoji])
                    }
                )
            )
        }

        if !moreGroups.isEmpty {
            let moreUsers = moreGroups.flatMap { group in
                group.reactors.map {
                    ReactionDetailsGroupedReactor(reactor: $0, emojis: [group.emoji])
                }
            }
            categories.append(
                ReactionDetailsCategory(id: .more, count: moreUsers.count, users: moreUsers)
            )
        }

        self.categories = categories
    }
}

struct ReactionDetailsCategory: Identifiable {
    enum ID: Hashable {
        case all
        case emoji(String)
        case more
    }

    let id: ID
    let count: Int
    let users: [ReactionDetailsGroupedReactor]

    var showsEmojis: Bool {
        switch id {
        case .all, .more:
            true
        case .emoji:
            false
        }
    }
}

struct ReactionDetailsGroupedReactor {
    let reactor: ReactionReactor
    let emojis: [String]
}

private struct AggregatedReactor {
    let reactor: ReactionReactor
    var emojis: [String]
    var firstReactionIndex: Int32
    let encounterOrder: Int

    var groupedReactor: ReactionDetailsGroupedReactor {
        ReactionDetailsGroupedReactor(reactor: reactor, emojis: emojis)
    }
}
