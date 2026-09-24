import Foundation

private struct StickerPackListResponse: Decodable {
    let packs: [StickerPackSummary]
}

private struct FavoriteStickerListResponse: Decodable {
    let stickers: [MessageStickerResponse]
}

private struct CreateStickerPackBody: Encodable {
    let name: String
    let description: String?
}

private struct UpdateStickerPackBody: Encodable {
    let name: String?
    let description: String?
}

private struct StickerPackOrderBody: Encodable {
    let order: [StickerPackOrderUpdate]
}

private struct StickerMultipartBody {
    let boundary = "ChahuaSticker-\(UUID().uuidString)"
    let upload: StickerUpload
    let emoji: String
    let name: String?
    let description: String?

    func encoded() throws -> Data {
        guard
            upload.fileURL.isFileURL,
            !upload.contentType.contains(where: { $0 == "\r" || $0 == "\n" })
        else {
            throw APIError.encoding(description: "Invalid sticker upload metadata.")
        }

        let file: Data
        do {
            file = try Data(contentsOf: upload.fileURL, options: .mappedIfSafe)
        } catch {
            throw APIError.encoding(description: "Unable to read sticker file.")
        }

        var body = Data()
        body.reserveCapacity(file.count + 512)
        appendField(named: "emoji", value: emoji, to: &body)
        if let name = trimmed(name) {
            appendField(named: "name", value: name, to: &body)
        }
        if let description = trimmed(description) {
            appendField(named: "description", value: description, to: &body)
        }
        appendFile(file, to: &body)
        body.append(contentsOf: "--\(boundary)--\r\n".utf8)
        return body
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func appendField(named name: String, value: String, to body: inout Data) {
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(contentsOf: "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8)
        body.append(contentsOf: value.utf8)
        body.append(contentsOf: "\r\n".utf8)
    }

    private func appendFile(_ file: Data, to body: inout Data) {
        let fileName = upload.fileName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        body.append(contentsOf: "--\(boundary)\r\n".utf8)
        body.append(
            contentsOf:
                "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".utf8)
        body.append(contentsOf: "Content-Type: \(upload.contentType)\r\n\r\n".utf8)
        body.append(file)
        body.append(contentsOf: "\r\n".utf8)
    }
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
    public func createStickerPack(name: String, description: String?) async throws
        -> StickerPackSummary
    {
        try await send(
            HTTPRequestSpec.json(
                .post, ["stickers", "packs"],
                body: CreateStickerPackBody(name: name, description: description)),
            decoding: StickerPackSummary.self
        )
    }

    public func updateStickerPack(id: String, name: String?, description: String?) async throws
        -> StickerPackSummary
    {
        try await send(
            HTTPRequestSpec.json(
                .patch, ["stickers", "packs", id],
                body: UpdateStickerPackBody(name: name, description: description)),
            decoding: StickerPackSummary.self
        )
    }

    public func deleteStickerPack(id: String) async throws {
        try await send(HTTPRequestSpec(method: .delete, path: ["stickers", "packs", id]))
    }

    public func uploadStickerToPack(
        id: String, upload: StickerUpload, emoji: String, name: String?, description: String?
    ) async throws -> MessageStickerResponse {
        let multipart = StickerMultipartBody(
            upload: upload, emoji: emoji, name: name, description: description)
        return try await send(
            HTTPRequestSpec(
                method: .post, path: ["stickers", "packs", id, "stickers"],
                body: try multipart.encoded(),
                contentType: "multipart/form-data; boundary=\(multipart.boundary)"
            ),
            decoding: MessageStickerResponse.self
        )
    }

    public func removeStickerFromPack(id: String, stickerID: String) async throws {
        try await send(
            HTTPRequestSpec(
                method: .delete, path: ["stickers", "packs", id, "stickers", stickerID]))
    }

    public func updateStickerPackOrder(_ order: [StickerPackOrderUpdate]) async throws {
        try await send(
            HTTPRequestSpec.json(
                .put, ["users", "me", "stickerpack-order"],
                body: StickerPackOrderBody(order: order)))
    }
}
