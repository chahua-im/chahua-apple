import ChahuaAPI
import Combine
import Foundation
import UniformTypeIdentifiers
import XCTest

@testable import chahua_apple

// The test target compiles the extension model and its shared helpers directly,
// without linking the app extension or using the user's Keychain session.

@MainActor
final class ShareExtensionModelTests: XCTestCase {
    func testRestrictedProfileDoesNotAffectDirectMessagesOrReadProfile() async throws {
        let provider = NSItemProvider(object: "Direct message" as NSString)
        let (model, api) = await loadShare(provider: provider)
        defer { model.cancel() }
        await api.setAuthenticatedProfile(try shareProfile(restricted: true))
        await api.setConversationPageMetadata(
            group: .init(
                id: "recipient", myRole: .member, kind: .dm,
                peer: .init(uid: 18, username: "Peer", gender: 0)))
        let relationship = try JSONDecoder().decode(
            FriendRelationshipResponse.self,
            from: Data(#"{"peerUid":18,"canDm":true}"#.utf8))
        await api.setShareFriendRelationship(relationship)
        model.selectDestination(try XCTUnwrap(model.destinations.first))
        try await waitFor(model.$isCheckingPermission) { !$0 }
        XCTAssertTrue(model.canSend)
        model.send()
        try await waitFor(model.$state) { $0 == .ready }
        let sends = await api.sentMessageRequests
        let profileReads = await api.meRequestCount
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(profileReads, 0)
        XCTAssertTrue(model.canSend, "An ordinary transport failure remains retryable.")
    }

    func testRestrictedProfileBlocksGroupThreadForMembersAndAdministrators() async throws {
        let profile = try shareProfile(restricted: true)
        let root = MessagePreview(
            id: MessageID(1), clientGeneratedId: "root", createdAt: .distantPast,
            sender: profile.asSender, messageType: .text, message: "Topic")
        let thread = ThreadListItem(
            chatId: "recipient", chatName: "Recipient", threadRootMessage: root,
            replyCount: 0, lastReplyAt: .distantPast, unreadCount: 0, chatKind: .group,
            subscribedAt: .distantPast, archived: false)
        for role in [GroupRole.member, .admin] {
            let api = FakeChatAPI(
                chatResults: [.success(.init(chats: []))],
                threadResults: [.success(.init(threads: [thread]))])
            await api.setAuthenticatedProfile(profile)
            await api.setConversationPageMetadata(
                group: .init(
                    id: "recipient", myRole: role, kind: .group,
                    effectiveSpeakingMode: .unrestricted))
            let item = NSExtensionItem()
            item.attachments = [NSItemProvider(object: "Thread reply" as NSString)]
            let model = ShareExtensionModel(
                extensionItems: [item], makeSession: { ("isolated-session", api) })
            await model.load()
            model.selectDestination(try XCTUnwrap(model.destinations.first))
            try await waitFor(model.$isCheckingPermission) { !$0 }
            XCTAssertFalse(model.canSend)
            XCTAssertNotNil(model.destinationPermissionMessage)
            model.send()
            let sends = await api.sentMessageRequests
            XCTAssertTrue(sends.isEmpty)
            XCTAssertEqual(model.caption, "Thread reply")
            model.cancel()
        }
    }

    func testRestrictedAdministratorCannotSendAndExplicitRefreshRestoresPermission() async throws {
        let provider = NSItemProvider(object: "Keep this shared content" as NSString)
        let (model, api) = await loadShare(provider: provider)
        defer { model.cancel() }
        await api.setAuthenticatedProfile(try shareProfile(restricted: true))
        let destination = try XCTUnwrap(model.destinations.first)
        let caption = model.caption
        model.selectDestination(destination)
        try await waitFor(model.$isCheckingPermission) { !$0 }
        XCTAssertFalse(model.canSend)
        XCTAssertNotNil(model.destinationPermissionMessage)
        model.send()
        model.retrySend()
        let sends = await api.sentMessageRequests
        let configurations = await api.attachmentConfigRequests
        XCTAssertTrue(sends.isEmpty)
        XCTAssertEqual(configurations, 0)
        XCTAssertEqual(model.caption, caption)

        await api.setAuthenticatedProfile(try shareProfile(restricted: false))
        model.retryPermission()
        try await waitFor(model.$isCheckingPermission) { !$0 }
        XCTAssertTrue(model.canSend)
        XCTAssertNil(model.destinationPermissionMessage)
    }

    func testSendPreflightCatchesRestrictionChangedAfterSelection() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-restricted-\(UUID().uuidString).png")
        try makeMediaPNG(red: 255, green: 0, blue: 0).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all
        ) { completion in
            completion(file, false, nil)
            return nil
        }
        let (model, api) = await loadShare(provider: provider)
        defer { model.cancel() }
        model.selectDestination(try XCTUnwrap(model.destinations.first))
        try await waitFor(model.$isCheckingPermission) { !$0 }
        XCTAssertTrue(model.canSend)
        await api.setAuthenticatedProfile(try shareProfile(restricted: true))
        let caption = model.caption
        XCTAssertEqual(model.media.count, 1)
        let mediaIDs = model.media.map(\.id)
        model.send()
        try await waitFor(model.$state) { $0 == .ready }
        XCTAssertFalse(model.canSend)
        let sends = await api.sentMessageRequests
        let configurations = await api.attachmentConfigRequests
        XCTAssertTrue(sends.isEmpty)
        XCTAssertEqual(configurations, 0)
        XCTAssertEqual(model.caption, caption)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.media.map(\.id), mediaIDs)
        XCTAssertTrue(mediaIDs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testServerRestrictionRetainsFrozenRequestAndRequiresPermissionRefresh() async throws {
        let provider = NSItemProvider(object: "Keep this shared content" as NSString)
        let (model, api) = await loadShare(provider: provider)
        defer { model.cancel() }
        await api.setSendMessageFailure(
            .http(status: 403, body: Data(#"{"reason":"groupChatWriteRestricted"}"#.utf8)))
        model.selectDestination(try XCTUnwrap(model.destinations.first))
        try await waitFor(model.$isCheckingPermission) { !$0 }
        let caption = model.caption
        model.send()
        try await waitFor(model.$state) { $0 == .ready }
        XCTAssertFalse(model.canSend)
        XCTAssertFalse(model.canChangeDestination)
        XCTAssertEqual(model.caption, caption)
        XCTAssertNotNil(model.destinationPermissionMessage)
        model.retrySend()
        let first = await api.sentMessageRequests
        XCTAssertEqual(first.count, 1)

        model.retryPermission()
        try await waitFor(model.$isCheckingPermission) { !$0 }
        XCTAssertTrue(model.canSend, "Explicit refresh must work even with a frozen request.")
        model.retrySend()
        try await waitFor(model.$state) { $0 == .ready }
        let retried = await api.sentMessageRequests
        XCTAssertEqual(retried.count, 2)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(
            try encoder.encode(XCTUnwrap(first.first).body),
            try encoder.encode(XCTUnwrap(retried.last).body))
    }

    func testDestinationRetryAfterSendFailureDoesNotResendAndPreservesFrozenRequest() async throws {
        let provider = NSItemProvider(object: "https://example.com/shared" as NSString)
        let (model, api) = await loadShare(provider: provider)
        defer { model.cancel() }
        let destination = try XCTUnwrap(model.destinations.first)
        XCTAssertNotNil(model.destinationErrorMessage)
        model.caption += " Caption edit"
        model.selectDestination(destination)
        try await waitFor(model.$isCheckingPermission) { !$0 }
        XCTAssertTrue(model.canSend)

        model.send()
        try await waitFor(model.$state) { $0 == .ready }
        let sendError = try XCTUnwrap(model.errorMessage)
        let firstRequests = await api.sentMessageRequests
        XCTAssertEqual(firstRequests.count, 1)
        XCTAssertFalse(model.canChangeDestination)
        let caption = model.caption

        model.retryDestinations()
        try await waitFor(model.$isLoadingDestinations) { !$0 }

        let requestsAfterReload = await api.sentMessageRequests
        let uploadRequests = await api.attachmentUploadRequests
        let configRequests = await api.attachmentConfigRequests
        let chatQueries = await api.recordedChatQueries()
        let threadQueries = await api.recordedThreadQueries()
        XCTAssertEqual(chatQueries.count, 2)
        XCTAssertEqual(threadQueries.count, 2)
        XCTAssertEqual(requestsAfterReload.count, 1, "Reloading recipients must never resend.")
        XCTAssertEqual(uploadRequests, 0)
        XCTAssertEqual(configRequests, 0)
        XCTAssertEqual(
            model.destinations.map(\.id), [destination.id], "Reload must not duplicate rows.")
        XCTAssertEqual(model.selectedDestination, destination)
        XCTAssertEqual(model.caption, caption)
        XCTAssertEqual(model.errorMessage, sendError)
        XCTAssertNil(model.destinationErrorMessage)
        XCTAssertTrue(model.canSend)
        XCTAssertFalse(model.canChangeDestination)

        model.retrySend()
        try await waitFor(model.$state) { $0 == .ready }
        let retriedRequests = await api.sentMessageRequests
        XCTAssertEqual(retriedRequests.count, 2)
        let first = try XCTUnwrap(firstRequests.first)
        let retried = try XCTUnwrap(retriedRequests.last)
        XCTAssertEqual(retried.chatID, first.chatID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(retried.body), try encoder.encode(first.body))
    }

    func testDestinationRetryAfterMediaFailureDoesNotRestartUploadPreparation() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-retry-\(UUID().uuidString).png")
        try makeMediaPNG(red: 255, green: 0, blue: 0).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all
        ) { completion in
            completion(file, false, nil)
            return nil
        }
        let (model, api) = await loadShare(provider: provider)
        defer { model.cancel() }
        XCTAssertNotNil(model.destinationErrorMessage)
        XCTAssertEqual(model.media.count, 1)
        let mediaIDs = model.media.map(\.id)
        let destination = try XCTUnwrap(model.destinations.first)
        model.caption = "Keep this caption"
        model.selectDestination(destination)
        try await waitFor(model.$isCheckingPermission) { !$0 }
        XCTAssertTrue(model.canSend)

        model.send()
        try await waitFor(model.$state) { $0 == .ready }
        let sendError = try XCTUnwrap(model.errorMessage)
        let initialConfigRequests = await api.attachmentConfigRequests
        XCTAssertEqual(
            initialConfigRequests, 1, "The fake rejects media configuration before upload.")

        model.retryDestinations()
        try await waitFor(model.$isLoadingDestinations) { !$0 }
        let configRequests = await api.attachmentConfigRequests
        let uploadRequests = await api.attachmentUploadRequests
        let sends = await api.sentMessageRequests
        XCTAssertEqual(
            configRequests, 1, "Destination reload must not restart the media send pipeline.")
        XCTAssertEqual(uploadRequests, 0)
        XCTAssertTrue(sends.isEmpty)
        XCTAssertEqual(model.selectedDestination, destination)
        XCTAssertEqual(model.caption, "Keep this caption")
        XCTAssertEqual(model.media.map(\.id), mediaIDs)
        XCTAssertTrue(mediaIDs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(model.errorMessage, sendError)
        XCTAssertNil(model.destinationErrorMessage)

        model.retrySend()
        try await waitFor(model.$state) { $0 == .ready }
        let retriedConfigRequests = await api.attachmentConfigRequests
        XCTAssertEqual(retriedConfigRequests, 2)
    }

    private func loadShare(provider: NSItemProvider) async -> (ShareExtensionModel, FakeChatAPI) {
        let page = ListChatsResponse(chats: [
            .init(id: "recipient", name: "Recipient", unreadCount: 0, archived: false, kind: .group)
        ])
        let api = FakeChatAPI(
            chatResults: [.success(page), .success(page)],
            threadResults: [.failure(APIError.unavailable), .success(.init(threads: []))])
        await api.setAuthenticatedProfile(try! shareProfile())
        await api.setConversationPageMetadata(
            group: .init(id: "recipient", myRole: .admin, kind: .group))
        let item = NSExtensionItem()
        item.attachments = [provider]
        let model = ShareExtensionModel(
            extensionItems: [item], makeSession: { ("isolated-session", api) })
        await model.load()
        XCTAssertNil(model.payloadErrorMessage)
        XCTAssertEqual(model.state, .ready)
        return (model, api)
    }

    private func shareProfile(restricted: Bool? = nil) throws -> MeResponse {
        let profile = try JSONDecoder().decode(
            MeResponse.self,
            from: Data(
                #"{"uid":17,"username":"Ada","gender":0,"stickerPackOrder":[],"permissions":[]}"#
                    .utf8))
        return restricted.map { profile.withGroupChatWriteRestriction($0) } ?? profile
    }

    private func waitFor<Value>(
        _ publisher: Published<Value>.Publisher, matching predicate: @escaping (Value) -> Bool
    ) async throws {
        let completed = expectation(description: "Share operation completed")
        let observation = publisher.first(where: predicate).sink { _ in completed.fulfill() }
        defer { observation.cancel() }
        await fulfillment(of: [completed], timeout: 5)
    }
}
