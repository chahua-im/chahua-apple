import ChahuaAPI
import Foundation
import XCTest

@testable import chahua_apple

@MainActor
final class StickerMessageActionsTests: XCTestCase {
    func testFavoriteUsesConfirmedSharedStateAndRejectsDuplicateMutation() async {
        let api = FakeChatAPI()
        let sticker = sticker()
        await api.setStickerLibrary(owned: [], favorites: [sticker])
        let library = StickerLibrary(apiClient: api, onInvalidToken: {})
        library.setAccount(1)
        await library.refresh()
        XCTAssertTrue(library.isFavorite(sticker))

        let removal = Task { await library.toggleFavorite(sticker) }
        await api.waitForFavoriteStickerRequests(1)
        XCTAssertTrue(library.isFavorite(sticker), "Do not change confirmed state optimistically")
        let duplicate = await library.toggleFavorite(sticker)
        XCTAssertFalse(duplicate)
        await api.finishFavoriteSticker(0, with: .failure(APIError.unavailable))
        let failed = await removal.value
        XCTAssertFalse(failed)
        XCTAssertTrue(library.isFavorite(sticker))
        XCTAssertEqual(library.favorites.map(\.id), [sticker.id])
        XCTAssertNotNil(library.error)

        let retry = Task { await library.toggleFavorite(sticker) }
        await api.waitForFavoriteStickerRequests(2)
        await api.finishFavoriteSticker(1, with: .success(()))
        let removed = await retry.value
        XCTAssertTrue(removed)
        XCTAssertFalse(library.isFavorite(sticker))
        XCTAssertTrue(library.favorites.isEmpty)
        XCTAssertNil(library.error)
        let requests = await api.recordedFavoriteStickerRequests()
        XCTAssertEqual(requests.map(\.favorite), [false, false])
    }

    func testAccountReplacementDoesNotApplyOldFavoriteMutation() async {
        let api = FakeChatAPI()
        let library = StickerLibrary(apiClient: api, onInvalidToken: {})
        library.setAccount(1)
        let mutation = Task { await library.toggleFavorite(sticker()) }
        await api.waitForFavoriteStickerRequests(1)
        library.setAccount(2)
        await api.finishFavoriteSticker(0, with: .success(()))
        let saved = await mutation.value
        XCTAssertFalse(saved)
        XCTAssertTrue(library.favorites.isEmpty)
        XCTAssertTrue(library.pendingMutationIDs.isEmpty)
        XCTAssertNil(library.error)
    }

    func testConversionRequiresOwnedPackAndSavesOnlyOnceAfterConfirmation() async throws {
        let api = FakeChatAPI()
        let owned = pack("owned", owner: 1)
        let subscribed = pack("subscribed", owner: 2)
        await api.setStickerLibrary(owned: [owned], subscribed: [subscribed])
        let library = StickerLibrary(apiClient: api, onInvalidToken: {})
        library.setAccount(1)
        await library.refresh()
        let source = try source()
        let denied = await library.addMessageSticker(
            source, toPack: "subscribed", emoji: "😊", name: nil)
        XCTAssertNil(denied)
        let pending = Task {
            await library.addMessageSticker(source, toPack: "owned", emoji: "😊", name: "  Smile  ")
        }
        await api.waitForMessageStickerRequests(1)
        let duplicate = await library.addMessageSticker(
            source, toPack: "owned", emoji: "😊", name: nil)
        XCTAssertNil(duplicate)
        XCTAssertTrue(library.packDetails["owned"]?.stickers.isEmpty ?? true)
        await api.finishMessageSticker(0, with: .success(sticker()))
        let added = await pending.value
        XCTAssertEqual(added?.id, "sticker")
        XCTAssertEqual(library.packDetails["owned"]?.stickers.map(\.id), ["sticker"])
        let again = await library.addMessageSticker(source, toPack: "owned", emoji: "😊", name: nil)
        XCTAssertEqual(again?.id, "sticker")
        let requests = await api.recordedMessageStickerRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.chatID, source.chatId)
        XCTAssertEqual(requests.first?.messageID, source.id)
        XCTAssertEqual(requests.first?.name, "Smile")
        XCTAssertEqual(requests.first?.emoji, "😊")
        XCTAssertTrue(library.pendingMutationIDs.isEmpty)
    }

    func testNewlyCreatedPackIsImmediatelyOwnedAndAcceptsMessageSticker() async throws {
        let api = FakeChatAPI()
        await api.setStickerLibrary(owned: [])
        await api.setCreatedStickerPack(pack("new", owner: 1))
        let library = StickerLibrary(apiClient: api, onInvalidToken: {})
        library.setAccount(1)
        await library.refresh()
        let created = await library.createPack(name: "New Pack")
        XCTAssertEqual(created?.id, "new")
        XCTAssertTrue(library.isOwnedPack("new"))
        let source = try source()
        let saving = Task {
            await library.addMessageSticker(source, toPack: "new", emoji: "😊", name: nil)
        }
        await api.waitForMessageStickerRequests(1)
        await api.finishMessageSticker(0, with: .success(sticker()))
        let result = await saving.value
        XCTAssertEqual(result?.id, "sticker")
        XCTAssertEqual(library.packDetails["new"]?.stickers.map(\.id), ["sticker"])
    }

    func testUncertainConversionDoesNotBlindlyRetryButDefiniteRejectionCanRetry() async throws {
        let api = FakeChatAPI()
        await api.setStickerLibrary(owned: [pack("owned", owner: 1)])
        let library = StickerLibrary(apiClient: api, onInvalidToken: {})
        library.setAccount(1)
        await library.refresh()
        let source = try source()
        let rejected = Task {
            await library.addMessageSticker(source, toPack: "owned", emoji: "😊", name: nil)
        }
        await api.waitForMessageStickerRequests(1)
        await api.finishMessageSticker(0, with: .failure(APIError.http(status: 409, body: Data())))
        let rejection = await rejected.value
        XCTAssertNil(rejection)
        XCTAssertFalse(library.hasUncertainMessageStickerSave(source, packID: "owned"))

        let lostResponse = Task {
            await library.addMessageSticker(source, toPack: "owned", emoji: "😊", name: nil)
        }
        await api.waitForMessageStickerRequests(2)
        await api.finishMessageSticker(1, with: .failure(APIError.transport(URLError(.timedOut))))
        let uncertain = await lostResponse.value
        XCTAssertNil(uncertain)
        XCTAssertTrue(library.hasUncertainMessageStickerSave(source, packID: "owned"))
        let retry = await library.addMessageSticker(source, toPack: "owned", emoji: "😊", name: nil)
        XCTAssertNil(retry)
        let requests = await api.recordedMessageStickerRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotNil(library.error)
        library.setAccount(2)
        XCTAssertFalse(library.hasUncertainMessageStickerSave(source, packID: "owned"))
    }

    func testCancellationOfUncertainWriteBlocksDuplicateSaveWithoutPublishingError() async throws {
        let api = FakeChatAPI()
        await api.setStickerLibrary(owned: [pack("owned", owner: 1)])
        let library = StickerLibrary(apiClient: api, onInvalidToken: {})
        library.setAccount(1)
        await library.refresh()
        let source = try source()
        let pending = Task {
            await library.addMessageSticker(source, toPack: "owned", emoji: "😊", name: nil)
        }
        await api.waitForMessageStickerRequests(1)
        pending.cancel()
        await api.finishMessageSticker(0, with: .failure(CancellationError()))
        let result = await pending.value
        XCTAssertNil(result)
        XCTAssertTrue(library.hasUncertainMessageStickerSave(source, packID: "owned"))
        XCTAssertTrue(library.pendingMutationIDs.isEmpty)
        XCTAssertNil(library.error)
    }

    func testSingleImageEligibilityMirrorsServerSizeAndCaptionRules() throws {
        let source = try source()
        XCTAssertTrue(source.canAddToStickerPack)
        XCTAssertFalse(source.replacingMessageText("caption").canAddToStickerPack)
        XCTAssertFalse(source.redactedForDeletion().canAddToStickerPack)
        XCTAssertFalse(
            source.replacingAttachments(source.attachments + source.attachments).canAddToStickerPack
        )
        let image = source.attachments[0]
        let tooLarge = AttachmentResponse(
            id: image.id, url: image.url, kind: image.kind, size: 10 * 1_024 * 1_024 + 1,
            fileName: image.fileName)
        XCTAssertFalse(source.replacingAttachments([tooLarge]).canAddToStickerPack)
        let video = AttachmentResponse(
            id: image.id, url: image.url, kind: "video/webm", size: 1, fileName: "video.webm")
        XCTAssertFalse(source.replacingAttachments([video]).canAddToStickerPack)
        let fileMessage = try TimelineTestFixtures.message(id: 5, at: 0, type: .file, text: " ")
            .replacingAttachments(source.attachments)
        XCTAssertFalse(fileMessage.canAddToStickerPack)
    }

    private func source() throws -> MessageResponse {
        try TimelineTestFixtures.message(id: 5, at: 0, text: "")
            .replacingMessageText(" \n\t ")
            .replacingAttachments([
                AttachmentResponse(
                    id: "image", url: "https://cdn.example/image.png", kind: "image/png",
                    size: 10 * 1_024 * 1_024, fileName: "image.png")
            ])
    }

    private func sticker() -> MessageStickerResponse {
        MessageStickerResponse(
            id: "sticker", emoji: "😊", createdAt: Date(timeIntervalSince1970: 0),
            isFavorited: false,
            media: .init(
                id: "media", url: "https://cdn.example/sticker.webp", contentType: "image/webp",
                size: 1))
    }

    private func pack(_ id: String, owner: Int32) -> StickerPackSummary {
        StickerPackSummary(
            id: id, ownerUid: owner, name: id, createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0), stickerCount: 0, isSubscribed: true)
    }
}
