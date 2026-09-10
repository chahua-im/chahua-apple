import Foundation

/// Matches the PWA defaults: one pinned thumb, followed by recent choices.
/// Pinned preference editing is intentionally not exposed by the message menu.
enum MessageReactionPreferences {
    static let recentStorageKey = "chat.reactions.recent"
    static let defaultRecentStorage = "❤️|😂|😮|😢|🎉"
    static let pinned = ["👍"]
    static let maximumRecent = 30

    static func recent(from storage: String) -> [String] {
        var seen: Set<String> = []
        return storage.split(separator: "|").map(String.init).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }.prefix(maximumRecent).map { $0 }
    }

    static func quick(from storage: String) -> [String] {
        Array((pinned + recent(from: storage).filter { !pinned.contains($0) }).prefix(5))
    }

    static func recording(_ emoji: String, in storage: String) -> String {
        guard !pinned.contains(emoji) else { return storage }
        return ([emoji] + recent(from: storage).filter { $0 != emoji })
            .prefix(maximumRecent).joined(separator: "|")
    }
}
