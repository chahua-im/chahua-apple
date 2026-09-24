import Foundation

/// Matches the PWA defaults: editable pinned reactions, followed by recent choices.
enum MessageReactionPreferences {
    static let recentStorageKey = "chat.reactions.recent"
    static let defaultRecentStorage = "❤️|😂|😮|😢|🎉"
    static let pinnedRevisionStorageKey = "chat.reactions.pinned-revision"
    static let maximumRecent = 30
    private static let activeAccountStorageKey = "chat.stickers.active-account"

    static var pinned: [String] {
        guard
            let rawAccountID = UserDefaults.standard.string(forKey: activeAccountStorageKey),
            let accountID = Int32(rawAccountID)
        else { return StickerPreferences.defaultPinnedReactions }
        return StickerPreferences.load(for: accountID).pinnedReactions
    }

    static func setActiveAccount(_ accountID: Int32?) {
        if let accountID {
            UserDefaults.standard.set(String(accountID), forKey: activeAccountStorageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeAccountStorageKey)
        }
    }

    static func pinnedReactionsDidChange() {
        UserDefaults.standard.set(
            UserDefaults.standard.integer(forKey: pinnedRevisionStorageKey) + 1,
            forKey: pinnedRevisionStorageKey)
    }

    static func recent(from storage: String) -> [String] {
        var seen: Set<String> = []
        return storage.split(separator: "|").map(String.init).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }.prefix(maximumRecent).map { $0 }
    }

    static func quick(from storage: String) -> [String] {
        let pinned = pinned
        return Array((pinned + recent(from: storage).filter { !pinned.contains($0) }).prefix(5))
    }

    static func recording(_ emoji: String, in storage: String) -> String {
        let pinned = pinned
        guard !pinned.contains(emoji) else { return storage }
        return ([emoji] + recent(from: storage).filter { $0 != emoji })
            .prefix(maximumRecent).joined(separator: "|")
    }
}
