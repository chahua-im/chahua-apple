import Foundation

public struct StickerPackPreviewSticker: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let media: MessageStickerMediaResponse
    public let emoji: String

    public init(id: String, media: MessageStickerMediaResponse, emoji: String) {
        self.id = id
        self.media = media
        self.emoji = emoji
    }
}

public struct StickerPackSummary: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let ownerUid: Int32
    public let ownerName: String?
    public let name: String
    public let description: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let stickerCount: Int
    public var isSubscribed: Bool
    public let previewSticker: StickerPackPreviewSticker?

    public init(
        id: String, ownerUid: Int32, ownerName: String? = nil, name: String,
        description: String? = nil, createdAt: Date, updatedAt: Date, stickerCount: Int,
        isSubscribed: Bool, previewSticker: StickerPackPreviewSticker? = nil
    ) {
        self.id = id
        self.ownerUid = ownerUid
        self.ownerName = ownerName
        self.name = name
        self.description = description
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.stickerCount = stickerCount
        self.isSubscribed = isSubscribed
        self.previewSticker = previewSticker
    }
}

/// The HTTP response is flat: pack fields and `stickers` share the root object.
public struct StickerPackDetailResponse: Codable, Hashable, Sendable {
    public let pack: StickerPackSummary
    public let stickers: [MessageStickerResponse]

    public init(pack: StickerPackSummary, stickers: [MessageStickerResponse]) {
        self.pack = pack
        self.stickers = stickers
    }

    private enum CodingKeys: String, CodingKey { case stickers }

    public init(from decoder: any Decoder) throws {
        pack = try StickerPackSummary(from: decoder)
        stickers = try decoder.container(keyedBy: CodingKeys.self).decode([MessageStickerResponse].self, forKey: .stickers)
    }

    public func encode(to encoder: any Encoder) throws {
        try pack.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stickers, forKey: .stickers)
    }
}

/// The HTTP response is flat: sticker fields and `packs` share the root object.
public struct StickerDetailResponse: Codable, Hashable, Sendable {
    public let sticker: MessageStickerResponse
    public let packs: [StickerPackSummary]

    public init(sticker: MessageStickerResponse, packs: [StickerPackSummary]) {
        self.sticker = sticker
        self.packs = packs
    }

    private enum CodingKeys: String, CodingKey { case packs }

    public init(from decoder: any Decoder) throws {
        sticker = try MessageStickerResponse(from: decoder)
        packs = try decoder.container(keyedBy: CodingKeys.self).decode([StickerPackSummary].self, forKey: .packs)
    }

    public func encode(to encoder: any Encoder) throws {
        try sticker.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(packs, forKey: .packs)
    }
}
