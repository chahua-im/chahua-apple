import Foundation

private struct StickerPackListResponse: Decodable {
    let packs: [StickerPackSummary]
}

private struct FavoriteStickerListResponse: Decodable {
    let stickers: [MessageStickerResponse]
}

extension ChahuaClient {
    public func listOwnedStickerPacks() async throws -> [StickerPackSummary] {
        try await send(
            HTTPRequestSpec(method: .get, path: ["stickers", "packs", "mine", "owned"]),
            decoding: StickerPackListResponse.self
        ).packs
    }

    public func listSubscribedStickerPacks() async throws -> [StickerPackSummary] {
        try await send(
            HTTPRequestSpec(method: .get, path: ["stickers", "packs", "mine", "subscribed"]),
            decoding: StickerPackListResponse.self
        ).packs
    }

    public func listFavoriteStickers() async throws -> [MessageStickerResponse] {
        try await send(
            HTTPRequestSpec(method: .get, path: ["stickers", "mine", "favorites"]),
            decoding: FavoriteStickerListResponse.self
        ).stickers
    }

    public func getSticker(id: String) async throws -> StickerDetailResponse {
        try await send(
            HTTPRequestSpec(method: .get, path: ["stickers", id]),
            decoding: StickerDetailResponse.self
        )
    }

    public func getStickerPack(id: String) async throws -> StickerPackDetailResponse {
        try await send(
            HTTPRequestSpec(method: .get, path: ["stickers", "packs", id]),
            decoding: StickerPackDetailResponse.self
        )
    }

    public func setStickerFavorite(id: String, favorite: Bool) async throws {
        try await send(
            HTTPRequestSpec(method: favorite ? .put : .delete, path: ["stickers", id, "favorite"]))
    }

    public func setStickerPackSubscription(id: String, subscribed: Bool) async throws {
        try await send(
            HTTPRequestSpec(
                method: subscribed ? .put : .delete,
                path: ["stickers", "packs", id, "subscription"]))
    }
}
