import ChahuaAPI
import Combine
import Foundation
import UniformTypeIdentifiers
import XCTest

@testable import chahua_apple

#if os(macOS)
    import AppKit
#endif

// The test target compiles the extension model and its shared helpers directly,
// without linking the app extension or using the user's Keychain session.

@MainActor
final class ShareExtensionModelTests: XCTestCase {
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
        #if os(macOS)
            // The CI timeout stack showed all 64 dispatch workers blocked in NSAnimation.
            // Off-window loading views must not starve the real item-provider callback below.
            let detachedIndicators = (0..<80).map { _ in
                let indicator = WindowBoundProgressIndicator()
                indicator.style = .spinning
                indicator.isDisplayedWhenStopped = false
                indicator.startAnimation(nil)
                return indicator
            }
            defer { detachedIndicators.forEach { $0.stopAnimation(nil) } }
        #endif
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

    private func waitFor<Value>(
        _ publisher: Published<Value>.Publisher, matching predicate: @escaping (Value) -> Bool
    ) async throws {
        let completed = expectation(description: "Share operation completed")
        let observation = publisher.first(where: predicate).sink { _ in completed.fulfill() }
        defer { observation.cancel() }
        await fulfillment(of: [completed], timeout: 5)
    }
}
