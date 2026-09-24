import Foundation

/// Account-scoped local preferences shared by the sticker picker and reaction controls.
struct StickerPreferences: Codable, Equatable {
    static let defaultPinnedReactions = ["👍"]
    static let maximumPinnedReactions = 5
    static let maximumStickerEmojiCount = 4
    static let automaticSortLimit = 20

    var pinnedReactions: [String] = Self.defaultPinnedReactions
    var autoSortPacks = false
    var autoSortFavorites = false
    var favoriteOrder: [String: Int64] = [:]

    static func load(for accountID: Int32) -> Self {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey(for: accountID)),
            let decoded = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return Self(
            pinnedReactions: normalizedPinnedReactions(decoded.pinnedReactions.joined()),
            autoSortPacks: decoded.autoSortPacks,
            autoSortFavorites: decoded.autoSortFavorites,
            favoriteOrder: decoded.favoriteOrder
        )
    }

    func save(for accountID: Int32) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey(for: accountID))
    }

    static func normalizedEmojiSequences(_ value: String, maximum: Int) -> [String] {
        value.compactMap { character in
            let scalars = character.unicodeScalars
            let isEmoji =
                scalars.contains { $0.properties.isEmojiPresentation }
                || scalars.contains { $0.value == 0xFE0F || $0.value == 0x20E3 }
            return isEmoji ? String(character) : nil
        }
        .prefix(maximum)
        .map(\.self)
    }

    static func normalizedPinnedReactions(_ value: String) -> [String] {
        var seen = Set<String>()
        return normalizedEmojiSequences(value, maximum: value.count).filter {
            seen.insert($0).inserted
        }.prefix(maximumPinnedReactions).map(\.self)
    }

    private static func storageKey(for accountID: Int32) -> String {
        "chat.stickers.preferences.\(accountID)"
    }
}
