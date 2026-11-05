import ChahuaAPI
import Foundation
import XCTest

@testable import chahua_apple

@MainActor
final class StickerDiscoveryTests: XCTestCase {
    func testPaginationDeduplicatesRowsButRetriesAndAdvancesUsingRawServerOffset() async {
        let api = FakeChatAPI()
        let library = StickerLibrary(apiClient: api, onInvalidToken: {})
        library.setAccount(1)
        let first = pack("first")
        let initial = Task { await library.discover(query: " 茶 ", sort: .subscribers) }
        await api.waitForStickerDiscoveryRequests(1)
        await api.finishStickerDiscovery(0, with: .success(page([first, first], hasMore: true)))
        await initial.value
        XCTAssertEqual(library.discoveryPacks.map(\.id), ["first"])
        XCTAssertEqual(library.discoveryCursor, 2)

        let failedPage = Task {
            await library.discover(query: " 茶 ", sort: .subscribers, more: true)
        }
        await api.waitForStickerDiscoveryRequests(2)
        await api.finishStickerDiscovery(1, with: .failure(APIError.unavailable))
        await failedPage.value
        XCTAssertEqual(library.discoveryPacks.map(\.id), ["first"])
        XCTAssertEqual(library.discoveryCursor, 2)
        XCTAssertNotNil(library.discoveryError)
        XCTAssertFalse(library.isDiscovering)

        let retry = Task { await library.retryDiscovery() }
        await api.waitForStickerDiscoveryRequests(3)
        await api.finishStickerDiscovery(
            2,
            with: .success(page([pack("first", name: "Updated"), pack("second")], hasMore: true)))
        await retry.value
        XCTAssertEqual(library.discoveryPacks.map(\.id), ["first", "second"])
        XCTAssertEqual(library.discoveryPacks.first?.pack.name, "Updated")
        XCTAssertEqual(library.discoveryCursor, 4)
        XCTAssertNil(library.discoveryError)

        let finalPage = Task {
            await library.discover(query: "茶", sort: .subscribers, more: true)
        }
        await api.waitForStickerDiscoveryRequests(4)
        await api.finishStickerDiscovery(3, with: .success(page([], hasMore: false)))
        await finalPage.value
        XCTAssertEqual(library.discoveryPacks.map(\.id), ["first", "second"])
        XCTAssertNil(library.discoveryCursor)
        let requests = await api.recordedStickerDiscoveryRequests()
        XCTAssertEqual(requests.map { $0.offset }, [0, 2, 2, 4])
        XCTAssertEqual(requests.map { $0.query }, ["茶", "茶", "茶", "茶"])
        XCTAssertTrue(requests.allSatisfy { $0.limit == 20 && $0.sort == .subscribers })
    }

    func testSearchRetainsKnownRowsAndIgnoresOlderResponseAfterNewResultsArrive() async {
        let api = FakeChatAPI()
        let library = StickerLibrary(apiClient: api, onInvalidToken: {})
        library.setAccount(1)
        let initial = Task { await library.discover(query: "", sort: .trending) }
        await api.waitForStickerDiscoveryRequests(1)
        await api.finishStickerDiscovery(0, with: .success(page([pack("known")], hasMore: true)))
        await initial.value

        let older = Task { await library.discover(query: "old", sort: .trending) }
        await api.waitForStickerDiscoveryRequests(2)
        XCTAssertEqual(library.discoveryPacks.map(\.id), ["known"])
        XCTAssertNil(library.discoveryCursor, "Old pagination must stop while replacing a search")
        let latest = Task { await library.discover(query: "new", sort: .subscribers) }
        await api.waitForStickerDiscoveryRequests(3)
        XCTAssertTrue(library.isDiscovering)
        XCTAssertEqual(library.discoveryPacks.map(\.id), ["known"])

        await api.finishStickerDiscovery(2, with: .success(page([pack("latest")], hasMore: true)))
        await latest.value
        let revision = library.discoveryRevision
        await api.finishStickerDiscovery(
            1, with: .success(page([pack("obsolete")], hasMore: false)))
        await older.value
        XCTAssertEqual(library.discoveryPacks.map(\.id), ["latest"])
        XCTAssertEqual(library.discoveryCursor, 1)
        XCTAssertEqual(library.discoveryRevision, revision)
        XCTAssertNil(library.discoveryError)
        XCTAssertFalse(library.isDiscovering)
    }

    func testAccountReplacementDiscardsLateRowsAndAuthenticationFailureWithoutStoppingNewLoad()
        async
    {
        let api = FakeChatAPI()
        var invalidations = 0
        let library = StickerLibrary(apiClient: api) { invalidations += 1 }
        library.setAccount(1)
        let oldRows = Task { await library.discover(query: "old", sort: .trending) }
        await api.waitForStickerDiscoveryRequests(1)
        let oldFailure = Task { await library.discover(query: "other", sort: .trending) }
        await api.waitForStickerDiscoveryRequests(2)
        library.setAccount(2)
        XCTAssertTrue(library.discoveryPacks.isEmpty)
        XCTAssertFalse(library.hasLoadedDiscovery)
        XCTAssertNil(library.discoveryCursor)
        let current = Task { await library.discover(query: "", sort: .trending) }
        await api.waitForStickerDiscoveryRequests(3)

        await api.finishStickerDiscovery(
            0, with: .success(page([pack("old-account")], hasMore: true)))
        await api.finishStickerDiscovery(1, with: .failure(APIError.invalidToken))
        await oldRows.value
        await oldFailure.value
        XCTAssertTrue(library.discoveryPacks.isEmpty)
        XCTAssertNil(library.discoveryError)
        XCTAssertTrue(
            library.isDiscovering, "Stale request cleanup must not stop the new account's load")
        XCTAssertEqual(invalidations, 0)

        await api.finishStickerDiscovery(
            2, with: .success(page([pack("current-account")], hasMore: false)))
        await current.value
        XCTAssertEqual(library.discoveryPacks.map(\.id), ["current-account"])
        XCTAssertEqual(library.accountID, 2)
        XCTAssertTrue(library.hasLoadedDiscovery)
        XCTAssertFalse(library.isDiscovering)
    }

    private func pack(_ id: String, name: String? = nil) -> StickerPackDiscoveryItem {
        StickerPackDiscoveryItem(
            pack: StickerPackSummary(
                id: id, ownerUid: 42, name: name ?? id,
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0),
                stickerCount: 0, isSubscribed: false),
            visibility: .public, previewStickers: [], recentSubscriberCount: 2, subscriberCount: 5)
    }

    private func page(_ packs: [StickerPackDiscoveryItem], hasMore: Bool)
        -> StickerPackDiscoveryResponse
    {
        StickerPackDiscoveryResponse(
            packs: packs, hasMore: hasMore, recentWindowDays: 30,
            statsUpdatedAt: Date(timeIntervalSince1970: 0))
    }
}
