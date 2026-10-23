import ChahuaAPI
import Combine
import Foundation
import XCTest

@testable import chahua_apple

@MainActor
final class RealtimeCoordinatorTests: XCTestCase {
    func testPrivacySelectionAutomaticallySavesAcrossPageDismissal() async throws {
        let api = RealtimeTestHTTP()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let model = PresencePrivacySettingsModel(store: store)
        await model.load()
        await api.holdNextPresenceUpdate()
        let choosing = Task { await model.chooseVisibility(.nobody) }
        await eventually { await api.hasHeldPresenceUpdate }
        XCTAssertEqual(model.visibility, .nobody)
        XCTAssertTrue(model.isSaving)

        // Leaving and reopening the page must not abort or reload over the write.
        model.cancelLoading()
        await model.load()
        XCTAssertTrue(model.isSaving)
        XCTAssertEqual(model.visibility, .nobody)
        await api.releasePresenceUpdate()
        await choosing.value
        XCTAssertFalse(model.isSaving)
        XCTAssertNil(model.saveError)
        let stored = try await api.presenceSettings()
        XCTAssertEqual(stored.visibility, .nobody)

        // Tapping the already selected policy must not start another fallible write.
        await api.setPresenceUpdateError(.unavailable)
        await model.chooseVisibility(.nobody)
        XCTAssertNil(model.saveError)
        XCTAssertEqual(model.visibility, .nobody)
    }

    func testAutomaticPrivacySaveRetainsFailedSelectionAndRetries() async {
        let api = RealtimeTestHTTP()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let model = PresencePrivacySettingsModel(store: store)
        await model.load()
        store.setRealtimeStatus(.connected)
        store.setPresenceScope(PresenceScope(userIDs: [2]), for: UUID())
        store.beginPresenceRequest(1)
        await store.applyRealtimeEvent(
            .presenceSnapshot(
                PresenceSnapshotPayload(
                    requestId: 1, users: [UserPresenceResponse(uid: 2, online: true)], groups: [])),
            currentUserID: 1)
        await api.setPresenceUpdateError(.unavailable)
        await model.chooseVisibility(.friends)
        XCTAssertEqual(model.visibility, .friends)
        XCTAssertNotNil(model.saveError)
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(store.state.userPresence[2]?.online, true)

        await api.setPresenceUpdateError(nil)
        await model.retrySave()
        XCTAssertEqual(model.visibility, .friends)
        XCTAssertNil(model.saveError)
        XCTAssertFalse(model.isSaving)
        XCTAssertNil(store.state.userPresence[2])
    }

    func testPrivacySaveClearsIndividualPresenceAndRefreshesUnchangedWatch() async throws {
        let socket = RealtimeTestSocket()
        let api = RealtimeTestHTTP()
        let clock = RealtimeTestClock()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let coordinator = RealtimeCoordinator(
            provider: RealtimeTestProvider(sockets: [socket]), store: store, onInvalidToken: {},
            sleep: { try await clock.sleep($0) }, jitter: { 0 })
        coordinator.setSceneActive(id: UUID(), active: true)
        coordinator.setSession(uid: 1)
        defer { coordinator.setSession(uid: nil) }
        store.setPresenceScope(PresenceScope(userIDs: [2], chatIDs: ["7"]), for: UUID())
        await eventually { await socket.latestWatch != nil }
        let initialWatch = await socket.latestWatch
        let initialID = try XCTUnwrap(initialWatch?.requestID)
        let user = UserPresenceResponse(uid: 2, online: true)
        let group = GroupPresenceResponse(chatId: "7", memberCount: 8, onlineCount: 3)
        await store.applyRealtimeEvent(
            .presenceSnapshot(
                PresenceSnapshotPayload(requestId: initialID, users: [user], groups: [group])),
            currentUserID: 1)
        var groupCounts: [UInt32?] = []
        let observation = store.$state.sink {
            groupCounts.append($0.groupPresence["7"]?.onlineCount)
        }
        let saved = try await store.updatePresenceSettings(visibility: .nobody)
        XCTAssertEqual(saved.visibility, .nobody)
        XCTAssertNil(store.state.userPresence[2])
        XCTAssertEqual(store.state.groupPresence["7"], group)
        await eventually { await socket.latestWatch.map { $0.requestID > initialID } == true }
        let refreshedWatch = await socket.latestWatch
        let refreshedID = try XCTUnwrap(refreshedWatch?.requestID)
        await store.applyRealtimeEvent(
            .presenceSnapshot(
                PresenceSnapshotPayload(requestId: initialID, users: [user], groups: [group])),
            currentUserID: 1)
        XCTAssertNil(
            store.state.userPresence[2],
            "An old snapshot must not restore privacy-invalidated status.")
        await store.applyRealtimeEvent(
            .presenceSnapshot(
                PresenceSnapshotPayload(requestId: refreshedID, users: [], groups: [group])),
            currentUserID: 1)
        XCTAssertNil(store.state.userPresence[2])
        XCTAssertTrue(
            groupCounts.allSatisfy { $0 == 3 }, "Privacy changes must not hide group counts.")
        withExtendedLifetime(observation) {}
    }

    func testFailedPrivacySaveKeepsCurrentPresenceWatchValid() async throws {
        let api = RealtimeTestHTTP()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        store.setRealtimeStatus(.connected)
        store.setPresenceScope(PresenceScope(userIDs: [2]), for: UUID())
        store.beginPresenceRequest(1)
        await store.applyRealtimeEvent(
            .presenceSnapshot(
                PresenceSnapshotPayload(
                    requestId: 1, users: [UserPresenceResponse(uid: 2, online: true)], groups: [])),
            currentUserID: 1)
        await api.setPresenceUpdateError(.unavailable)
        do {
            _ = try await store.updatePresenceSettings(visibility: .nobody)
            XCTFail("Rejected settings must not be reported as saved.")
        } catch APIError.unavailable {}
        XCTAssertEqual(store.state.userPresence[2]?.online, true)
        let lastSeen = Date(timeIntervalSince1970: 1_800_000_000)
        await store.applyRealtimeEvent(
            .presenceSnapshot(
                PresenceSnapshotPayload(
                    requestId: 1,
                    users: [UserPresenceResponse(uid: 2, online: false, lastSeenAt: lastSeen)],
                    groups: [])),
            currentUserID: 1)
        XCTAssertEqual(store.state.userPresence[2]?.lastSeenAt, lastSeen)
    }

    func testOldAccountPrivacySaveCannotInvalidateNewAccountPresence() async throws {
        let api = RealtimeTestHTTP()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        await api.holdNextPresenceUpdate()
        let saving = Task { try await store.updatePresenceSettings(visibility: .nobody) }
        await eventually { await api.hasHeldPresenceUpdate }
        store.reset()
        store.setRealtimeStatus(.connected)
        store.setPresenceScope(PresenceScope(userIDs: [3]), for: UUID())
        store.beginPresenceRequest(2)
        await store.applyRealtimeEvent(
            .presenceSnapshot(
                PresenceSnapshotPayload(
                    requestId: 2, users: [UserPresenceResponse(uid: 3, online: true)], groups: [])),
            currentUserID: 2)
        await api.releasePresenceUpdate()
        do {
            _ = try await saving.value
            XCTFail("An old account's save must not publish into the new session.")
        } catch is CancellationError {}
        XCTAssertEqual(store.state.userPresence[3]?.online, true)
        await store.applyRealtimeEvent(
            .presenceSnapshot(PresenceSnapshotPayload(requestId: 2, users: [], groups: [])),
            currentUserID: 2)
        XCTAssertNil(store.state.userPresence[3], "The new account's watch must remain usable.")
    }

    func testPresenceRefreshKeepsOverlappingStatusVisibleUntilReplacement() async {
        let api = RealtimeTestHTTP()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        store.setRealtimeStatus(.connected)
        let consumer = UUID()
        store.setPresenceScope(PresenceScope(userIDs: [2], chatIDs: ["7"]), for: consumer)
        store.beginPresenceRequest(1)
        await store.applyRealtimeEvent(
            .presenceSnapshot(
                PresenceSnapshotPayload(
                    requestId: 1, users: [UserPresenceResponse(uid: 2, online: true)],
                    groups: [GroupPresenceResponse(chatId: "7", memberCount: 8, onlineCount: 3)])),
            currentUserID: 1)

        var onlineStates: [Bool?] = []
        var onlineCounts: [UInt32?] = []
        let observation = store.$state.sink { state in
            onlineStates.append(state.userPresence[2]?.online)
            onlineCounts.append(state.groupPresence["7"]?.onlineCount)
        }
        // Scrolling another peer into view must not hide an existing dot or subtitle.
        // Mounting a replacement consumer can transiently empty the aggregate.
        store.removePresenceScope(for: consumer)
        store.setPresenceScope(PresenceScope(userIDs: [2, 3], chatIDs: ["7"]), for: consumer)
        store.beginPresenceRequest(2)
        await store.applyRealtimeEvent(
            .presenceSnapshot(PresenceSnapshotPayload(requestId: 1, users: [], groups: [])),
            currentUserID: 1)
        XCTAssertEqual(store.state.userPresence[2]?.online, true)
        XCTAssertEqual(store.state.groupPresence["7"]?.onlineCount, 3)
        XCTAssertNil(
            store.state.userPresence[3], "New peers stay unknown until the snapshot arrives.")

        let lastSeen = Date(timeIntervalSince1970: 1_800_000_000)
        await store.applyRealtimeEvent(
            .presenceSnapshot(
                PresenceSnapshotPayload(
                    requestId: 2,
                    users: [
                        UserPresenceResponse(uid: 2, online: false, lastSeenAt: lastSeen),
                        UserPresenceResponse(uid: 3, online: true),
                    ],
                    groups: [GroupPresenceResponse(chatId: "7", memberCount: 8, onlineCount: 4)])),
            currentUserID: 1)
        XCTAssertEqual(store.state.userPresence[2]?.online, false)
        XCTAssertEqual(store.state.userPresence[2]?.lastSeenAt, lastSeen)
        XCTAssertEqual(store.state.groupPresence["7"]?.onlineCount, 4)
        XCTAssertTrue(
            onlineStates.allSatisfy { $0 != nil }, "Refresh must not publish a hidden dot.")
        XCTAssertTrue(onlineCounts.allSatisfy { $0 != nil }, "Refresh must not hide group counts.")
        withExtendedLifetime(observation) {}

        store.setPresenceScope(PresenceScope(userIDs: [3]), for: consumer)
        store.beginPresenceRequest(3)
        XCTAssertNil(store.state.userPresence[2])
        XCTAssertTrue(store.state.groupPresence.isEmpty)
        XCTAssertEqual(store.state.userPresence[3]?.online, true)
    }

    func testPresenceSnapshotsRejectOldScopesAndReplaceMissingUsers() async {
        let api = RealtimeTestHTTP()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        store.setRealtimeStatus(.connected)
        let consumer = UUID()
        store.setPresenceScope(PresenceScope(userIDs: [2], chatIDs: ["7"]), for: consumer)
        store.beginPresenceRequest(1)
        let user = UserPresenceResponse(uid: 2, online: true, lastSeenAt: nil)
        let group = GroupPresenceResponse(chatId: "7", memberCount: 8, onlineCount: 3)
        await store.applyRealtimeEvent(
            .presenceSnapshot(
                PresenceSnapshotPayload(requestId: 1, users: [user], groups: [group])),
            currentUserID: 1)
        XCTAssertEqual(store.state.userPresence[2]?.online, true)
        XCTAssertEqual(store.state.groupPresence["7"]?.onlineCount, 3)

        store.setPresenceScope(PresenceScope(userIDs: [3]), for: consumer)
        store.beginPresenceRequest(2)
        await store.applyRealtimeEvent(
            .presenceSnapshot(
                PresenceSnapshotPayload(requestId: 1, users: [user], groups: [group])),
            currentUserID: 1)
        XCTAssertTrue(store.state.userPresence.isEmpty)
        XCTAssertTrue(store.state.groupPresence.isEmpty)
        await store.applyRealtimeEvent(
            .presenceSnapshot(
                PresenceSnapshotPayload(
                    requestId: 2,
                    users: [UserPresenceResponse(uid: 3, online: true, lastSeenAt: nil)],
                    groups: [])),
            currentUserID: 1)
        await store.applyRealtimeEvent(
            .presenceSnapshot(PresenceSnapshotPayload(requestId: 2, users: [], groups: [])),
            currentUserID: 1)
        XCTAssertNil(
            store.state.userPresence[3], "An omitted user must lose its previous online dot.")
        store.setForegroundActive(false)
        await store.applyRealtimeEvent(
            .presenceSnapshot(
                PresenceSnapshotPayload(requestId: 2, users: [user], groups: [group])),
            currentUserID: 1)
        XCTAssertTrue(store.state.userPresence.isEmpty)
        XCTAssertTrue(store.state.groupPresence.isEmpty)
    }

    func testPresenceWatchResubscribesAfterReconnectAndForeground() async throws {
        let first = RealtimeTestSocket()
        let second = RealtimeTestSocket()
        let clock = RealtimeTestClock()
        let api = RealtimeTestHTTP()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let coordinator = RealtimeCoordinator(
            provider: RealtimeTestProvider(sockets: [first, second]), store: store,
            onInvalidToken: {}, sleep: { try await clock.sleep($0) }, jitter: { 0 })
        let scene = UUID()
        coordinator.setSceneActive(id: scene, active: true)
        coordinator.setSession(uid: 1)
        defer { coordinator.setSession(uid: nil) }
        let consumer = UUID()
        store.setPresenceScope(PresenceScope(userIDs: [2]), for: consumer)
        await eventually { await first.latestWatch?.userIDs == [2] }
        let firstWatch = await first.latestWatch
        let firstID = try XCTUnwrap(firstWatch?.requestID)
        await first.emit(
            .presenceSnapshot(
                PresenceSnapshotPayload(
                    requestId: firstID,
                    users: [UserPresenceResponse(uid: 2, online: true, lastSeenAt: nil)], groups: []
                )))
        await eventually { store.state.userPresence[2]?.online == true }
        await first.close()
        await eventually { await clock.hasSleep(seconds: 1) }
        XCTAssertTrue(store.state.userPresence.isEmpty)
        await clock.advance(seconds: 1)
        await eventually { await second.latestWatch?.userIDs == [2] }
        let secondWatch = await second.latestWatch
        let secondID = try XCTUnwrap(secondWatch?.requestID)
        XCTAssertGreaterThan(secondID, firstID)

        coordinator.setSceneActive(id: scene, active: false)
        await eventually { await second.latestWatch?.userIDs == [] }
        // A UI disappearance while inactive must not cancel the queued unsubscribe.
        store.removePresenceScope(for: consumer)
        store.setPresenceScope(PresenceScope(userIDs: [2]), for: consumer)
        coordinator.setSceneActive(id: scene, active: true)
        await eventually { await second.latestWatch?.userIDs == [2] }
        let resumed = await second.latestWatch
        XCTAssertGreaterThan(try XCTUnwrap(resumed?.requestID), secondID)
        coordinator.setSession(uid: nil)
        XCTAssertTrue(store.presenceScope.isEmpty)
        XCTAssertTrue(store.state.userPresence.isEmpty)
    }

    func testPresenceScopesDeduplicateAndRetainOtherConsumersWithinServerLimits() {
        let api = RealtimeTestHTTP()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let first = UUID()
        let second = UUID()
        store.setPresenceScope(PresenceScope(userIDs: [2], chatIDs: ["7"]), for: first)
        store.setPresenceScope(PresenceScope(userIDs: [2, 3], chatIDs: ["7"]), for: second)
        store.removePresenceScope(for: first)
        XCTAssertEqual(store.presenceScope, PresenceScope(userIDs: [2, 3], chatIDs: ["7"]))
        store.setPresenceScope(
            PresenceScope(userIDs: Array(1...Int32(120)), chatIDs: ["1", "2", "3", "4", "5"]),
            for: second)
        XCTAssertEqual(store.presenceScope.userIDs, Array(1...Int32(100)))
        XCTAssertEqual(store.presenceScope.chatIDs, ["1", "2", "3", "4"])
        store.removePresenceScope(for: second)
        XCTAssertTrue(store.presenceScope.isEmpty)
    }

    func testInitialOpenWarnsOnlyAfterThreeForegroundFailures() async {
        let clock = RealtimeTestClock()
        let provider = RealtimeTestProvider(sockets: [], holdOpen: true)
        let api = RealtimeTestHTTP()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let coordinator = RealtimeCoordinator(
            provider: provider, store: store, onInvalidToken: {},
            sleep: { try await clock.sleep($0) }, jitter: { 0 })
        coordinator.setSceneActive(id: UUID(), active: true)
        coordinator.setSession(uid: 1)
        XCTAssertEqual(store.state.realtimeStatus, .connecting)

        await eventually { await provider.opens == 1 }
        await provider.releaseOpen()
        await eventually { await clock.hasSleep(seconds: 1) }
        XCTAssertEqual(store.state.realtimeStatus, .reconnecting)
        await clock.advance(seconds: 1)
        await eventually { await provider.opens == 2 }
        await provider.releaseOpen()
        await eventually { await clock.hasSleep(seconds: 2) }
        XCTAssertEqual(store.state.realtimeStatus, .reconnecting)
        await clock.advance(seconds: 2)
        await eventually { await provider.opens == 3 }
        await provider.releaseOpen()
        await eventually { await clock.hasSleep(seconds: 4) }
        XCTAssertEqual(store.state.realtimeStatus, .unavailable)
        coordinator.setSession(uid: 2)
        XCTAssertEqual(store.state.realtimeStatus, .connecting)
        await eventually { await provider.opens == 4 }
        await provider.releaseOpen()
        await eventually { await clock.hasSleep(seconds: 1) }
        XCTAssertEqual(store.state.realtimeStatus, .reconnecting)
        coordinator.setSession(uid: nil)
        XCTAssertEqual(store.state.realtimeStatus, .idle)
    }

    func testSocketDropDoesNotConsumeAReconnectionFailure() async {
        let clock = RealtimeTestClock()
        let socket = RealtimeTestSocket()
        let provider = RealtimeTestProvider(sockets: [socket])
        let api = RealtimeTestHTTP()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let coordinator = RealtimeCoordinator(
            provider: provider, store: store, onInvalidToken: {},
            sleep: { try await clock.sleep($0) }, jitter: { 0 })
        coordinator.setSceneActive(id: UUID(), active: true)
        coordinator.setSession(uid: 1)
        await eventually { await socket.frames == [.appState(.active)] }
        XCTAssertEqual(store.state.realtimeStatus, .connected)
        await socket.close()
        await eventually { await clock.hasSleep(seconds: 1) }
        XCTAssertEqual(store.state.realtimeStatus, .reconnecting)

        for (delay, nextDelay) in [(1.0, 2.0), (2.0, 4.0)] {
            await clock.advance(seconds: delay)
            await eventually { await clock.hasSleep(seconds: nextDelay) }
            XCTAssertEqual(store.state.realtimeStatus, .reconnecting)
        }
        await clock.advance(seconds: 4)
        await eventually { await clock.hasSleep(seconds: 8) }
        XCTAssertEqual(store.state.realtimeStatus, .unavailable)
        coordinator.setSession(uid: nil)
    }

    func testBackgroundFailuresDoNotConsumeForegroundWarningBudget() async {
        let clock = RealtimeTestClock()
        let provider = RealtimeTestProvider(sockets: [])
        let api = RealtimeTestHTTP()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let coordinator = RealtimeCoordinator(
            provider: provider, store: store, onInvalidToken: {},
            sleep: { try await clock.sleep($0) }, jitter: { 0 })
        coordinator.setSession(uid: 1)
        await eventually { await clock.hasSleep(seconds: 1) }
        for (delay, nextDelay) in [(1.0, 2.0), (2.0, 4.0), (4.0, 8.0)] {
            await clock.advance(seconds: delay)
            await eventually { await clock.hasSleep(seconds: nextDelay) }
            XCTAssertEqual(store.state.realtimeStatus, .reconnecting)
        }

        coordinator.setSceneActive(id: UUID(), active: true)
        XCTAssertEqual(store.state.realtimeStatus, .reconnecting)
        for (delay, nextDelay) in [(8.0, 16.0), (16.0, 30.0)] {
            await clock.advance(seconds: delay)
            await eventually { await clock.hasSleep(seconds: nextDelay) }
            XCTAssertEqual(store.state.realtimeStatus, .reconnecting)
        }
        await clock.advance(seconds: 30)
        await eventually { await provider.opens == 7 }
        await eventually { store.state.realtimeStatus == .unavailable }
        coordinator.setSession(uid: nil)
    }

    func testForegroundResumeClearsWarningWithoutResettingTransportBackoff() async {
        let clock = RealtimeTestClock()
        let provider = RealtimeTestProvider(sockets: [])
        let api = RealtimeTestHTTP()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let coordinator = RealtimeCoordinator(
            provider: provider, store: store, onInvalidToken: {},
            sleep: { try await clock.sleep($0) }, jitter: { 0 })
        let scene = UUID()
        coordinator.setSceneActive(id: scene, active: true)
        coordinator.setSession(uid: 1)
        await eventually { await clock.hasSleep(seconds: 1) }
        await clock.advance(seconds: 1)
        await eventually { await clock.hasSleep(seconds: 2) }
        await clock.advance(seconds: 2)
        await eventually { await clock.hasSleep(seconds: 4) }
        XCTAssertEqual(store.state.realtimeStatus, .unavailable)
        coordinator.setSceneActive(id: scene, active: false)
        coordinator.setSceneActive(id: scene, active: true)
        XCTAssertEqual(store.state.realtimeStatus, .reconnecting)
        let opens = await provider.opens
        XCTAssertEqual(opens, 3)
        for (delay, nextDelay) in [(4.0, 8.0), (8.0, 16.0)] {
            await clock.advance(seconds: delay)
            await eventually { await clock.hasSleep(seconds: nextDelay) }
            XCTAssertEqual(store.state.realtimeStatus, .reconnecting)
        }
        await clock.advance(seconds: 16)
        await eventually { await clock.hasSleep(seconds: 30) }
        XCTAssertEqual(store.state.realtimeStatus, .unavailable)
        coordinator.setSession(uid: nil)
    }

    func testSuccessfulOpenImmediatelyClearsWarningAndResetsOpenFailureBudget() async {
        let clock = RealtimeTestClock()
        let socket = RealtimeTestSocket()
        let provider = RealtimeTestProvider(
            results: [
                .failure(.unavailable), .failure(.unavailable), .failure(.unavailable),
                .success(socket),
            ])
        let api = RealtimeTestHTTP()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let coordinator = RealtimeCoordinator(
            provider: provider, store: store, onInvalidToken: {},
            sleep: { try await clock.sleep($0) }, jitter: { 0 })
        coordinator.setSceneActive(id: UUID(), active: true)
        coordinator.setSession(uid: 1)
        await eventually { await clock.hasSleep(seconds: 1) }
        await clock.advance(seconds: 1)
        await eventually { await clock.hasSleep(seconds: 2) }
        await clock.advance(seconds: 2)
        await eventually { await clock.hasSleep(seconds: 4) }
        XCTAssertEqual(store.state.realtimeStatus, .unavailable)
        await clock.advance(seconds: 4)
        await eventually { await socket.frames == [.appState(.active)] }
        XCTAssertEqual(store.state.realtimeStatus, .connected)
        await socket.close()
        await eventually { await clock.hasSleep(seconds: 8) }
        XCTAssertEqual(store.state.realtimeStatus, .reconnecting)
        for (delay, nextDelay) in [(8.0, 16.0), (16.0, 30.0)] {
            await clock.advance(seconds: delay)
            await eventually { await clock.hasSleep(seconds: nextDelay) }
            XCTAssertEqual(store.state.realtimeStatus, .reconnecting)
        }
        await clock.advance(seconds: 30)
        await eventually { await provider.opens == 7 }
        await eventually { store.state.realtimeStatus == .unavailable }
        coordinator.setSession(uid: nil)
    }

    func testShortLivedReconnectsEventuallyWarn() async {
        let clock = RealtimeTestClock()
        let sockets = (0..<4).map { _ in RealtimeTestSocket() }
        let provider = RealtimeTestProvider(sockets: sockets)
        let api = RealtimeTestHTTP()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let coordinator = RealtimeCoordinator(
            provider: provider, store: store, onInvalidToken: {},
            sleep: { try await clock.sleep($0) }, jitter: { 0 })
        coordinator.setSceneActive(id: UUID(), active: true)
        coordinator.setSession(uid: 1)
        await eventually { await sockets[0].frames == [.appState(.active)] }
        await sockets[0].close()
        await eventually { await clock.hasSleep(seconds: 1) }
        for (index, delay, nextDelay) in [(1, 1.0, 2.0), (2, 2.0, 4.0), (3, 4.0, 8.0)] {
            await clock.advance(seconds: delay)
            await eventually { await sockets[index].frames == [.appState(.active)] }
            XCTAssertEqual(store.state.realtimeStatus, .connected)
            await sockets[index].close()
            await eventually { await clock.hasSleep(seconds: nextDelay) }
            XCTAssertEqual(store.state.realtimeStatus, index == 3 ? .unavailable : .reconnecting)
        }
        coordinator.setSession(uid: nil)
    }

    func testStatusSeedsAndSynchronouslyUpdatesRegisteredTimelineModels() async {
        let api = RealtimeTestHTTP()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let model = ConversationTimelineModel(
            chatID: "1", currentUserID: 1, isGroupChat: true, source: store,
            messageStore: store.conversationMessages)
        store.setRealtimeStatus(.reconnecting)
        store.registerTimeline(model)
        XCTAssertEqual(model.state.realtimeStatus, .reconnecting)
        var observed: [RealtimeConnectionStatus] = []
        let observation = model.$state.map(\.realtimeStatus).sink { observed.append($0) }
        store.setRealtimeStatus(.unavailable)
        XCTAssertEqual(model.state.realtimeStatus, .unavailable)
        XCTAssertEqual(observed, [.reconnecting, .unavailable])
        await model.open()
        XCTAssertEqual(model.state.realtimeStatus, .unavailable)
        XCTAssertEqual(model.state.content, .initialLoadFailed)
        store.reset()
        XCTAssertEqual(store.state.realtimeStatus, .idle)
        XCTAssertEqual(model.state.realtimeStatus, .idle)
        store.unregisterTimeline(model)
        store.setRealtimeStatus(.connected)
        XCTAssertEqual(model.state.realtimeStatus, .idle)
        model.close()
        withExtendedLifetime(observation) {}
    }

    func testReplacementSessionDiscardsLateOpeningSuccess() async {
        let first = RealtimeTestSocket()
        let second = RealtimeTestSocket()
        let provider = RealtimeTestProvider(sockets: [first, second], holdOpen: true)
        let api = RealtimeTestHTTP()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let coordinator = RealtimeCoordinator(
            provider: provider, store: store, onInvalidToken: {})
        coordinator.setSceneActive(id: UUID(), active: true)
        coordinator.setSession(uid: 1)
        await eventually { await provider.opens == 1 }
        coordinator.setSession(uid: 2)
        XCTAssertEqual(store.state.realtimeStatus, .connecting)
        await eventually { await provider.opens == 2 }
        await provider.releaseOpen()
        await eventually { await first.closed }
        XCTAssertEqual(store.state.realtimeStatus, .connecting)
        await provider.releaseOpen()
        await eventually { await second.frames == [.appState(.active)] }
        XCTAssertEqual(store.state.realtimeStatus, .connected)
        coordinator.setSession(uid: nil)
        XCTAssertEqual(store.state.realtimeStatus, .idle)
    }

    func testReplacementSessionDiscardsLateInvalidTokenOpeningFailure() async {
        let socket = RealtimeTestSocket()
        let provider = RealtimeTestProvider(
            results: [.failure(.invalidToken), .success(socket)], holdOpen: true)
        let api = RealtimeTestHTTP()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        var expirations = 0
        let coordinator = RealtimeCoordinator(
            provider: provider, store: store, onInvalidToken: { expirations += 1 })
        coordinator.setSceneActive(id: UUID(), active: true)
        coordinator.setSession(uid: 1)
        await eventually { await provider.opens == 1 }
        coordinator.setSession(uid: 2)
        await eventually { await provider.opens == 2 }
        await provider.releaseOpen()
        await eventually { await provider.completedOpens == 1 }
        await provider.releaseOpen()
        await eventually { await socket.frames == [.appState(.active)] }
        XCTAssertEqual(expirations, 0)
        XCTAssertEqual(store.state.realtimeStatus, .connected)
        coordinator.setSession(uid: nil)
    }

    func testInvalidTokenOpeningFailureImmediatelyExpiresSession() async {
        let provider = RealtimeTestProvider(results: [.failure(.invalidToken)])
        let api = RealtimeTestHTTP()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        var expirations = 0
        let coordinator = RealtimeCoordinator(
            provider: provider, store: store, onInvalidToken: { expirations += 1 })
        coordinator.setSceneActive(id: UUID(), active: true)
        coordinator.setSession(uid: 1)
        await eventually { expirations == 1 }
        XCTAssertEqual(store.state.realtimeStatus, .idle)
        let opens = await provider.opens
        XCTAssertEqual(opens, 1)
        coordinator.setSession(uid: nil)
    }

    func testExpirySuspendedInStorageCannotSignOutReplacementAccount() async {
        let storage = RealtimeExpiryStorage()
        let session = AuthSessionModel(
            apiClient: RealtimeTestHTTP(),
            credentialLoginClient: PrototypeCredentialLoginClient(),
            tokenStorage: storage
        )
        await session.signIn(candidateJWT: "1")
        let expiry = Task { await session.sessionDidExpire() }
        await eventually { await storage.isDeleting }
        await session.signIn(candidateJWT: "2")
        await storage.releaseDelete()
        await expiry.value
        guard case .authenticated(let me) = session.state else {
            XCTFail("Old expiry signed out replacement account")
            return
        }
        XCTAssertEqual(me.uid, 2)
    }

    func testSceneTransitionsKeepSocketAndHeartbeatsPublishCurrentPresence() async {
        let clock = RealtimeTestClock()
        let socket = RealtimeTestSocket()
        let provider = RealtimeTestProvider(sockets: [socket])
        let store = ChatStore(
            apiClient: RealtimeTestHTTP(),
            outgoingQueue: testOutgoingQueue(apiClient: RealtimeTestHTTP()), onInvalidToken: {})
        let coordinator = RealtimeCoordinator(
            provider: provider, store: store, onInvalidToken: {},
            sleep: { try await clock.sleep($0) }, jitter: { 0 })
        let first = UUID()
        let second = UUID()
        coordinator.setSceneActive(id: first, active: true)
        coordinator.setSceneActive(id: second, active: true)
        coordinator.setSession(uid: 1)
        await eventually { await socket.frames == [.appState(.active)] }
        coordinator.removeScene(id: first)
        coordinator.removeScene(id: second)
        await eventually { await socket.frames == [.appState(.active), .appState(.inactive)] }
        await eventually { await clock.hasSleep(seconds: 10) }
        await clock.advance(seconds: 10)
        await eventually { await socket.frames.last == .ping(.inactive) }
        await eventually { await clock.sleepCount(seconds: 10) == 2 }
        await socket.emit(.pong)
        await eventually { await clock.sleepCount(seconds: 10) == 1 }
        coordinator.setSceneActive(id: first, active: true)
        await eventually { await socket.frames.last == .appState(.active) }
        await clock.advance(seconds: 10)
        await eventually { await socket.frames.last == .ping(.active) }
        let frames = await socket.frames
        XCTAssertEqual(
            frames,
            [
                .appState(.active), .appState(.inactive), .ping(.inactive),
                .appState(.active), .ping(.active),
            ])
        let closed = await socket.closed
        let opens = await provider.opens
        XCTAssertFalse(closed)
        XCTAssertEqual(opens, 1)
        coordinator.setSession(uid: nil)
        await eventually { await socket.closed }
    }

    func testMissingPongReconnectsWhileInactiveWithoutAdvertisingActive() async {
        let clock = RealtimeTestClock()
        let first = RealtimeTestSocket()
        let second = RealtimeTestSocket()
        let provider = RealtimeTestProvider(sockets: [first, second])
        let coordinator = RealtimeCoordinator(
            provider: provider,
            store: ChatStore(
                apiClient: RealtimeTestHTTP(),
                outgoingQueue: testOutgoingQueue(apiClient: RealtimeTestHTTP()), onInvalidToken: {}),
            onInvalidToken: {}, sleep: { try await clock.sleep($0) }, jitter: { 0 }
        )
        coordinator.setSession(uid: 1)
        await eventually { await first.frames == [.appState(.inactive)] }
        await eventually { await clock.hasSleep(seconds: 10) }
        await clock.advance(seconds: 10)
        await eventually { await first.frames == [.appState(.inactive), .ping(.inactive)] }
        await eventually { await clock.sleepCount(seconds: 10) == 2 }
        await clock.advance(seconds: 10)
        await eventually { await first.closed }
        await eventually { await clock.hasSleep(seconds: 1) }
        await clock.advance(seconds: 1)
        await eventually { await second.frames == [.appState(.inactive)] }
        await eventually { await clock.hasSleep(seconds: 10) }
        await clock.advance(seconds: 10)
        await eventually { await second.frames == [.appState(.inactive), .ping(.inactive)] }
        let opens = await provider.opens
        XCTAssertEqual(opens, 2)
        coordinator.setSession(uid: nil)
    }

    func testSignOutDiscardsLateSocketOpening() async {
        let socket = RealtimeTestSocket()
        let provider = RealtimeTestProvider(sockets: [socket], holdOpen: true)
        var expired = false
        let coordinator = RealtimeCoordinator(
            provider: provider,
            store: ChatStore(
                apiClient: RealtimeTestHTTP(),
                outgoingQueue: testOutgoingQueue(apiClient: RealtimeTestHTTP()), onInvalidToken: {}),
            onInvalidToken: { expired = true }
        )
        coordinator.setSession(uid: 1)
        coordinator.setSceneActive(id: UUID(), active: true)
        await eventually { await provider.opens == 1 }
        coordinator.setSession(uid: nil)
        await provider.releaseOpen()
        await eventually { await socket.closed }
        XCTAssertFalse(expired)
    }

    func testFocusLossDuringOpeningUsesInactiveInitialState() async {
        let socket = RealtimeTestSocket()
        let provider = RealtimeTestProvider(sockets: [socket], holdOpen: true)
        let coordinator = RealtimeCoordinator(
            provider: provider,
            store: ChatStore(
                apiClient: RealtimeTestHTTP(),
                outgoingQueue: testOutgoingQueue(apiClient: RealtimeTestHTTP()), onInvalidToken: {}),
            onInvalidToken: {}
        )
        let scene = UUID()
        coordinator.setSceneActive(id: scene, active: true)
        coordinator.setSession(uid: 1)
        await eventually { await provider.opens == 1 }
        coordinator.setSceneActive(id: scene, active: false)
        await provider.releaseOpen()
        await eventually { await socket.frames == [.appState(.inactive)] }
        let closed = await socket.closed
        XCTAssertFalse(closed)
        coordinator.setSession(uid: nil)
    }

    func testFocusRestoredDuringInactiveSendRetainsSocketAndFrameOrder() async {
        let socket = RealtimeTestSocket()
        let coordinator = RealtimeCoordinator(
            provider: RealtimeTestProvider(sockets: [socket]),
            store: ChatStore(
                apiClient: RealtimeTestHTTP(),
                outgoingQueue: testOutgoingQueue(apiClient: RealtimeTestHTTP()), onInvalidToken: {}),
            onInvalidToken: {}
        )
        let scene = UUID()
        coordinator.setSceneActive(id: scene, active: true)
        coordinator.setSession(uid: 1)
        await eventually { await socket.frames == [.appState(.active)] }
        await socket.holdNextAppState()
        coordinator.setSceneActive(id: scene, active: false)
        await eventually { await socket.isHoldingAppState }
        coordinator.setSceneActive(id: scene, active: true)
        await socket.releaseAppState()
        await eventually {
            await socket.frames == [.appState(.active), .appState(.inactive), .appState(.active)]
        }
        let closed = await socket.closed
        XCTAssertFalse(closed)
        coordinator.setSession(uid: nil)
    }

    func testAccountReplacementClosesOnlyOldSocketAndPreservesScenePresence() async {
        let first = RealtimeTestSocket()
        let second = RealtimeTestSocket()
        let provider = RealtimeTestProvider(sockets: [first, second])
        let coordinator = RealtimeCoordinator(
            provider: provider,
            store: ChatStore(
                apiClient: RealtimeTestHTTP(),
                outgoingQueue: testOutgoingQueue(apiClient: RealtimeTestHTTP()), onInvalidToken: {}),
            onInvalidToken: {}
        )
        let scene = UUID()
        coordinator.setSceneActive(id: scene, active: true)
        coordinator.setSession(uid: 1)
        await eventually { await first.frames == [.appState(.active)] }
        coordinator.setSession(uid: 2)
        await eventually { await first.closed }
        await eventually { await second.frames == [.appState(.active)] }
        coordinator.setSceneActive(id: scene, active: false)
        await eventually { await second.frames == [.appState(.active), .appState(.inactive)] }
        let oldFrames = await first.frames
        let replacementClosed = await second.closed
        XCTAssertEqual(oldFrames, [.appState(.active)])
        XCTAssertFalse(replacementClosed)
        coordinator.setSession(uid: nil)
    }

    func testInactiveOpenDefersBulkRecoveryUntilActivationWithoutReconnecting() async {
        let api = RealtimeTestHTTP()
        let socket = RealtimeTestSocket()
        let provider = RealtimeTestProvider(sockets: [socket])
        let coordinator = RealtimeCoordinator(
            provider: provider,
            store: ChatStore(
                apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {}
            ),
            onInvalidToken: {}
        )
        coordinator.setSession(uid: 1)
        await eventually { await socket.frames == [.appState(.inactive)] }
        await socket.emit(.pong)
        for _ in 0..<20 { await Task.yield() }
        let refreshedWhileInactive = await api.chatRequestStarted
        XCTAssertFalse(refreshedWhileInactive)
        coordinator.setSceneActive(id: UUID(), active: true)
        await eventually { await api.chatRequestStarted }
        let opens = await provider.opens
        XCTAssertEqual(opens, 1)
        coordinator.setSession(uid: nil)
    }

    func testRecoveryDoesNotBlockLaterEventDelivery() async throws {
        let api = RealtimeTestHTTP(holdChats: true)
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let socket = RealtimeTestSocket()
        let coordinator = RealtimeCoordinator(
            provider: RealtimeTestProvider(sockets: [socket]), store: store, onInvalidToken: {})
        var received = false
        let observation = store.conversationMessages.changes.sink { change in
            if case .realtime(.threadUpdate(let payload)) = change {
                received = payload.replyCount == 9
            }
        }
        coordinator.setSession(uid: 1)
        coordinator.setSceneActive(id: UUID(), active: true)
        await socket.emit(.pong)
        await eventually { await api.chatRequestStarted }
        await socket.emit(.presenceUpdate(PresenceUpdatePayload(activeConnections: 1)))
        await socket.emit(.unknown(type: "futureEvent"))
        await socket.emit(
            .threadUpdate(
                ThreadUpdatePayload(
                    threadRootId: "100", chatId: "1", lastReplyAt: Date(), replyCount: 9)))
        await eventually { received }
        XCTAssertTrue(received)
        coordinator.setSession(uid: nil)
        await api.releaseChats()
        withExtendedLifetime(observation) {}
    }

    func testHealthyForegroundResumeRetainsListsAndReplacesUnreadWatch() async throws {
        let api = RealtimeTestHTTP()
        let socket = RealtimeTestSocket()
        let store = ChatStore(
            apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {})
        let coordinator = RealtimeCoordinator(
            provider: RealtimeTestProvider(sockets: [socket]), store: store, onInvalidToken: {})
        let scene = UUID()
        coordinator.setSceneActive(id: scene, active: true)
        coordinator.setSession(uid: 1)
        defer { coordinator.setSession(uid: nil) }
        await eventually {
            store.state.chatListLoadPhase == .loaded
                && store.state.archivedChatListLoadPhase == .loaded
                && store.state.threadListLoadPhase == .loaded
                && store.state.archivedThreadListLoadPhase == .loaded
        }
        await eventually { await socket.unreadWatches.last?.appBadge == true }
        let initialWatch = await socket.unreadWatches.last
        let initial = try XCTUnwrap(initialWatch)
        await socket.emit(
            .conversationUnread(
                .init(requestId: initial.requestID, full: true, summaries: [], appBadgeCount: 7)))
        await eventually { store.state.unreadBadgeCount() == 7 }
        let requestsBefore = await api.chatRequestCount

        coordinator.setSceneActive(id: scene, active: false)
        await eventually { await socket.unreadWatches.last?.appBadge == false }
        coordinator.setSceneActive(id: scene, active: true)
        await eventually { await socket.unreadWatches.last?.appBadge == true }
        let resumedWatch = await socket.unreadWatches.last
        let resumed = try XCTUnwrap(resumedWatch)
        XCTAssertGreaterThan(resumed.requestID, initial.requestID)
        await socket.emit(
            .conversationUnread(
                .init(requestId: initial.requestID, full: true, summaries: [], appBadgeCount: 99)))
        await socket.emit(
            .conversationUnread(
                .init(requestId: resumed.requestID, full: true, summaries: [], appBadgeCount: 4)))
        await eventually { store.state.unreadBadgeCount() == 4 }
        let requestsAfter = await api.chatRequestCount
        XCTAssertEqual(requestsAfter, requestsBefore, "Healthy resume must not reload list pages.")
    }

    private func eventually(
        _ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<5_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Expected asynchronous transition did not occur", file: file, line: line)
    }
}

private actor RealtimeTestClock {
    private struct Waiter {
        let deadline: Double
        let duration: Double
        let continuation: CheckedContinuation<Void, Error>
    }
    private var now = 0.0
    private var waiters: [UUID: Waiter] = [:]

    func sleep(_ duration: Duration) async throws {
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = Waiter(
                    deadline: now + seconds, duration: seconds, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func hasSleep(seconds: Double) -> Bool { waiters.values.contains { $0.duration == seconds } }
    func sleepCount(seconds: Double) -> Int {
        waiters.values.filter { $0.duration == seconds }.count
    }
    func advance(seconds: Double) {
        now += seconds
        let due = waiters.filter { $0.value.deadline <= now }
        for (id, waiter) in due {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }
    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}

private actor RealtimeTestSocket: RealtimeConnection {
    enum Frame: Equatable, Sendable {
        case appState(RealtimeAppState)
        case ping(RealtimeAppState)
        case watch(UInt64, [Int32], [String])
    }
    struct UnreadWatch: Sendable {
        let requestID: UInt32
        let views: [ConversationView]
        let appBadge: Bool
    }
    struct StateWatch: Sendable {
        let requestID: UInt32
        let conversations: [ConversationRef]
    }
    private(set) var unreadWatches: [UnreadWatch] = []
    private(set) var stateWatches: [StateWatch] = []
    private(set) var frames: [Frame] = []
    struct Watch: Sendable {
        let requestID: UInt64
        let userIDs: [Int32]
        let chatIDs: [String]
    }
    var latestWatch: Watch? {
        for case .watch(let id, let users, let groups) in frames.reversed() {
            return Watch(requestID: id, userIDs: users, chatIDs: groups)
        }
        return nil
    }
    private var events: [RealtimeServerEvent] = []
    private var receiver: CheckedContinuation<RealtimeServerEvent, Error>?
    private var holdsNextAppState = false
    private var heldAppState: CheckedContinuation<Void, Never>?
    var isHoldingAppState: Bool { heldAppState != nil }
    func holdNextAppState() { holdsNextAppState = true }
    func releaseAppState() {
        heldAppState?.resume()
        heldAppState = nil
    }
    private(set) var closed = false
    func receive() async throws -> RealtimeServerEvent {
        if closed { throw CancellationError() }
        if !events.isEmpty { return events.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func sendPing(state: RealtimeAppState) async throws {
        guard !closed else { throw CancellationError() }
        frames.append(.ping(state))
    }
    func sendAppState(_ state: RealtimeAppState) async throws {
        if holdsNextAppState {
            holdsNextAppState = false
            await withCheckedContinuation { heldAppState = $0 }
        }
        guard !closed else { throw CancellationError() }
        frames.append(.appState(state))
    }
    func sendWatchPresence(requestID: UInt64, userIDs: [Int32], chatIDs: [String]) async throws {
        guard !closed else { throw CancellationError() }
        frames.append(.watch(requestID, userIDs, chatIDs))
    }
    func sendWatchConversationUnread(
        requestID: UInt32, views: [ConversationView], appBadge: Bool
    ) async throws {
        guard !closed else { throw CancellationError() }
        unreadWatches.append(.init(requestID: requestID, views: views, appBadge: appBadge))
    }
    func sendWatchConversationStates(
        requestID: UInt32, conversations: [ConversationRef]
    ) async throws {
        guard !closed else { throw CancellationError() }
        stateWatches.append(.init(requestID: requestID, conversations: conversations))
    }
    func close() {
        closed = true
        releaseAppState()
        receiver?.resume(throwing: CancellationError())
        receiver = nil
    }
    func emit(_ event: RealtimeServerEvent) {
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: event)
        } else {
            events.append(event)
        }
    }
}

private actor RealtimeTestProvider: RealtimeConnectionProviding {
    private var results: [Result<RealtimeTestSocket, APIError>]
    private let holdOpen: Bool
    private var openings: [CheckedContinuation<Void, Never>] = []
    private(set) var opens = 0
    private(set) var completedOpens = 0
    init(sockets: [RealtimeTestSocket], holdOpen: Bool = false) {
        results = sockets.map { .success($0) }
        self.holdOpen = holdOpen
    }
    init(results: [Result<RealtimeTestSocket, APIError>], holdOpen: Bool = false) {
        self.results = results
        self.holdOpen = holdOpen
    }
    func openRealtimeConnection() async throws -> any RealtimeConnection {
        opens += 1
        let result = results.isEmpty ? .failure(APIError.unavailable) : results.removeFirst()
        if holdOpen { await withCheckedContinuation { openings.append($0) } }
        defer { completedOpens += 1 }
        return try result.get()
    }
    func releaseOpen() {
        guard !openings.isEmpty else { return }
        openings.removeFirst().resume()
    }
}

private actor RealtimeTestHTTP: ChahuaAPIClient {
    private let holdChats: Bool
    private var chats: CheckedContinuation<Void, Never>?
    private(set) var chatRequestStarted = false
    private(set) var chatRequestCount = 0
    init(holdChats: Bool = false) { self.holdChats = holdChats }
    private var visibility: PresenceVisibility = .everyone
    private var presenceUpdateError: APIError?
    private var holdsPresenceUpdate = false
    private var heldPresenceUpdate: CheckedContinuation<PresenceSettingsResponse, Error>?
    var hasHeldPresenceUpdate: Bool { heldPresenceUpdate != nil }
    private var receiptVisibility: ReadReceiptVisibility = .friends
    private var receiptOverrides: [Int32: FriendReadReceiptOverride] = [:]

    private enum UnexpectedActivityCall: Error { case unread }
    func unreadMentions(chatID: String, threadID: MessageID?) async throws
        -> UnreadMentionIDsResponse
    {
        throw UnexpectedActivityCall.unread
    }
    func unreadReactions(chatID: String, threadID: MessageID?) async throws
        -> UnreadReactionIDsResponse
    {
        throw UnexpectedActivityCall.unread
    }
    func acknowledgeReactions(chatID: String, threadID: MessageID?, readThrough: String?)
        async throws -> UnreadReactionsAckResponse
    {
        throw UnexpectedActivityCall.unread
    }

    func readReceipt(chatID: String, threadID: MessageID?) async throws -> ReadReceiptResponse {
        ReadReceiptResponse()
    }
    func readReceiptSettings() async throws -> ReadReceiptSettingsResponse {
        .init(visibility: receiptVisibility)
    }
    func updateReadReceiptSettings(visibility: ReadReceiptVisibility) async throws
        -> ReadReceiptSettingsResponse
    {
        receiptVisibility = visibility
        return .init(visibility: visibility)
    }
    func friendReadReceiptSettings(peerUID: Int32) async throws -> FriendReadReceiptSettingsResponse
    {
        .init(override: receiptOverrides[peerUID] ?? .inherit)
    }
    func updateFriendReadReceiptSettings(peerUID: Int32, override: FriendReadReceiptOverride)
        async throws -> FriendReadReceiptSettingsResponse
    {
        receiptOverrides[peerUID] = override
        return .init(override: override)
    }

    func presenceSettings() async throws -> PresenceSettingsResponse {
        PresenceSettingsResponse(visibility: visibility)
    }

    func updatePresenceSettings(visibility: PresenceVisibility) async throws
        -> PresenceSettingsResponse
    {
        if let presenceUpdateError { throw presenceUpdateError }
        self.visibility = visibility
        if holdsPresenceUpdate {
            holdsPresenceUpdate = false
            return try await withCheckedThrowingContinuation { heldPresenceUpdate = $0 }
        }
        return PresenceSettingsResponse(visibility: visibility)
    }

    func setPresenceUpdateError(_ error: APIError?) { presenceUpdateError = error }
    func holdNextPresenceUpdate() { holdsPresenceUpdate = true }
    func releasePresenceUpdate() {
        heldPresenceUpdate?.resume(returning: PresenceSettingsResponse(visibility: visibility))
        heldPresenceUpdate = nil
    }

    func authenticate(candidateJWT: String) async throws -> MeResponse {
        try JSONDecoder().decode(
            MeResponse.self,
            from: Data(
                "{\"uid\":\(Int(candidateJWT) ?? 1),\"username\":\"Test\",\"gender\":0,\"stickerPackOrder\":[],\"permissions\":[]}"
                    .utf8
            ))
    }
    func createDevSession(uid: Int32, clientID: String) async throws -> String {
        throw APIError.unavailable
    }
    func me() async throws -> MeResponse { throw APIError.unavailable }
    func attachmentConfig() async throws -> AttachmentConfigResponse { throw APIError.unavailable }
    func requestAttachmentUpload(
        fileName: String, contentType: String, size: Int64, width: Int, height: Int, order: Int
    ) async throws -> OutgoingUploadAllocation { throw APIError.unavailable }
    func listOwnedStickerPacks() async throws -> [StickerPackSummary] { throw APIError.unavailable }
    func listSubscribedStickerPacks() async throws -> [StickerPackSummary] {
        throw APIError.unavailable
    }
    func listFavoriteStickers() async throws -> [MessageStickerResponse] {
        throw APIError.unavailable
    }
    func getSticker(id: String) async throws -> StickerDetailResponse { throw APIError.unavailable }
    func getStickerPack(id: String) async throws -> StickerPackDetailResponse {
        throw APIError.unavailable
    }
    func setStickerFavorite(id: String, favorite: Bool) async throws { throw APIError.unavailable }
    func setStickerPackSubscription(id: String, subscribed: Bool) async throws {
        throw APIError.unavailable
    }
    func createStickerPack(name: String, description: String?) async throws -> StickerPackSummary {
        throw APIError.unavailable
    }
    func updateStickerPack(id: String, name: String?, description: String?) async throws
        -> StickerPackSummary
    { throw APIError.unavailable }
    func deleteStickerPack(id: String) async throws { throw APIError.unavailable }
    func uploadStickerToPack(
        id: String, upload: StickerUpload, emoji: String, name: String?, description: String?
    ) async throws -> MessageStickerResponse { throw APIError.unavailable }
    func removeStickerFromPack(id: String, stickerID: String) async throws {
        throw APIError.unavailable
    }
    func updateStickerPackOrder(_ order: [StickerPackOrderUpdate]) async throws {
        throw APIError.unavailable
    }
    func groupInfo(chatID: String) async throws -> GroupInfoResponse { throw APIError.unavailable }
    func listMembers(chatID: String, query: ListMembersQuery) async throws -> ListMembersResponse {
        throw APIError.unavailable
    }
    func updateGroupMemberRole(chatID: String, uid: Int32, role: GroupRole) async throws
        -> MemberResponse
    { throw APIError.unavailable }
    func removeGroupMember(chatID: String, uid: Int32) async throws { throw APIError.unavailable }
    func friendRelationship(peerUID: Int32) async throws -> FriendRelationshipResponse {
        throw APIError.unavailable
    }
    func getMessage(chatID: String, messageID: MessageID) async throws -> MessageResponse {
        throw APIError.unavailable
    }

    func getReactionDetails(chatID: String, messageID: MessageID) async throws
        -> ReactionDetailResponse
    {
        throw APIError.unavailable
    }
    func deleteMessage(chatID: String, messageID: MessageID) async throws {
        throw APIError.unavailable
    }
    func markChatRead(chatID: String, messageID: MessageID) async throws -> ReadStateResponse {
        throw APIError.unavailable
    }
    func markChatUnread(chatID: String) async throws -> ReadStateResponse {
        throw APIError.unavailable
    }
    func archiveChat(chatID: String) async throws { throw APIError.unavailable }
    func unarchiveChat(chatID: String) async throws { throw APIError.unavailable }
    func archiveThread(chatID: String, threadID: String) async throws { throw APIError.unavailable }
    func unarchiveThread(chatID: String, threadID: String) async throws {
        throw APIError.unavailable
    }
    func markThreadRead(chatID: String, threadID: String, messageID: MessageID) async throws
        -> ReadStateResponse
    { throw APIError.unavailable }
    func putReaction(chatID: String, messageID: MessageID, emoji: String) async throws {
        throw APIError.unavailable
    }
    func deleteReaction(chatID: String, messageID: MessageID, emoji: String) async throws {
        throw APIError.unavailable
    }
    func listThreads(query: ListThreadsQuery) async throws -> ListThreadsResponse {
        .init(threads: [])
    }
    func sendThreadMessage(chatID: String, threadID: String, body: CreateMessageBody) async throws
        -> MessageResponse
    { throw APIError.unavailable }
    func listChats(query: ListChatsQuery) async throws -> ListChatsResponse {
        chatRequestStarted = true
        chatRequestCount += 1
        if holdChats { await withCheckedContinuation { chats = $0 } }
        return ListChatsResponse(chats: [])
    }
    func releaseChats() {
        chats?.resume()
        chats = nil
    }
    func listMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse
    { throw APIError.unavailable }
    func sendMessage(chatID: String, body: CreateMessageBody) async throws -> MessageResponse {
        throw APIError.unavailable
    }
}

private actor RealtimeExpiryStorage: SessionTokenStorage {
    private var deletion: CheckedContinuation<Void, Never>?
    var isDeleting: Bool { deletion != nil }
    func loadToken() async throws -> String? { nil }
    func saveToken(_ token: String) async throws {}
    func deleteToken() async throws { await withCheckedContinuation { deletion = $0 } }
    func releaseDelete() {
        deletion?.resume()
        deletion = nil
    }
}
