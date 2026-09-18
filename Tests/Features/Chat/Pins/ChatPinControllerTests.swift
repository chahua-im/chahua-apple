import ChahuaAPI
import Foundation
import XCTest

@testable import chahua_apple

@MainActor
final class ChatPinControllerTests: XCTestCase {
    func testLateEchoForOldPinCannotRemoveRepinnedMessage() throws {
        let controller = ChatPinController(apiClient: HeldPinAPI(), onInvalidToken: {})
        let old = try pin("message", second: 1)
        let replacement = PinResponse(
            id: "replacement", chatId: old.chatId, message: old.message, pinnedBy: 1, pinnedAt: Date())
        let removal = RealtimeServerEvent.pinRemoved(
            .init(chatId: old.chatId, pinId: old.id, messageId: old.message.id))
        controller.applyRealtimeEvent(addedEvent(old))
        controller.applyRealtimeEvent(removal)
        controller.applyRealtimeEvent(addedEvent(replacement))
        controller.applyRealtimeEvent(addedEvent(old))
        controller.applyRealtimeEvent(removal)
        XCTAssertEqual(controller.pinsByChatID["chat"]?.map(\.id), [replacement.id])
    }

    func testInflightListReplaysAddsRemovalsEditsAndBulkDeletion() async throws {
        let api = HeldPinAPI()
        let controller = ChatPinController(apiClient: api, onInvalidToken: {})
        let edited = try pin("edit", second: 1)
        let removed = try pin("remove", second: 2)
        let deleted = try pin("delete", second: 3)
        let added = try pin("add", second: 4)
        let load = Task { await controller.load(chatID: "chat") }
        await api.waitForRequests(1)
        controller.applyRealtimeEvent(.messageUpdated(edited.message.replacingMessageText("new preview")))
        controller.applyRealtimeEvent(.pinRemoved(.init(chatId: "chat", pinId: removed.id, messageId: removed.message.id)))
        controller.applyRealtimeEvent(.messagesBulkDeleted(.init(chatId: "chat", messageIds: [deleted.message.id])))
        controller.applyRealtimeEvent(addedEvent(added))
        await api.finishList(0, with: .success(.init(pins: [edited, removed, deleted])))
        await load.value

        XCTAssertEqual(controller.pinsByChatID["chat"]?.map(\.id), [added.id, edited.id])
        XCTAssertEqual(controller.pinsByChatID["chat"]?.last?.message.message, "new preview")
        controller.applyRealtimeEvent(addedEvent(removed))
        controller.applyRealtimeEvent(addedEvent(deleted))
        XCTAssertEqual(controller.pinsByChatID["chat"]?.map(\.id), [added.id, edited.id])
    }

    func testSuccessfulMutationsWinOverInflightListWithoutWebsocket() async throws {
        let api = HeldPinAPI()
        let controller = ChatPinController(apiClient: api, onInvalidToken: {})
        let old = try pin("old", second: 1)
        let new = try pin("new", second: 2)
        controller.applyRealtimeEvent(addedEvent(old))
        let load = Task { await controller.load(chatID: "chat") }
        await api.waitForRequests(1)
        let add = Task { await controller.pin(new.message) }
        await api.waitForRequests(2)
        await controller.pin(new.message)
        await api.finishCreate(1, with: .success(new))
        await add.value
        XCTAssertEqual(controller.pinsByChatID["chat"]?.map(\.id), [new.id, old.id])
        let remove = Task { await controller.unpin(old) }
        await api.waitForRequests(3)
        await api.finishDelete(2, with: .success(()))
        await remove.value
        await api.finishList(0, with: .success(.init(pins: [old])))
        await load.value
        XCTAssertEqual(controller.pinsByChatID["chat"]?.map(\.id), [new.id])
        XCTAssertTrue(controller.pendingMessageIDs.isEmpty)
    }

    func testCreateResponseCannotUndoConcurrentEditOrRemoval() async throws {
        let api = HeldPinAPI()
        let controller = ChatPinController(apiClient: api, onInvalidToken: {})
        let edited = try pin("edited", second: 1)
        let first = Task { await controller.pin(edited.message) }
        await api.waitForRequests(1)
        controller.applyRealtimeEvent(.messageUpdated(edited.message.replacingMessageText("changed")))
        await api.finishCreate(0, with: .success(edited))
        await first.value
        XCTAssertEqual(controller.pinsByChatID["chat"]?.first?.message.message, "changed")
        controller.applyRealtimeEvent(addedEvent(edited))
        XCTAssertEqual(controller.pinsByChatID["chat"]?.first?.message.message, "changed")

        let removed = try pin("removed", second: 2)
        let second = Task { await controller.pin(removed.message) }
        await api.waitForRequests(2)
        controller.applyRealtimeEvent(.pinRemoved(.init(chatId: "chat", pinId: removed.id, messageId: removed.message.id)))
        await api.finishCreate(1, with: .success(removed))
        await second.value
        XCTAssertEqual(controller.pinsByChatID["chat"]?.map(\.id), [edited.id])
    }

    func testResetFencesLateListsMutationsAndAuthenticationFailure() async throws {
        let api = HeldPinAPI()
        var invalidations = 0
        let controller = ChatPinController(apiClient: api) { invalidations += 1 }
        let old = try pin("old", second: 1)
        let staleLoad = Task { await controller.load(chatID: "chat") }
        await api.waitForRequests(1)
        let staleMutation = Task { await controller.pin(old.message) }
        await api.waitForRequests(2)
        controller.reset()
        let current = Task { await controller.pin(old.message) }
        await api.waitForRequests(3)
        await api.finishList(0, with: .success(.init(pins: [old])))
        await api.finishCreate(1, with: .failure(APIError.invalidToken))
        await staleLoad.value
        await staleMutation.value
        XCTAssertNil(controller.pinsByChatID["chat"])
        XCTAssertEqual(controller.pendingMessageIDs, [old.message.id])
        XCTAssertEqual(invalidations, 0)
        XCTAssertNil(controller.error)
        await api.finishCreate(2, with: .success(old))
        await current.value
        XCTAssertEqual(controller.pinsByChatID["chat"]?.map(\.id), [old.id])
    }

    func testPartialRealtimeListLoadsAndReconnectReplacesMissedEvents() async throws {
        let api = HeldPinAPI()
        let controller = ChatPinController(apiClient: api, onInvalidToken: {})
        let partial = try pin("partial", second: 1)
        let missing = try pin("missing", second: 2)
        controller.applyRealtimeEvent(addedEvent(partial))
        let load = Task { await controller.load(chatID: "chat") }
        await api.waitForRequests(1)
        await api.finishList(0, with: .success(.init(pins: [partial, missing, missing])))
        await load.value
        XCTAssertEqual(controller.pinsByChatID["chat"]?.map(\.id), [missing.id, partial.id])
        let reconnect = Task { await controller.reconcileAfterReconnect(activeChatIDs: []) }
        await api.waitForRequests(2)
        await api.finishList(1, with: .success(.init(pins: [missing])))
        await reconnect.value
        XCTAssertEqual(controller.pinsByChatID["chat"]?.map(\.id), [missing.id])
    }

    func testInvalidScopeFailsVisiblyAndRetryInstallsOnlyLivePins() async throws {
        let api = HeldPinAPI()
        let controller = ChatPinController(apiClient: api, onInvalidToken: {})
        let wrong = PinResponse(id: "wrong", chatId: "another", message: try TimelineTestFixtures.message(id: "wrong", at: 1), pinnedBy: 1, pinnedAt: Date())
        let load = Task { await controller.load(chatID: "chat") }
        await api.waitForRequests(1)
        await api.finishList(0, with: .success(.init(pins: [wrong])))
        await load.value
        XCTAssertTrue(controller.failedChatIDs.contains("chat"))
        XCTAssertNotNil(controller.error)
        XCTAssertNil(controller.pinsByChatID["chat"])

        let expired = try pin("expired", second: 3, expiresAt: .distantPast)
        let live = try pin("live", second: 1)
        let retry = Task { await controller.load(chatID: "chat") }
        await api.waitForRequests(2)
        await api.finishList(1, with: .success(.init(pins: [expired, live])))
        await retry.value
        XCTAssertEqual(controller.pinsByChatID["chat"]?.map(\.id), [live.id])
        XCTAssertTrue(controller.failedChatIDs.isEmpty)
        XCTAssertNil(controller.error)
    }

    private func pin(_ id: String, second: Int, expiresAt: Date? = nil) throws -> PinResponse {
        PinResponse(id: "pin-\(id)", chatId: "chat", message: try TimelineTestFixtures.message(id: id, at: second), pinnedBy: 1, pinnedAt: Date(), expiresAt: expiresAt)
    }

    private func addedEvent(_ pin: PinResponse) -> RealtimeServerEvent {
        .pinAdded(.init(chatId: pin.chatId, pinId: pin.id, messageId: pin.message.id, pin: pin))
    }
}

private actor HeldPinAPI: ChahuaAPIClient {
    private var requestCount = 0
    private var lists: [Int: CheckedContinuation<ListPinsResponse, Error>] = [:]
    private var creates: [Int: CheckedContinuation<PinResponse, Error>] = [:]
    private var deletes: [Int: CheckedContinuation<Void, Error>] = [:]
    private var waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    func waitForRequests(_ count: Int) async {
        guard requestCount < count else { return }
        await withCheckedContinuation { waiter = (count, $0) }
    }

    private func notifyWaiter() {
        guard let waiter, requestCount >= waiter.count else { return }
        self.waiter = nil
        waiter.continuation.resume()
    }

    func finishList(_ index: Int, with result: Result<ListPinsResponse, Error>) { lists.removeValue(forKey: index)?.resume(with: result) }
    func finishCreate(_ index: Int, with result: Result<PinResponse, Error>) { creates.removeValue(forKey: index)?.resume(with: result) }
    func finishDelete(_ index: Int, with result: Result<Void, Error>) { deletes.removeValue(forKey: index)?.resume(with: result) }

    // Ignore cancellation deliberately: reset must fence even a transport that returns late.
    func listPins(chatID: String) async throws -> ListPinsResponse {
        let index = requestCount
        requestCount += 1
        return try await withCheckedThrowingContinuation { lists[index] = $0; notifyWaiter() }
    }

    func createPin(chatID: String, messageID: String) async throws -> PinResponse {
        let index = requestCount
        requestCount += 1
        return try await withCheckedThrowingContinuation { creates[index] = $0; notifyWaiter() }
    }

    func deletePin(chatID: String, pinID: String) async throws {
        let index = requestCount
        requestCount += 1
        try await withCheckedThrowingContinuation { deletes[index] = $0; notifyWaiter() }
    }

    func authenticate(candidateJWT: String) async throws -> MeResponse { throw APIError.unavailable }
    func createDevSession(uid: Int32, clientID: String) async throws -> String { throw APIError.unavailable }
    func me() async throws -> MeResponse { throw APIError.unavailable }
    func attachmentConfig() async throws -> AttachmentConfigResponse { throw APIError.unavailable }
    func requestAttachmentUpload(fileName: String, contentType: String, size: Int64, width: Int, height: Int, order: Int) async throws -> OutgoingUploadAllocation { throw APIError.unavailable }
    func listOwnedStickerPacks() async throws -> [StickerPackSummary] { throw APIError.unavailable }
    func listSubscribedStickerPacks() async throws -> [StickerPackSummary] { throw APIError.unavailable }
    func listFavoriteStickers() async throws -> [MessageStickerResponse] { throw APIError.unavailable }
    func getSticker(id: String) async throws -> StickerDetailResponse { throw APIError.unavailable }
    func getStickerPack(id: String) async throws -> StickerPackDetailResponse { throw APIError.unavailable }
    func setStickerFavorite(id: String, favorite: Bool) async throws { throw APIError.unavailable }
    func setStickerPackSubscription(id: String, subscribed: Bool) async throws { throw APIError.unavailable }
    func listChats(query: ListChatsQuery) async throws -> ListChatsResponse { throw APIError.unavailable }
    func archiveChat(chatID: String) async throws { throw APIError.unavailable }
    func unarchiveChat(chatID: String) async throws { throw APIError.unavailable }
    func archiveThread(chatID: String, threadID: String) async throws { throw APIError.unavailable }
    func unarchiveThread(chatID: String, threadID: String) async throws { throw APIError.unavailable }
    func muteChat(chatID: String) async throws -> MuteResponse { throw APIError.unavailable }
    func unmuteChat(chatID: String) async throws { throw APIError.unavailable }
    func listThreads(query: ListThreadsQuery) async throws -> ListThreadsResponse { throw APIError.unavailable }
    func sendThreadMessage(chatID: String, threadID: String, body: CreateMessageBody) async throws -> MessageResponse { throw APIError.unavailable }
    func markChatRead(chatID: String, messageID: String) async throws -> ReadStateResponse { throw APIError.unavailable }
    func markChatUnread(chatID: String) async throws -> ReadStateResponse { throw APIError.unavailable }
    func markThreadRead(chatID: String, threadID: String, messageID: String) async throws -> ReadStateResponse { throw APIError.unavailable }
    func listMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse { throw APIError.unavailable }
    func sendMessage(chatID: String, body: CreateMessageBody) async throws -> MessageResponse { throw APIError.unavailable }
    func getMessage(chatID: String, messageID: String) async throws -> MessageResponse { throw APIError.unavailable }
    func deleteMessage(chatID: String, messageID: String) async throws { throw APIError.unavailable }
    func putReaction(chatID: String, messageID: String, emoji: String) async throws { throw APIError.unavailable }
    func deleteReaction(chatID: String, messageID: String, emoji: String) async throws { throw APIError.unavailable }
    func groupInfo(chatID: String) async throws -> GroupInfoResponse { throw APIError.unavailable }
    func listMembers(chatID: String, query: ListMembersQuery) async throws -> ListMembersResponse { throw APIError.unavailable }
    func friendRelationship(peerUID: Int32) async throws -> FriendRelationshipResponse { throw APIError.unavailable }
}
