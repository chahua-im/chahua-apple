import ChahuaAPI
import Combine
import XCTest

@testable import chahua_apple

@MainActor
final class ConversationTimelineModelTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    func testIsolatedLatestSeedRetainsRowThroughHeldFailureAndExplicitRetry() async throws {
        let (cache, local) = try await makeHistoryCache()
        let key = ConversationKey(chatID: "chat")
        let seed = try TimelineTestFixtures.message(id: 20, senderID: 2, at: 20)
        let epoch = try await local.cacheEpoch()
        try await local.cacheChange(.create(seed, key, adjoining: nil), epoch: epoch)
        let source = ScriptedTimelineSource(pages: [
            .failure(StubError()), .success(try TimelineTestFixtures.page([seed])),
        ])
        var online = true
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false,
            source: source, messageStore: source.store, historyCache: cache,
            canFetchHistory: { online })
        defer { model.close() }
        source.holdNextRequest()
        let opening = Task { await model.open() }
        await source.waitUntilHeld()
        XCTAssertEqual(model.rows.compactMap(\.messageID), [seed.id])
        XCTAssertTrue(model.state.hasUnverifiedLatestSeed)
        XCTAssertEqual(model.state.olderEdgePresentation, .loading)
        source.release()
        await opening.value
        XCTAssertEqual(model.rows.compactMap(\.messageID), [seed.id])
        XCTAssertEqual(model.state.olderEdgePresentation, .retryNetworkHistory)
        online = false  // Explicit retry must bypass a stale path hint.
        source.holdNextRequest()
        let retrying = Task { await model.retryNetworkHistory() }
        await source.waitUntilHeld()
        XCTAssertEqual(model.rows.compactMap(\.messageID), [seed.id])
        XCTAssertEqual(model.state.olderEdgePresentation, .loading)
        source.release()
        await retrying.value
        XCTAssertFalse(model.state.hasUnverifiedLatestSeed)
        XCTAssertEqual(model.state.history, .server)
    }

    func testOnlineUnreadSeedWaitsForMissingAnchorWithoutPublishingBoundary() async throws {
        let (cache, local) = try await makeHistoryCache()
        let key = ConversationKey(chatID: "chat")
        let seed = try TimelineTestFixtures.message(id: 20, senderID: 2, at: 20)
        let anchor = try TimelineTestFixtures.message(id: 10, senderID: 2, at: 10)
        let epoch = try await local.cacheEpoch()
        try await local.cacheChange(.create(seed, key, adjoining: nil), epoch: epoch)
        let source = ScriptedTimelineSource(pages: [
            .success(try TimelineTestFixtures.page([anchor, seed]))
        ])
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false,
            source: source, messageStore: source.store, historyCache: cache)
        defer { model.close() }
        source.holdNextRequest()
        let opening = Task { await model.loadInitial(position: .unread(after: anchor.id)) }
        await source.waitUntilHeld()
        XCTAssertEqual(model.state.content, .loadingInitial)
        XCTAssertTrue(model.rows.isEmpty)
        source.release()
        await opening.value
        XCTAssertEqual(model.state.history, .server)
        XCTAssertEqual(model.rows.compactMap(\.messageID), [anchor.id, seed.id])
        XCTAssertTrue(model.rows.contains { $0.id == .unreadSeparator })
    }

    func testOfflineIsolatedSeedAndVerifiedSingletonRemainDistinct() async throws {
        for isolated in [true, false] {
            let (cache, local) = try await makeHistoryCache()
            let key = ConversationKey(chatID: "chat")
            let message = try TimelineTestFixtures.message(id: 20, senderID: 2, at: 20)
            let epoch = try await local.cacheEpoch()
            if isolated {
                try await local.cacheChange(.create(message, key, adjoining: nil), epoch: epoch)
            } else {
                try await local.cacheHistory(
                    key, query: .init(max: 50),
                    response: TimelineTestFixtures.page([message]), epoch: epoch)
            }
            let source = ScriptedTimelineSource(pages: [])
            let model = ConversationTimelineModel(
                chatID: "chat", currentUserID: 1, isGroupChat: false,
                source: source, messageStore: source.store, historyCache: cache,
                canFetchHistory: { false })
            await model.loadInitial(position: .unread(after: MessageID(10)))
            XCTAssertEqual(model.state.content, .ready)
            XCTAssertEqual(model.rows.compactMap(\.messageID), [message.id])
            XCTAssertEqual(model.state.hasUnverifiedLatestSeed, isolated)
            XCTAssertEqual(model.state.olderEdgePresentation, .none)
            XCTAssertTrue(source.queries.isEmpty)
            model.close()
        }
    }

    func testIsolatedMessageTargetReplaysEditOverHeldStaleHistory() async throws {
        let (cache, local) = try await makeHistoryCache()
        let key = ConversationKey(chatID: "chat")
        let seed = try TimelineTestFixtures.message(id: 20, senderID: 2, at: 20, text: "stale")
        let edited = try TimelineTestFixtures.message(id: 20, senderID: 2, at: 20, text: "edited")
        let epoch = try await local.cacheEpoch()
        try await local.cacheChange(.create(seed, key, adjoining: nil), epoch: epoch)
        let source = ScriptedTimelineSource(pages: [
            .success(try TimelineTestFixtures.page([seed]))
        ])
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false,
            source: source, messageStore: source.store, historyCache: cache)
        defer { model.close() }
        source.holdNextRequest()
        let opening = Task { await model.loadInitial(position: .message(seed.id)) }
        await source.waitUntilHeld()
        XCTAssertEqual(model.rows.compactMap(\.messageID), [seed.id])
        XCTAssertFalse(model.state.live.followsLatest)
        source.store.apply(.messageUpdated(edited))
        source.release()
        await opening.value
        XCTAssertEqual(remoteMessages(model).map(\.id), [seed.id])
        XCTAssertEqual(remoteMessages(model).first?.message, "edited")
        XCTAssertFalse(model.state.hasUnverifiedLatestSeed)
        XCTAssertFalse(model.state.live.followsLatest)
    }

    func testColdChatSwitchPublishesReplayedSQLiteTailBeforeResumeWithoutFetching() async throws {
        let (cache, local) = try await makeHistoryCache()
        let a = ConversationKey(chatID: "a")
        let b = ConversationKey(chatID: "b")
        let original = try TimelineTestFixtures.message(
            id: 10, chatID: a.chatID, senderID: 2, at: 10, text: "original")
        let edited = try TimelineTestFixtures.message(
            id: 10, chatID: a.chatID, senderID: 2, at: 10, text: "edited while hidden")
        let removed = try TimelineTestFixtures.message(
            id: 20, chatID: a.chatID, senderID: 2, at: 20, text: "deleted while hidden")
        let arrival = try TimelineTestFixtures.message(
            id: 30, chatID: a.chatID, senderID: 2, at: 30)
        let other = try TimelineTestFixtures.message(id: 40, chatID: b.chatID, senderID: 2, at: 40)
        try await seedSyncTail([original, removed], for: a, at: "a-base", in: local)
        try await seedSyncTail([other], for: b, at: "b-base", in: local)

        let offline = ScriptedTimelineSource(pages: [])
        func offlineTimeline(_ key: ConversationKey) -> ConversationTimelineModel {
            ConversationTimelineModel(
                chatID: key.chatID, currentUserID: 1, isGroupChat: false,
                source: offline, messageStore: offline.store, historyCache: cache,
                canFetchHistory: { false })
        }
        do {
            let firstA = offlineTimeline(a)
            defer { firstA.close() }
            await firstA.open()
            XCTAssertEqual(firstA.rows.compactMap(\.messageID), [original.id, removed.id])
        }
        do {
            let showingB = offlineTimeline(b)
            defer { showingB.close() }
            await showingB.open()
            let replay = try await cache.commitSyncBatch(
                chatID: a.chatID, from: "a-base", to: "a-replayed",
                changes: [
                    .upsert(message: edited, appeared: false),
                    .delete(messageID: removed.id, threadRootID: nil),
                    .upsert(message: arrival, appeared: true),
                ])
            XCTAssertEqual(replay, .committed)
            XCTAssertEqual(showingB.rows.compactMap(\.messageID), [other.id])
        }

        // No previous model or in-memory message journal can supply the returning rows.
        let source = ScriptedTimelineSource(pages: [.failure(StubError())])
        let waiting = expectation(description: "Freshness decision waits for sync resume")
        var resumeSync: CheckedContinuation<Void, Never>?
        source.waitForSync = {
            await withCheckedContinuation {
                resumeSync = $0
                waiting.fulfill()
            }
        }
        let returningA = ConversationTimelineModel(
            chatID: a.chatID, currentUserID: 1, isGroupChat: false,
            source: source, messageStore: source.store, historyCache: cache)
        defer {
            returningA.close()
            resumeSync?.resume()
        }
        let opening = Task { await returningA.open() }
        await fulfillment(of: [waiting], timeout: 3)

        XCTAssertEqual(returningA.state.history, .saved)
        XCTAssertEqual(returningA.rows.compactMap(\.messageID), [edited.id, arrival.id])
        XCTAssertEqual(remoteMessages(returningA).first?.message, "edited while hidden")
        XCTAssertTrue(source.queries.isEmpty)
        reportVisible([edited.id, arrival.id], to: returningA, distanceToBottom: 0)

        source.syncCoverage.insert(a)
        source.waitForSync = nil
        resumeSync?.resume()
        resumeSync = nil
        await opening.value

        XCTAssertEqual(returningA.state.history, .server)
        XCTAssertTrue(returningA.isAtLiveEdge)
        XCTAssertEqual(returningA.rows.compactMap(\.messageID), [edited.id, arrival.id])
        XCTAssertNil(
            returningA.updates.value.pendingScroll, "Promotion must not reposition the viewport")
        XCTAssertTrue(source.queries.isEmpty, "A covered, certified tail needs no history request")
    }

    func testExpiredSyncTailStaysVisibleUntilRevocationFencesHeldReplacement() async throws {
        let (cache, local) = try await makeHistoryCache()
        let key = ConversationKey(chatID: "chat")
        let saved = try TimelineTestFixtures.message(id: 10, senderID: 2, at: 10)
        let late = try TimelineTestFixtures.message(id: 20, senderID: 2, at: 20)
        try await seedSyncTail([saved], for: key, at: "base", in: local)
        // Expiry drops the proof, not the saved rows.
        try await cache.resetSyncChat(chatID: key.chatID, cursor: "expired-head", purge: false)
        let source = ScriptedTimelineSource(timelinePages: [
            .success(
                TimelinePage(
                    response: .init(messages: [saved, late]), journalFloor: 0, at: "expired-head"))
        ])
        let model = ConversationTimelineModel(
            chatID: key.chatID, currentUserID: 1, isGroupChat: false,
            source: source, messageStore: source.store, historyCache: cache)
        defer { model.close() }
        let requested = expectation(description: "Expired tail requests one replacement")
        source.holdNextRequest { requested.fulfill() }
        let opening = Task { await model.open() }
        await fulfillment(of: [requested], timeout: 3)

        XCTAssertEqual(model.state.history, .saved)
        XCTAssertEqual(model.rows.compactMap(\.messageID), [saved.id])
        XCTAssertEqual(source.queries.count, 1)

        cache.revoke(key.chatID)
        model.invalidateCachedHistory()
        XCTAssertTrue(model.rows.isEmpty, "Revocation clears rows even while the page is held")
        source.release()
        await opening.value

        XCTAssertTrue(model.rows.isEmpty, "A late replacement cannot restore revoked rows")
        XCTAssertEqual(source.queries.count, 1)
        let persisted = try await cache.read { try await $0.cachedHistory(key) }
        XCTAssertTrue(persisted.messages.isEmpty)
    }

    func testSyncPageReplaysOnlyJournalEntriesAfterItsFloor() async throws {
        let pageText = try TimelineTestFixtures.message(id: 10, at: 10, text: "page state")
        let earlier = try TimelineTestFixtures.message(id: 10, at: 10, text: "at the floor")
        let pageOther = try TimelineTestFixtures.message(id: 20, at: 20, text: "as of page")
        let later = try TimelineTestFixtures.message(id: 20, at: 20, text: "after the floor")
        let floor: UInt64 = 1
        let source = ScriptedTimelineSource(timelinePages: [
            .success(
                TimelinePage(
                    response: .init(messages: [pageText, pageOther]), journalFloor: floor,
                    at: "page"))
        ])
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false,
            source: source, messageStore: source.store)
        defer { model.close() }
        source.holdNextRequest()
        let loading = Task { await model.open() }
        await source.waitUntilHeld()

        source.store.apply(.messageUpdated(earlier))
        XCTAssertEqual(source.store.receiveRevision, floor)
        source.store.apply(.messageUpdated(later))
        source.release()
        await loading.value

        XCTAssertEqual(remoteMessages(model).map(\.message), ["page state", "after the floor"])
    }

    func testDelayedCreateInsertsInIDOrderInsideHistoricalWindow() async throws {
        let first = try TimelineTestFixtures.message(id: 10, at: 10)
        let last = try TimelineTestFixtures.message(id: 20, at: 20)
        let delayed = try TimelineTestFixtures.message(id: 15, senderID: 2, at: 15, type: .audio)
        let beyond = try TimelineTestFixtures.message(id: 25, senderID: 2, at: 25)
        let (model, source, _) = try makeModel(pages: [
            .success(try TimelineTestFixtures.page([first, last], newerCursor: last.id))
        ])
        defer { model.close() }
        await model.open()
        XCTAssertFalse(model.isAtLiveEdge)

        source.store.apply(.message(delayed))
        source.store.apply(.message(delayed))
        source.store.apply(.message(beyond))

        XCTAssertEqual(model.rows.compactMap(\.messageID), [first.id, delayed.id, last.id])
        XCTAssertFalse(model.isAtLiveEdge)
        XCTAssertEqual(source.queries.count, 1)
    }

    func testSavedHistoryPagesWithinASectionAndRequiresExplicitGapNavigation() async throws {
        let (cache, local) = try await makeHistoryCache()
        let key = ConversationKey(chatID: "chat")
        let epoch = try await local.cacheEpoch()
        try await local.cacheHistory(
            key, query: .init(around: MessageID(8), max: 50),
            response: try historyPage(
                ids: 7...9, olderCursor: MessageID(7), newerCursor: MessageID(9)), epoch: epoch)
        try await local.cacheHistory(
            key, query: .init(max: 50),
            response: try historyPage(
                ids: 110...159, olderCursor: MessageID(110), newerCursor: nil),
            epoch: epoch)
        try await local.cacheHistory(
            key, query: .init(before: MessageID(110), max: 50),
            response: try historyPage(
                ids: 100...109, olderCursor: MessageID(100), newerCursor: nil),
            epoch: epoch)

        let source = ScriptedTimelineSource(pages: [])
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false,
            source: source, messageStore: source.store, historyCache: cache,
            canFetchHistory: { false })
        defer { model.close() }
        await model.open()
        XCTAssertEqual(model.state.history, .saved)
        XCTAssertEqual(model.state.historyConnection, .offline)
        XCTAssertEqual(remoteMessages(model).map(\.id), (110...159).map { MessageID(UInt64($0)) })
        XCTAssertFalse(model.isAtLiveEdge)
        XCTAssertEqual(model.state.olderSaved, .more)

        let contiguous = expectation(description: "contiguous saved page")
        let more = model.$rows.filter {
            $0.first(where: { $0.messageID != nil })?.messageID == MessageID(100)
        }
        .prefix(1).sink { _ in contiguous.fulfill() }
        model.browseSavedEdge(.older)
        await fulfillment(of: [contiguous], timeout: 3)
        more.cancel()
        XCTAssertEqual(model.state.olderSaved, .section)
        reportVisible([MessageID(100)], to: model, reason: .user, distanceToTop: 0)
        XCTAssertEqual(remoteMessages(model).first?.id, MessageID(100))

        let older = expectation(description: "older saved section")
        let section = model.$rows.filter { $0.contains(where: { $0.messageID == MessageID(7) }) }
            .prefix(1).sink { _ in older.fulfill() }
        model.browseSavedEdge(.older)
        await fulfillment(of: [older], timeout: 3)
        section.cancel()
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(7), MessageID(8), MessageID(9)])
        XCTAssertEqual(model.state.newerSaved, .section)
        XCTAssertTrue(source.queries.isEmpty)
    }

    func testDiskPressurePausesHistoryGrowthButDoesNotSkipRedaction() async throws {
        let (cache, local) = try await makeHistoryCache()
        let key = ConversationKey(chatID: "chat")
        let saved = try TimelineTestFixtures.message(id: 1, at: 1)
        let new = try TimelineTestFixtures.message(id: 2, at: 2)
        let epoch = try await local.cacheEpoch()
        try await local.cacheHistory(
            key, query: .init(max: 50), response: TimelineTestFixtures.page([saved]), epoch: epoch)

        cache.pauseForDiskFull()
        cache.accept(.message(new), fromSocket: true)
        cache.accept(.messageDeleted(saved.redactedForDeletion()), fromSocket: true)
        try await cache.read { store in
            let history = try await store.cachedHistory(key, position: .latest)
            XCTAssertTrue(
                history.messages.isEmpty,
                "The new row must not be cached and the deleted row must not survive")
        }
    }

    func testSocketPeerCreateAppearsOnlyAtSavedTailWithoutAdvancingReadsOrCoverage() async throws {
        let (cache, local) = try await makeHistoryCache()
        let key = ConversationKey(chatID: "chat")
        let epoch = try await local.cacheEpoch()
        try await local.cacheHistory(
            key, query: .init(around: MessageID(3), max: 50),
            response: try historyPage(ids: 2...3, newerCursor: MessageID(3)), epoch: epoch)
        try await local.cacheHistory(
            key, query: .init(max: 50),
            response: try historyPage(ids: 10...12, olderCursor: MessageID(10), newerCursor: nil),
            epoch: epoch)

        let source = ScriptedTimelineSource(pages: [])
        var reads: [MessageID] = []
        var online = false
        let latest = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false, source: source,
            messageStore: source.store, historyCache: cache, canFetchHistory: { online },
            markRead: { reads.append($0) })
        let historical = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false, source: source,
            messageStore: source.store, historyCache: cache, canFetchHistory: { false })
        defer {
            latest.close()
            historical.close()
        }
        await latest.open()
        await historical.open(position: .message(MessageID(11)))
        online = true  // HTTP is usable, but a saved baseline must not record a read.
        let anchor = historical.updates.value.pendingScroll
        latest.setReadTrackingActive(true)

        let peer = try TimelineTestFixtures.message(id: 14, senderID: 2, at: 14)
        source.store.apply(.message(peer))
        XCTAssertTrue(latest.updates.value.animateFollowing)
        source.store.apply(.message(peer))
        source.store.apply(.message(try TimelineTestFixtures.message(id: 9, senderID: 2, at: 9)))
        source.store.apply(.message(try TimelineTestFixtures.message(id: 15, senderID: 1, at: 15)))
        reportVisible([MessageID(12), MessageID(14)], to: latest, distanceToBottom: 0)
        await source.drain()

        XCTAssertEqual(remoteMessages(latest).map(\.id), [10, 11, 12, 14].map(MessageID.init))
        XCTAssertEqual(remoteMessages(historical).map(\.id), [10, 11, 12].map(MessageID.init))
        XCTAssertEqual(historical.updates.value.pendingScroll, anchor)
        XCTAssertEqual(latest.state.history, .saved)
        XCTAssertEqual(latest.state.olderSaved, .section)
        XCTAssertNil(latest.state.newerSaved)
        XCTAssertEqual(latest.state.live.pendingLiveCount, 0)
        XCTAssertFalse(latest.isAtLiveEdge)
        XCTAssertTrue(reads.isEmpty)
        XCTAssertTrue(source.queries.isEmpty)

        latest.userScrollBegan()
        source.store.apply(.message(try TimelineTestFixtures.message(id: 16, senderID: 2, at: 16)))
        XCTAssertEqual(remoteMessages(latest).map(\.id), [10, 11, 12, 14].map(MessageID.init))
    }

    func testSavedSocketTailReplaysEditsAndTombstonesOverStaleRefreshWithoutDuplicates()
        async throws
    {
        let (cache, local) = try await makeHistoryCache()
        let key = ConversationKey(chatID: "chat")
        let epoch = try await local.cacheEpoch()
        let baseline = try TimelineTestFixtures.message(id: 10, senderID: 2, at: 10)
        let removed = try TimelineTestFixtures.message(id: 13, senderID: 2, at: 13, text: "removed")
        let edited = try TimelineTestFixtures.message(id: 14, senderID: 2, at: 14, text: "stale")
        let fresh = try TimelineTestFixtures.message(id: 14, senderID: 2, at: 14, text: "edited")
        try await local.cacheHistory(
            key, query: .init(max: 50), response: TimelineTestFixtures.page([baseline]),
            epoch: epoch)
        let source = ScriptedTimelineSource(pages: [
            .success(try TimelineTestFixtures.page([baseline, removed, edited]))
        ])
        var online = false
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false, source: source,
            messageStore: source.store, historyCache: cache, canFetchHistory: { online })
        defer { model.close() }
        await model.open()
        online = true
        source.holdNextRequest()
        let recovering = Task { await model.resumeNetworkHistory() }
        await source.waitUntilHeld()

        source.store.apply(.message(removed))
        source.store.apply(.message(edited))
        XCTAssertEqual(remoteMessages(model).map(\.id), [10, 13, 14].map(MessageID.init))
        source.store.apply(.messageDeleted(removed.redactedForDeletion()))
        source.store.apply(.message(edited))
        source.store.apply(.messageUpdated(fresh))
        source.store.apply(.message(removed))
        XCTAssertEqual(remoteMessages(model).map(\.id), [10, 14].map(MessageID.init))
        XCTAssertEqual(remoteMessages(model).last?.message, "edited")
        source.release()
        await recovering.value

        XCTAssertEqual(model.state.history, .server)
        XCTAssertEqual(remoteMessages(model).map(\.id), [10, 14].map(MessageID.init))
        XCTAssertEqual(remoteMessages(model).last?.message, "edited")
        let saved = try await cache.read { try await $0.cachedHistory(key) }
        XCTAssertFalse(saved.messages.contains { $0.id == removed.id && !$0.isDeleted })
        XCTAssertEqual(saved.messages.first { $0.id == fresh.id }?.message, "edited")
    }

    func testSavedHistoryAutomaticRecoveryUsesCurrentAnchorAndStopsAfterThreeAttempts() async throws
    {
        let (cache, local) = try await makeHistoryCache()
        let epoch = try await local.cacheEpoch()
        try await local.cacheHistory(
            .init(chatID: "chat"), query: .init(max: 50), response: try livePage(ids: 10...12),
            epoch: epoch)
        let source = ScriptedTimelineSource(
            pages: Array(repeating: .failure(APIError.transport(URLError(.timedOut))), count: 4))
        let clock = SavedRefreshRetryClock()
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false, source: source,
            messageStore: source.store, historyCache: cache,
            sleepBeforeSavedRefreshRetry: { await clock.sleep($0) })
        defer {
            model.close()
            clock.wake()
        }
        model.setReadTrackingActive(true)
        await model.open()
        model.userScrollBegan()
        reportVisible([MessageID(11)], to: model, reason: .user)

        for (index, delay) in [Duration.seconds(1), .seconds(2), .seconds(4)].enumerated() {
            await clock.waitForSleep()
            XCTAssertEqual(clock.delays.last, delay)
            XCTAssertEqual(remoteMessages(model).map(\.id), [10, 11, 12].map(MessageID.init))
            source.holdNextRequest()
            clock.wake()
            await source.waitUntilHeld()
            XCTAssertEqual(source.queries.count, index + 2)
            XCTAssertEqual(source.queries.last?.around, MessageID(11))
            let reconnecting = Task { await model.resumeNetworkHistory() }
            await source.drain()
            XCTAssertEqual(source.queries.count, index + 2)
            source.release()
            await reconnecting.value
        }
        await source.drain()
        XCTAssertEqual(source.queries.count, 4)
        XCTAssertEqual(clock.delays, [.seconds(1), .seconds(2), .seconds(4)])
        XCTAssertEqual(model.state.history, .saved)
        XCTAssertTrue(model.state.reconciliationFailed)
    }

    func testSavedHistoryAutomaticRecoveryPausesForPathAndVisibilityAndCancelsOnClose() async throws
    {
        let (cache, local) = try await makeHistoryCache()
        let epoch = try await local.cacheEpoch()
        try await local.cacheHistory(
            .init(chatID: "chat"), query: .init(max: 50), response: try livePage(ids: 10...12),
            epoch: epoch)
        let source = ScriptedTimelineSource(pages: [
            .failure(APIError.unavailable), .success(try livePage(ids: 13...13)),
        ])
        let clock = SavedRefreshRetryClock()
        var online = true
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false, source: source,
            messageStore: source.store, historyCache: cache, canFetchHistory: { online },
            sleepBeforeSavedRefreshRetry: { await clock.sleep($0) })
        defer {
            model.close()
            clock.wake()
        }
        model.setReadTrackingActive(true)
        await model.open()
        await clock.waitForSleep()

        online = false
        model.historyPathChanged()
        clock.wake()
        await source.drain()
        XCTAssertEqual(model.state.historyConnection, .offline)
        XCTAssertEqual(source.queries.count, 1)

        online = true
        model.historyPathChanged()
        await clock.waitForSleep()
        model.setReadTrackingActive(false)
        clock.wake()
        await source.drain()
        XCTAssertEqual(source.queries.count, 1)

        model.setReadTrackingActive(true)
        await clock.waitForSleep()
        source.holdNextRequest()
        clock.wake()
        await source.waitUntilHeld()
        let joining = Task { await model.resumeNetworkHistory() }
        await source.drain()
        model.setReadTrackingActive(false)
        source.release()
        await joining.value
        XCTAssertEqual(model.state.history, .saved)
        XCTAssertEqual(remoteMessages(model).map(\.id), [10, 11, 12].map(MessageID.init))

        model.setReadTrackingActive(true)
        await clock.waitForSleep()
        model.close()
        clock.wake()
        await source.drain()
        XCTAssertEqual(source.queries.count, 2)
        XCTAssertEqual(clock.delays, [.seconds(1), .seconds(1), .seconds(1), .seconds(2)])
    }

    func testReconnectRepairsSavedAnchorAndReplaysOnlyDurableEventsIntoCache() async throws {
        let (cache, local) = try await makeHistoryCache()
        let key = ConversationKey(chatID: "chat")
        let baseline = try livePage(ids: 10...12)
        let epoch = try await local.cacheEpoch()
        try await local.cacheHistory(
            key, query: .init(max: 50), response: baseline, epoch: epoch)
        let source = ScriptedTimelineSource(pages: [.success(baseline)])
        var online = false
        var read: [MessageID] = []
        var receipts = 0
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false,
            source: source, messageStore: source.store, historyCache: cache,
            canFetchHistory: { online }, markRead: { read.append($0) },
            fetchReadReceipt: { _ in
                receipts += 1
                return nil
            })
        defer { model.close() }
        await model.open()
        model.setReadTrackingActive(true)
        model.userScrollBegan()
        reportVisible([MessageID(11)], to: model, reason: .user)
        await source.drain()
        XCTAssertTrue(read.isEmpty)
        XCTAssertEqual(receipts, 0)
        XCTAssertTrue(source.queries.isEmpty)

        online = true
        source.holdNextRequest()
        let recovering = Task { await model.resumeNetworkHistory() }
        await source.waitUntilHeld()
        XCTAssertEqual(source.queries.last?.around, MessageID(11))
        XCTAssertEqual(model.state.history, .saved)
        XCTAssertEqual(remoteMessages(model).count, 3)
        model.userScrollBegan()
        reportVisible([MessageID(12)], to: model, reason: .user)
        XCTAssertTrue(read.isEmpty)
        let durable = try TimelineTestFixtures.message(id: 11, senderID: 2, at: 11, text: "durable")
        let optimistic = try TimelineTestFixtures.message(
            id: 11, senderID: 2, at: 11, text: "optimistic")
        source.store.apply(.messageUpdated(durable))
        source.store.apply(.messageUpdated(optimistic), persistent: false)
        source.release()
        await recovering.value
        XCTAssertEqual(model.state.history, .server)
        XCTAssertNil(model.updates.value.pendingScroll, "The native host keeps the row's offset")
        XCTAssertEqual(
            remoteMessages(model).first { $0.id == MessageID(11) }?.message, "optimistic")
        let saved = try await cache.read { try await $0.cachedHistory(key) }
        XCTAssertEqual(saved.messages.first { $0.id == MessageID(11) }?.message, "durable")
    }

    func testMissingDirectedMessageAndClearKeepPendingWithoutRepopulatingOldHistory() async throws {
        let (cache, local) = try await makeHistoryCache()
        let key = ConversationKey(chatID: "chat")
        let epoch = try await local.cacheEpoch()
        try await local.cacheHistory(
            key, query: .init(max: 50), response: .init(messages: []), epoch: epoch)
        let source = ScriptedTimelineSource(pages: [.success(try livePage(ids: 90...90))])
        var online = false
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false,
            source: source, messageStore: source.store, historyCache: cache,
            canFetchHistory: { online })
        defer { model.close() }
        cache.onClear = { [weak model] in model?.invalidateCachedHistory() }
        source.store.replacePending(chatID: "chat", with: [pending(id: "offline")])
        await model.open(position: .message(MessageID(90)))
        XCTAssertEqual(model.state.history, .verifiedEmpty)
        XCTAssertEqual(model.state.missingOfflineMessage, MessageID(90))
        XCTAssertEqual(model.rows.compactMap(\.stableMessageKey).count, 1)
        XCTAssertFalse(model.isAtLiveEdge)

        online = true
        source.holdNextRequest()
        let recovering = Task { await model.resumeNetworkHistory() }
        await source.waitUntilHeld()
        try await cache.clear()
        source.release()
        await recovering.value
        XCTAssertEqual(model.state.history, .notDownloaded)
        XCTAssertTrue(remoteMessages(model).isEmpty)
        XCTAssertEqual(model.rows.compactMap(\.stableMessageKey).count, 1)
        let saved = try await cache.read { try await $0.cachedHistory(key) }
        XCTAssertTrue(saved.messages.isEmpty)
        XCTAssertNil(saved.context)
    }

    func testManualHistoryRetryWhilePathIsStaleKeepsSavedRowsAndRecordsOnlyServerVisibility()
        async throws
    {
        let (cache, local) = try await makeHistoryCache()
        let key = ConversationKey(chatID: "chat")
        let epoch = try await local.cacheEpoch()
        try await local.cacheHistory(
            key, query: .init(max: 50), response: try livePage(ids: 10...12), epoch: epoch)
        let source = ScriptedTimelineSource(pages: [
            .failure(APIError.unavailable), .success(try livePage(ids: 10...13)),
        ])
        let recorded = expectation(description: "visible server row recorded despite stale path")
        var authorized = false
        var validationRetries = 0
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false, source: source,
            messageStore: source.store,
            historyCache: cache, canFetchHistory: { false },
            canRetryHistory: {
                if !authorized { validationRetries += 1 }
                return authorized
            },
            markRead: { id in
                try await local.recordPendingRead(key, base: nil, target: id)
                recorded.fulfill()
            })
        defer { model.close() }
        await model.open()
        model.setReadTrackingActive(true)
        reportVisible([MessageID(12)], to: model)
        let before = try await local.pendingRead(key)
        XCTAssertNil(before)

        await model.retryNetworkHistory()
        XCTAssertEqual(validationRetries, 1)
        XCTAssertTrue(source.queries.isEmpty)
        authorized = true
        await model.retryNetworkHistory()
        XCTAssertEqual(model.state.history, .saved)
        XCTAssertEqual(
            remoteMessages(model).map(\.id), [MessageID(10), MessageID(11), MessageID(12)])
        XCTAssertTrue(model.state.reconciliationFailed)

        await model.retryNetworkHistory()
        XCTAssertEqual(source.queries.count, 2)
        XCTAssertEqual(model.state.history, .server)
        reportVisible([MessageID(12)], to: model)
        await fulfillment(of: [recorded], timeout: 3)
        let pending = try await local.pendingRead(key)
        XCTAssertEqual(pending?.target, MessageID(12))
    }

    func testRangeKeepsDirectionOnSmallReversalAndUsesFreshVisibleMessages() async throws {
        let messages = try (100...109).map { id in
            try TimelineTestFixtures.message(
                id: UInt64(id), at: id - 100, type: id == 108 ? .system : .text)
        }
        let (model, _, _) = try makeModel(pages: [
            .success(try TimelineTestFixtures.page(messages))
        ])
        defer { model.close() }
        await model.open()

        func report(
            _ top: CGFloat, _ ids: ClosedRange<UInt64>, reason: TimelineViewportChangeReason
        ) {
            reportVisible(
                ids.map(MessageID.init), to: model, reason: reason,
                distanceToBottom: 700 - top, distanceToTop: top)
        }

        report(250, 103...106, reason: .layout)
        let selection = [messages[4].id: messages[4], messages[6].id: messages[6]]
        model.updateSelectionRange(active: true, ids: selection.keys, busy: false)
        XCTAssertNil(model.selectionRange.offer)

        report(360, 103...107, reason: .user)
        XCTAssertEqual(model.selectionRange.offer?.direction, .newer)
        XCTAssertEqual(model.selectionRange.offer?.count, 1)
        report(340, 103...107, reason: .user)
        XCTAssertEqual(model.selectionRange.offer?.direction, .newer)
        report(295, 102...107, reason: .layout)
        XCTAssertEqual(model.selectionRange.offer?.direction, .newer)
        report(295, 102...107, reason: .user)
        XCTAssertEqual(model.selectionRange.offer?.direction, .older)
        XCTAssertEqual(model.selectionRange.offer?.count, 2)

        let older = model.selectionRangeMessages(
            toward: .older, visibleIDs: (101...105).map(MessageID.init))
        XCTAssertEqual(older?.map(\.id), (101...103).map(MessageID.init))
        XCTAssertNil(model.selectionRange.offer)

        report(500, 107...109, reason: .user)
        let newer = model.selectionRangeMessages(
            toward: .newer, visibleIDs: [MessageID(108), MessageID(109)])
        XCTAssertEqual(newer?.map(\.id), [MessageID(107), MessageID(109)])
    }

    func testRangeRejectsWholeExtensionWhenViewportGrowsPastLimitBeforeTap() async throws {
        let (model, _, _) = try makeModel(pages: [.success(try livePage(ids: 1...101))])
        defer { model.close() }
        await model.open()

        reportVisible(
            [MessageID(98), MessageID(99)], to: model, distanceToBottom: 500, distanceToTop: 200)
        let selection = Dictionary(
            uniqueKeysWithValues: remoteMessages(model).prefix(99).map { ($0.id, $0) })
        model.updateSelectionRange(active: true, ids: selection.keys, busy: false)
        reportVisible(
            [MessageID(100)], to: model, reason: .user, distanceToBottom: 400,
            distanceToTop: 300)
        XCTAssertEqual(model.selectionRange.offer?.exceedsLimit, false)

        XCTAssertNil(
            model.selectionRangeMessages(
                toward: .newer, visibleIDs: [MessageID(100), MessageID(101)]))
        XCTAssertEqual(model.selectionRange.offer?.exceedsLimit, true)
        XCTAssertEqual(model.selectionRange.offer?.remaining, 1)

        reportVisible(
            [MessageID(100)], to: model, reason: .user, distanceToBottom: 420,
            distanceToTop: 280)
        XCTAssertEqual(model.selectionRange.offer?.exceedsLimit, false)
        XCTAssertEqual(
            model.selectionRangeMessages(toward: .newer, visibleIDs: [MessageID(100)])?.map(\.id),
            [MessageID(100)])
        XCTAssertNil(model.selectionRange.offer)
    }

    func testPendingReplyKeepsStableIdentityAlongsideRootAndOtherSenderWithSameClientID()
        async throws
    {
        let root = try TimelineTestFixtures.message(
            id: 1, at: 1, text: "root", clientGeneratedID: "shared")
        let otherSender = try TimelineTestFixtures.message(
            id: 2, senderID: 2, at: 2, text: "other sender", clientGeneratedID: "shared",
            fields: ["replyRootId": "1"])
        let delivered = try TimelineTestFixtures.message(
            id: 3, at: 3, text: "server copy", clientGeneratedID: "shared",
            fields: ["replyRootId": "1"])
        let source = ScriptedTimelineSource(pages: [
            .success(try TimelineTestFixtures.page([root])),
            .success(try TimelineTestFixtures.page([delivered, otherSender, root])),
        ])
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false,
            source: source, messageStore: source.store, threadID: "1")
        defer { model.close() }
        await model.open()
        var pending = TimelineTestFixtures.pending(
            id: "shared", text: "local copy", phase: .sending)
        pending.threadID = "1"
        source.store.replacePending(chatID: "chat", threadID: "1", with: [pending])
        source.store.apply(.message(otherSender))

        let keys = [
            root.timelineStableKey, otherSender.timelineStableKey, delivered.timelineStableKey,
        ]
        XCTAssertEqual(Set(keys).count, 3)
        XCTAssertEqual(model.rows.compactMap(\.stableMessageKey), keys)
        XCTAssertEqual(remoteMessages(model).map(\.message), ["root", "other sender"])
        XCTAssertEqual(source.store.pending(chatID: "chat", threadID: "1"), [pending])

        source.store.replacePending(
            chatID: "chat", threadID: "1", with: [], acknowledging: delivered)
        XCTAssertEqual(model.rows.compactMap(\.stableMessageKey), keys)
        XCTAssertEqual(
            remoteMessages(model).map(\.message), ["root", "other sender", "server copy"])
        await model.reconcileAfterReconnect()
        XCTAssertEqual(model.rows.compactMap(\.stableMessageKey), keys)
    }

    func testDeletedAcknowledgementCannotBeResurrectedByLateOrdinaryIngress() async throws {
        let stale = try TimelineTestFixtures.message(
            id: 1, at: 1, text: "private copy", clientGeneratedID: "send")
        let (model, source, _) = try makeModel(pages: [
            .success(try TimelineTestFixtures.page([])),
            .success(try TimelineTestFixtures.page([stale])),
        ])
        defer { model.close() }
        await model.open()
        source.store.replacePending(chatID: "chat", with: [pending(id: "send")])
        source.store.replacePending(
            chatID: "chat", with: [], acknowledging: stale.redactedForDeletion())
        XCTAssertTrue(model.rows.isEmpty)
        source.store.apply(.message(stale))
        source.store.apply(.messageUpdated(stale))
        await model.reconcileAfterReconnect()
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testPendingPreviewExpiresLocallyAndFullUpdateRestoresReadyWithoutEditing() async throws {
        let deadline = Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970) + 1)
        let formatter = ISO8601DateFormatter()
        let pending = try TimelineTestFixtures.message(
            id: 1, at: 1, text: "https://example.com/article",
            fields: [
                "metadata": [
                    "linkPreviews": [
                        [
                            "url": "https://example.com/article", "status": "pending",
                            "expiresAt": formatter.string(from: deadline),
                        ]
                    ]
                ]
            ])
        let source = ScriptedTimelineSource(pages: [
            .success(try TimelineTestFixtures.page([pending]))
        ])
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: true,
            source: source, messageStore: source.store)
        defer { model.close() }
        await model.open()
        XCTAssertEqual(remoteMessages(model).first?.metadata?.linkPreviews.first?.status, .pending)
        let expired = expectation(description: "Pending card expires without a network request")
        var fulfilled = false
        let observation = model.updates.sink { snapshot in
            guard !fulfilled,
                snapshot.rows.contains(where: {
                    guard case .message(let row) = $0 else { return false }
                    return row.entry.remoteMessage?.metadata?.linkPreviews.first?.status
                        == .unavailable
                })
            else { return }
            fulfilled = true
            expired.fulfill()
        }
        defer { observation.cancel() }
        await fulfillment(of: [expired], timeout: 4)
        XCTAssertEqual(source.queries.count, 1)
        let ready = try TimelineTestFixtures.message(
            id: 1, at: 1, text: "https://example.com/article",
            fields: [
                "metadata": [
                    "linkPreviews": [
                        [
                            "url": "https://example.com/article", "status": "ready",
                            "title": "Article",
                        ]
                    ]
                ]
            ])
        source.store.apply(.messageUpdated(ready))
        XCTAssertEqual(remoteMessages(model).first?.metadata?.linkPreviews.first?.title, "Article")
        XCTAssertEqual(remoteMessages(model).first?.isEdited, false)
    }

    func testRevokedReceiptCannotBeRestoredByLateResponse() async throws {
        let source = ScriptedTimelineSource(pages: [.success(try livePage(ids: 1...2))])
        var release: CheckedContinuation<MessageID?, Never>?
        var revoked = false
        let started = expectation(description: "Original receipt request suspended")
        let denied = expectation(description: "Privacy refresh denied")
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false, source: source,
            messageStore: source.store,
            fetchReadReceipt: { _ in
                if revoked {
                    denied.fulfill()
                    return nil
                }
                return await withCheckedContinuation {
                    release = $0
                    started.fulfill()
                }
            })
        await model.open()
        model.setReadTrackingActive(true)
        await fulfillment(of: [started], timeout: 2)
        revoked = true
        model.refreshReadReceipt(clear: true)
        await fulfillment(of: [denied], timeout: 2)
        release?.resume(returning: MessageID(2))
        await source.drain()
        XCTAssertFalse(
            model.rows.contains {
                if case .message(let row) = $0 { return row.isRead }
                return false
            })
        model.close()
    }

    func testThreadReceiptsUseSeparateRootCursorAndRevokeOnPrivacyChange() async throws {
        let messages = [
            try TimelineTestFixtures.message(id: 10, at: 1),
            try TimelineTestFixtures.message(id: 11, at: 2, fields: ["replyRootId": "10"]),
            try TimelineTestFixtures.message(id: 12, at: 3, fields: ["replyRootId": "10"]),
            try TimelineTestFixtures.message(
                id: 13, senderID: 2, at: 4, fields: ["replyRootId": "10"]),
            try TimelineTestFixtures.message(id: 14, at: 5, fields: ["replyRootId": "10"]),
        ]
        let source = ScriptedTimelineSource(pages: [
            .success(try TimelineTestFixtures.page(messages))
        ])
        var hidden = false
        var failedRequests: XCTestExpectation?
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false, source: source,
            messageStore: source.store, threadID: "10",
            fetchReadReceipt: { threadID in
                if hidden {
                    failedRequests?.fulfill()
                    throw StubError()
                }
                return MessageID(threadID == nil ? 9 : 13)
            })
        await model.open()
        let received = expectation(description: "Thread receipt published")
        model.updates.first { snapshot in
            snapshot.rows.contains {
                if case .message(let row) = $0 { return row.isRead }
                return false
            }
        }.sink { _ in received.fulfill() }.store(in: &cancellables)
        model.setReadTrackingActive(true)
        await fulfillment(of: [received], timeout: 2)
        let readIDs = model.rows.compactMap { row -> MessageID? in
            guard case .message(let message) = row, message.isRead else { return nil }
            return message.entry.serverID
        }
        XCTAssertEqual(readIDs, [MessageID(11), MessageID(12)])

        hidden = true
        let ordinaryFailure = expectation(description: "Both refresh requests fail")
        ordinaryFailure.expectedFulfillmentCount = 2
        failedRequests = ordinaryFailure
        model.refreshReadReceipt()
        await fulfillment(of: [ordinaryFailure], timeout: 2)
        XCTAssertTrue(
            model.rows.contains {
                if case .message(let row) = $0 { return row.isRead }
                return false
            })
        let privacyFailure = expectation(description: "Both privacy refresh requests fail")
        privacyFailure.expectedFulfillmentCount = 2
        failedRequests = privacyFailure
        model.refreshReadReceipt(clear: true)
        XCTAssertFalse(
            model.rows.contains {
                if case .message(let row) = $0 { return row.isRead }
                return false
            })
        await fulfillment(of: [privacyFailure], timeout: 2)
        XCTAssertFalse(
            model.rows.contains {
                if case .message(let row) = $0 { return row.isRead }
                return false
            })
        model.close()
    }

    func testReplyJumpReusesLoadedTargetAndLoadsMissingHistory() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try livePage(ids: 10...12)),
            .success(try historyPage(ids: 1...3, newerCursor: MessageID(3))),
        ])
        await model.open()
        await model.jumpToMessage(MessageID(11))
        XCTAssertEqual(source.queries.count, 1)
        XCTAssertFalse(model.state.live.followsLatest)
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent,
            .reveal(
                .message(TimelineTestFixtures.stableKey("client-11", senderID: 2)),
                animated: true, highlight: true))
        await model.jumpToMessage(MessageID(2))
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1), MessageID(2), MessageID(3)])
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent,
            .reveal(
                .message(TimelineTestFixtures.stableKey("client-2")), animated: false,
                highlight: true))
    }

    func testFailedReplyJumpKeepsHistoryAndCanBeRetried() async throws {
        let (model, _, _) = try makeModel(pages: [
            .success(try livePage(ids: 10...12)), .failure(StubError()),
            .success(try historyPage(ids: 1...3, newerCursor: MessageID(3))),
        ])
        await model.open()
        await model.jumpToMessage(MessageID(2))
        XCTAssertEqual(model.state.content, .ready)
        XCTAssertEqual(model.state.repositionFailure, .message(MessageID(2)))
        XCTAssertEqual(
            remoteMessages(model).map(\.id), [MessageID(10), MessageID(11), MessageID(12)])
        await model.jumpToMessage(MessageID(2))
        XCTAssertNil(model.state.repositionFailure)
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1), MessageID(2), MessageID(3)])
    }

    func testLoadedReplyJumpSupersedesAnInFlightHistoryJump() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try livePage(ids: 10...12)),
            .success(try historyPage(ids: 1...3, newerCursor: MessageID(3))),
        ])
        await model.open()
        source.holdNextRequest()
        let oldJump = Task { await model.jumpToMessage(MessageID(2)) }
        await source.waitUntilHeld()
        await model.jumpToMessage(MessageID(11))
        source.release()
        let superseded = await oldJump.value
        XCTAssertEqual(superseded, .failed)
        XCTAssertEqual(model.state.content, .ready)
        XCTAssertEqual(
            remoteMessages(model).map(\.id), [MessageID(10), MessageID(11), MessageID(12)])
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent,
            .reveal(
                .message(TimelineTestFixtures.stableKey("client-11", senderID: 2)),
                animated: true, highlight: true))
    }

    func testInitialLoadPublishesBottomResetWithRemoteRows() async throws {
        let (model, _, updates) = try makeModel(pages: [.success(try livePage(ids: 1...2))])

        await model.loadInitial()

        XCTAssertEqual(model.state.content, .ready)
        XCTAssertTrue(model.isAtLiveEdge)
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(1), MessageID(2)])
        XCTAssertEqual(updates.value.last?.pendingScroll?.intent, .bottom(animated: false))
    }

    func testInitialLoadFailureIsRetryable() async throws {
        let (model, _, _) = try makeModel(pages: [
            .failure(StubError()), .success(try livePage(ids: 1...1)),
        ])

        await model.loadInitial()
        XCTAssertEqual(model.state.content, .initialLoadFailed)

        await model.retryInitial()
        XCTAssertEqual(model.state.content, .ready)
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(1)])
    }

    func testRestoredFailedRowsRemainVisibleWhileInitialHistoryLoadsAndFails() async throws {
        let source = ScriptedTimelineSource(pages: [.failure(StubError())])
        var failed = pending(id: "restored")
        failed.phase = .failed(
            .init(stage: .create, reason: .unknownOutcome, retry: .automatic), nextRetry: nil)
        source.store.replacePending(chatID: "chat", with: [failed])
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: true, source: source,
            messageStore: source.store)
        let restoredKey = TimelineTestFixtures.stableKey("restored")
        XCTAssertEqual(model.rows.compactMap(\.stableMessageKey), [restoredKey])
        source.holdNextRequest()
        let loading = Task { await model.open() }
        await source.waitUntilHeld()
        XCTAssertEqual(model.state.content, .loadingInitial)
        XCTAssertEqual(model.rows.compactMap(\.stableMessageKey), [restoredKey])

        source.release()
        await loading.value

        XCTAssertEqual(model.state.content, .initialLoadFailed)
        let entries = model.rows.compactMap { row -> ConversationTimelineEntry? in
            guard case .message(let message) = row else { return nil }
            return message.entry
        }
        XCTAssertEqual(entries.map(\.stableKey), [restoredKey])
        XCTAssertEqual(entries.map(\.displayState), [.failed])
        source.store.replacePending(chatID: "chat", with: [failed, pending(id: "new")])
        XCTAssertEqual(
            Set(model.rows.compactMap(\.stableMessageKey)),
            [restoredKey, TimelineTestFixtures.stableKey("new")])
    }

    func testAtomicAcknowledgementDuringInitialLoadingSurvivesFailureAndRetry() async throws {
        let acknowledged = try TimelineTestFixtures.message(
            id: 1, at: 1, clientGeneratedID: "send")
        let (model, source, _) = try makeModel(pages: [
            .failure(StubError()), .success(try TimelineTestFixtures.page([acknowledged])),
        ])
        source.store.replacePending(chatID: "chat", with: [pending(id: "send")])
        source.holdNextRequest()
        let loading = Task { await model.open() }
        await source.waitUntilHeld()
        var visibleKeys: [[ConversationMessageStableKey]] = []
        let observation = model.updates.sink {
            visibleKeys.append($0.rows.compactMap(\.stableMessageKey))
        }
        defer { observation.cancel() }

        source.store.replacePending(chatID: "chat", with: [], acknowledging: acknowledged)
        XCTAssertEqual(model.state.content, .loadingInitial)
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1)])
        source.store.apply(
            .message(try TimelineTestFixtures.message(id: 2, senderID: 2, at: 2)))
        XCTAssertEqual(
            remoteMessages(model).map(\.id), [MessageID(1)],
            "Only matched acknowledgements are exposed before history succeeds")
        source.release()
        await loading.value
        XCTAssertEqual(model.state.content, .initialLoadFailed)
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1)])

        source.holdNextRequest()
        let retrying = Task { await model.retryInitial() }
        await source.waitUntilHeld()
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1)])
        source.release()
        await retrying.value
        XCTAssertEqual(
            model.rows.filter { $0.stableMessageKey == acknowledged.timelineStableKey }.count, 1)
        XCTAssertTrue(
            visibleKeys.allSatisfy { $0.filter { $0 == acknowledged.timelineStableKey }.count == 1 }
        )
    }

    func testAcknowledgementAfterInitialFailureRemainsDeliveredUntilSnapshot() async throws {
        let acknowledged = try TimelineTestFixtures.message(
            id: 1, at: 1, clientGeneratedID: "send")
        let (model, source, _) = try makeModel(pages: [
            .failure(StubError()), .success(try TimelineTestFixtures.page([acknowledged])),
        ])
        source.store.replacePending(chatID: "chat", with: [pending(id: "send")])
        await model.open()
        source.store.replacePending(chatID: "chat", with: [], acknowledging: acknowledged)
        source.store.replacePending(chatID: "chat", with: [])
        XCTAssertEqual(model.state.content, .initialLoadFailed)
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1)])
        await model.retryInitial()
        XCTAssertEqual(model.rows.compactMap(\.stableMessageKey), [acknowledged.timelineStableKey])
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1)])
    }

    func testRevealAfterDurableEnqueueReusesNearbyLiveWindowWithoutWritingAgain() async throws {
        let (model, source, _) = try makeModel(pages: [.success(try livePage(ids: 1...2))])
        await model.open()
        model.userScrollBegan()
        model.viewportDidChange(
            .init(
                firstVisibleIndex: 0, lastVisibleIndex: model.rows.count - 1, distanceToTop: 5_000,
                distanceToBottom: 100, height: 400), reason: .user,
            revision: model.updates.value.revision)
        source.store.replacePending(chatID: "chat", with: [pending(id: "send")])

        model.revealLatestAfterSend()

        XCTAssertEqual(source.queries.count, 1)
        XCTAssertEqual(
            model.rows.filter { $0.stableMessageKey == TimelineTestFixtures.stableKey("send") }
                .count, 1)
        XCTAssertEqual(model.updates.value.pendingScroll?.intent, .bottom(animated: false))
        XCTAssertFalse(model.updates.value.animateFollowing)
        XCTAssertTrue(model.state.live.followsLatest)
    }

    func testScheduledRevealAfterSendDoesNotWaitForLiveEdgeFetch() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            .success(try livePage(ids: 1...3)),
        ])
        await model.loadInitial()
        XCTAssertFalse(model.isAtLiveEdge)
        source.holdNextRequest()

        model.revealLatestAfterSend()
        await source.waitUntilHeld()

        XCTAssertEqual(source.queries.count, 2)
        XCTAssertEqual(model.state.content, .repositioning(.liveEdge))
        source.release()
        await source.drain()
        XCTAssertEqual(model.state.content, .ready)
    }

    func testLiveMessageOffLiveEdgeIsDeferredAndMakesJumpAvailable() async throws {
        let (model, source, updates) = try makeModel(pages: [
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2)))
        ])
        await model.loadInitial()
        XCTAssertFalse(model.isAtLiveEdge)
        let updatesBefore = updates.value.count

        source.store.apply(.message(try TimelineTestFixtures.message(id: 3, senderID: 2, at: 3)))

        XCTAssertTrue(model.showsJumpToLatest)
        XCTAssertEqual(
            model.rows.compactMap(\.messageID), [MessageID(1), MessageID(2)],
            "history view must not render the deferred message")
        XCTAssertEqual(
            updates.value.count, updatesBefore,
            "A deferred arrival does not republish timeline rows.")
    }

    func testLiveMessageAtPinnedLiveEdgeAppendsAndFollows() async throws {
        let (model, source, updates) = try makeModel(pages: [.success(try livePage(ids: 1...1))])
        await model.loadInitial()

        source.store.apply(.message(try TimelineTestFixtures.message(id: 2, senderID: 2, at: 2)))

        XCTAssertFalse(model.showsJumpToLatest)
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(1), MessageID(2)])
        XCTAssertTrue(updates.value.last?.animateFollowing == true)
    }

    func testLiveMessageAtUnpinnedLiveEdgeRendersWithoutFollowing() async throws {
        let (model, source, updates) = try makeModel(pages: [.success(try livePage(ids: 1...1))])
        await model.loadInitial()
        model.scrollRequestDidFinish(id: model.updates.value.pendingScroll!.id)
        model.userScrollBegan()
        model.viewportDidChange(
            .init(
                firstVisibleIndex: 0, lastVisibleIndex: 0, distanceToTop: 0, distanceToBottom: 500,
                height: 400), reason: .user, revision: model.updates.value.revision)
        XCTAssertFalse(model.state.live.isPinnedToBottom)
        XCTAssertTrue(model.showsJumpToLatest, "Moving away from the bottom reveals the shortcut.")

        source.store.apply(.message(try TimelineTestFixtures.message(id: 2, senderID: 2, at: 2)))

        XCTAssertFalse(updates.value.last?.animateFollowing == true)
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(1), MessageID(2)])
        XCTAssertNil(updates.value.last?.pendingScroll)
    }

    func testPinnedViewportDoesNotClearUnreadBeforeServerConfirmation() async throws {
        let (model, source, _) = try makeModel(pages: [.success(try livePage(ids: 1...1))])
        await model.loadInitial()
        model.updateReadState(unreadCount: 1, lastReadMessageID: MessageID(1))
        model.scrollRequestDidFinish(id: model.updates.value.pendingScroll!.id)
        model.userScrollBegan()
        model.viewportDidChange(
            .init(
                firstVisibleIndex: 0, lastVisibleIndex: 0, distanceToTop: 0, distanceToBottom: 500,
                height: 400), reason: .user, revision: model.updates.value.revision)
        source.store.apply(.message(try TimelineTestFixtures.message(id: 2, senderID: 2, at: 2)))
        XCTAssertEqual(model.jumpUnreadCount, 1)

        model.viewportDidChange(
            .init(
                firstVisibleIndex: 0, lastVisibleIndex: 1, distanceToTop: 0, distanceToBottom: 0,
                height: 400), reason: .user, revision: model.updates.value.revision)

        XCTAssertTrue(model.state.live.isPinnedToBottom)
        XCTAssertFalse(
            model.showsJumpToLatest, "A stale unread count cannot keep the shortcut on screen.")
        XCTAssertEqual(
            model.jumpUnreadCount, 1,
            "Reaching bottom alone cannot clear authoritative unread state.")
    }

    func testJumpToLiveEdgeFromHistoryReplaysDeferredArrivalNewerThanServerPage() async throws {
        let (model, source, updates) = try makeModel(pages: [
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            .success(try livePage(ids: 98...99)),
        ])
        await model.loadInitial()
        // Newer than the server page's newest ID (99) and absent from that page.
        source.store.apply(
            .message(try TimelineTestFixtures.message(id: 100, senderID: 2, at: 40, minute: 1)))
        XCTAssertTrue(model.showsJumpToLatest)

        await model.jumpToLiveEdge()

        XCTAssertEqual(model.state.content, .ready)
        XCTAssertNil(model.state.repositionFailure)
        XCTAssertTrue(model.isAtLiveEdge)
        XCTAssertTrue(model.state.live.followsLatest)
        XCTAssertNil(source.queries.last?.after)
        XCTAssertNil(source.queries.last?.before)
        XCTAssertEqual(
            model.rows.compactMap(\.messageID), [MessageID(98), MessageID(99), MessageID(100)])
        XCTAssertEqual(updates.value.last?.pendingScroll?.intent, .bottom(animated: false))
    }

    func testJumpToLiveEdgeDropsDeferredArrivalOlderThanNewWindow() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            .success(try livePage(ids: 98...99)),
        ])
        await model.loadInitial()
        // Older than ID 98: replaying it would render above a history gap.
        source.store.apply(.message(try TimelineTestFixtures.message(id: 3, senderID: 2, at: 3)))

        await model.jumpToLiveEdge()

        XCTAssertEqual(
            model.rows.compactMap(\.messageID), [MessageID(98), MessageID(99)],
            "stale deferred entry must not be injected above the gap")
    }

    func testInitialOpenUsesHTTPRatherThanEventsFromAPriorScreen() async throws {
        let (model, source, _) = try makeModel(pages: [.success(try livePage(ids: 98...99))])
        source.store.apply(.message(try TimelineTestFixtures.message(id: 100, at: 40, minute: 1)))
        await model.open()
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(98), MessageID(99)])
    }

    func testLatestSnapshotReconcilesDeferredCreatesByIdentityAndRetainsEqualTimeArrivals()
        async throws
    {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            .success(try livePage(ids: 98...99)),
        ])
        await model.loadInitial()
        source.store.apply(
            .message(try TimelineTestFixtures.message(id: 99, senderID: 2, at: 39, minute: 1)))
        source.store.apply(
            .message(try TimelineTestFixtures.message(id: 100, senderID: 2, at: 39, minute: 1)))
        await model.jumpToLiveEdge()
        XCTAssertEqual(
            model.rows.compactMap(\.messageID), [MessageID(98), MessageID(99), MessageID(100)])
    }

    func testJumpToLiveEdgeFailureIsAnOverlayThatKeepsPagingAlive() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(
                try historyPage(
                    ids: 10...11, olderCursor: MessageID(10), newerCursor: MessageID(11))),
            .failure(StubError()),
            .success(
                try historyPage(ids: 8...9, olderCursor: MessageID(8), newerCursor: MessageID(9))),
        ])
        await model.loadInitial()

        await model.jumpToLiveEdge()

        XCTAssertEqual(model.state.content, .ready, "failure must not park the lifecycle")
        XCTAssertEqual(model.state.repositionFailure, .liveEdge)
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(10), MessageID(11)])

        // Paging is still live while the failure banner is showing.
        model.viewportDidChange(
            .init(
                firstVisibleIndex: 0, lastVisibleIndex: 1, distanceToTop: 0,
                distanceToBottom: 5_000, height: 400), reason: .user,
            revision: model.updates.value.revision)
        await source.drain()
        XCTAssertEqual(source.queries.last?.before, MessageID(10))
        XCTAssertEqual(
            model.rows.compactMap(\.messageID),
            [MessageID(8), MessageID(9), MessageID(10), MessageID(11)])
        XCTAssertEqual(model.state.repositionFailure, .liveEdge, "paging does not clear the banner")

        model.dismissRepositionFailure()
        XCTAssertNil(model.state.repositionFailure)
    }

    func testInitialLoadAroundMissingTargetSurfacesOverlayAndStaysReady() async throws {
        let (model, _, updates) = try makeModel(pages: [.success(try livePage(ids: 1...2))])

        await model.loadInitial(position: .message(MessageID(404)))

        XCTAssertEqual(model.state.content, .ready)
        XCTAssertEqual(model.state.repositionFailure, .message(MessageID(404)))
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(1), MessageID(2)])
        XCTAssertEqual(updates.value.last?.pendingScroll?.intent, .bottom(animated: false))
    }

    func testInitialMissingOrRecalledTargetFallsBackToLatestMessages() async throws {
        let recalled = try TimelineTestFixtures.message(id: 404, at: 4).redactedForDeletion()
        let missingPages: [Result<ListMessagesResponse, Error>] = [
            .failure(APIError.http(status: 404, body: Data())),
            .failure(APIError.invalidResponse(statusCode: 404)),
            .success(try TimelineTestFixtures.page([])),
            .success(try TimelineTestFixtures.page([recalled])),
        ]
        for missingPage in missingPages {
            let (model, _, updates) = try makeModel(pages: [
                missingPage, .success(try livePage(ids: 10...11)),
            ])
            await model.open(position: .message(MessageID(404)))
            XCTAssertEqual(model.state.content, .ready)
            XCTAssertEqual(model.state.repositionFailure, .message(MessageID(404)))
            XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(10), MessageID(11)])
            XCTAssertTrue(model.isAtLiveEdge)
            XCTAssertTrue(model.state.live.followsLatest)
            XCTAssertEqual(updates.value.last?.pendingScroll?.intent, .bottom(animated: false))
            model.close()
        }
    }

    func testMissingInitialTargetLatestFailureRemainsRetryable() async throws {
        let (model, _, _) = try makeModel(pages: [
            .failure(APIError.invalidResponse(statusCode: 404)),
            .failure(StubError()),
            .success(try livePage(ids: 404...405)),
        ])
        await model.open(position: .message(MessageID(404)))
        XCTAssertEqual(model.state.content, .initialLoadFailed)
        await model.retryInitial()
        XCTAssertEqual(model.state.content, .ready)
        XCTAssertNil(model.state.repositionFailure)
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(404), MessageID(405)])
    }

    func testOlderEdgeFailureIsSurfacedAndRetryable() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 10...11, olderCursor: MessageID(10), newerCursor: nil)),
            .failure(StubError()),
            .success(
                try historyPage(ids: 8...9, olderCursor: MessageID(8), newerCursor: MessageID(9))),
        ])
        await model.loadInitial()

        model.viewportDidChange(
            .init(
                firstVisibleIndex: 0, lastVisibleIndex: 1, distanceToTop: 0, distanceToBottom: 0,
                height: 400), reason: .user, revision: model.updates.value.revision)
        await source.drain()
        XCTAssertEqual(model.state.older, .failed)
        XCTAssertEqual(source.queries.last?.before, MessageID(10))

        model.viewportDidChange(
            .init(
                firstVisibleIndex: 0, lastVisibleIndex: 1, distanceToTop: 0, distanceToBottom: 0,
                height: 400), reason: .user, revision: model.updates.value.revision)
        XCTAssertEqual(source.queries.count, 2, "failed edge must not refetch until retried")

        model.retryOlder()
        await source.drain()
        XCTAssertEqual(model.state.older, .idle)
        XCTAssertEqual(
            model.rows.compactMap(\.messageID),
            [MessageID(8), MessageID(9), MessageID(10), MessageID(11)])
    }

    func testInitialSnapshotReplaysEditReactionAndDeletionBeforePublishing() async throws {
        let old = try TimelineTestFixtures.message(
            id: 1, at: 1, text: "old",
            fields: [
                "hasAttachments": true,
                "attachments": [
                    [
                        "id": "file", "url": "/file", "kind": "image/png", "size": 1,
                        "fileName": "file.png",
                    ]
                ],
            ])
        let edited = try TimelineTestFixtures.message(id: 1, at: 1, text: "new")
        let (model, source, updates) = try makeModel(pages: [
            .success(try TimelineTestFixtures.page([old]))
        ])
        source.holdNextRequest()
        let loading = Task { await model.open() }
        await source.waitUntilHeld()
        source.store.apply(.messageUpdated(edited))
        source.store.apply(
            .reactionUpdated(
                .init(messageId: MessageID(1), chatId: "chat", reactions: try reactionFixture())))
        source.store.apply(.messageDeleted(edited.redactedForDeletion()))
        source.release()
        await loading.value

        XCTAssertTrue(
            model.rows.isEmpty, "Deleted messages leave neither bubbles nor date separators")
        XCTAssertFalse(
            updates.value.contains { snapshot in
                snapshot.rows.contains { row in
                    if case .message(let row) = row { return row.entry.text == "old" }
                    return false
                }
            }, "No intermediate HTTP baseline may reach a native host")
    }

    func testOlderPageReplaysUnknownEditWithoutLosingRowsOutsideFetchedScope() async throws {
        let old = try TimelineTestFixtures.message(id: 1, at: 1, text: "old")
        let edited = try TimelineTestFixtures.message(id: 1, at: 1, text: "new")
        let (model, source, _) = try makeModel(pages: [
            .success(
                try historyPage(
                    ids: 10...11, olderCursor: MessageID(10), newerCursor: MessageID(11))),
            .success(try TimelineTestFixtures.page([old])),
        ])
        await model.loadInitial()
        source.holdNextRequest()
        model.retryOlder()
        await source.waitUntilHeld()
        source.store.apply(.messageUpdated(edited))
        XCTAssertEqual(
            model.rows.compactMap(\.messageID), [MessageID(10), MessageID(11)],
            "An unknown edit is not a create")
        source.release()
        await source.drain()
        XCTAssertEqual(
            remoteMessages(model).map(\.id), [MessageID(1), MessageID(10), MessageID(11)])
        XCTAssertEqual(remoteMessages(model).first?.message, "new")
    }

    func testLaterHTTPMayReplaceAnEventReceivedBeforeThatRequest() async throws {
        let old = try TimelineTestFixtures.message(id: 1, at: 1, text: "old")
        let new = try TimelineTestFixtures.message(id: 1, at: 1, text: "new")
        let authoritative = try TimelineTestFixtures.message(id: 1, at: 1, text: "authoritative")
        let (model, source, _) = try makeModel(pages: [
            .success(try TimelineTestFixtures.page([old])),
            .success(try TimelineTestFixtures.page([authoritative])),
        ])
        await model.open()
        source.store.apply(.messageUpdated(new))
        XCTAssertEqual(remoteMessages(model).first?.message, "new")
        await model.reconcileAfterReconnect()
        XCTAssertEqual(remoteMessages(model).first?.message, "authoritative")
    }

    func testInitialCreateAndHTTPAcknowledgementConvergeWithoutFollowingOrDuplicateRows()
        async throws
    {
        let acknowledged = try TimelineTestFixtures.message(
            id: 1, at: 1, clientGeneratedID: "send")
        for websocketFirst in [true, false] {
            let (model, source, updates) = try makeModel(pages: [
                .success(try TimelineTestFixtures.page([acknowledged]))
            ])
            source.store.replacePending(chatID: "chat", with: [pending(id: "send")])
            source.holdNextRequest()
            let loading = Task { await model.open() }
            await source.waitUntilHeld()
            if websocketFirst {
                source.store.replacePending(chatID: "chat", with: [], acknowledging: acknowledged)
            }
            source.release()
            await loading.value
            if !websocketFirst {
                source.store.replacePending(chatID: "chat", with: [], acknowledging: acknowledged)
            }
            XCTAssertEqual(
                model.rows.compactMap(\.stableMessageKey), [acknowledged.timelineStableKey])
            XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1)])
            XCTAssertFalse(updates.value.contains { $0.animateFollowing })
        }
    }

    func testLateDuplicateCreateCannotUndoOnlineEditOrDelete() async throws {
        let created = try TimelineTestFixtures.message(
            id: 1, at: 1, text: "old", clientGeneratedID: "send")
        let edited = try TimelineTestFixtures.message(
            id: 1, at: 1, text: "new", clientGeneratedID: "send")
        let (model, source, _) = try makeModel(pages: [
            .success(try TimelineTestFixtures.page([])),
            .success(try TimelineTestFixtures.page([created])),
            .success(try TimelineTestFixtures.page([created])),
        ])
        await model.open()
        source.store.replacePending(chatID: "chat", with: [pending(id: "send")])
        var visibleKeys: [[ConversationMessageStableKey]] = []
        let observation = model.updates.sink {
            visibleKeys.append($0.rows.compactMap(\.stableMessageKey))
        }
        defer { observation.cancel() }
        source.store.replacePending(chatID: "chat", with: [], acknowledging: created)
        source.store.apply(.messageUpdated(edited))
        source.store.apply(.message(created))
        XCTAssertEqual(remoteMessages(model).map(\.message), ["new"])
        XCTAssertTrue(visibleKeys.allSatisfy { $0 == [created.timelineStableKey] })
        source.store.apply(.messageDeleted(edited.redactedForDeletion()))
        XCTAssertTrue(model.rows.isEmpty)
        source.store.apply(.message(created))
        source.store.apply(.messageUpdated(edited))
        source.store.apply(
            .reactionUpdated(
                .init(messageId: MessageID(1), chatId: "chat", reactions: try reactionFixture())))
        XCTAssertTrue(
            model.rows.isEmpty, "Late events and acknowledgements must not restore deleted rows")
        await model.reconcileAfterReconnect()
        XCTAssertTrue(model.rows.isEmpty, "A stale HTTP snapshot must not restore a deleted row")
        await model.jumpToMessage(MessageID(1))
        XCTAssertEqual(model.state.repositionFailure, .message(MessageID(1)))
        XCTAssertTrue(model.rows.isEmpty, "A reply jump cannot target a removed bubble")
    }

    func testCanonicalAudioPublicationRefreshesAcknowledgementWithoutUndoingLaterState()
        async throws
    {
        let uploaded = try TimelineTestFixtures.message(
            id: 1, at: 1, type: .audio, clientGeneratedID: "send",
            fields: [
                "message": NSNull(), "hasAttachments": true,
                "attachments": [
                    [
                        "id": "upload", "url": "https://media.example/voice.m4a",
                        "kind": "audio/mp4",
                        "size": 1200, "fileName": "voice.m4a",
                    ]
                ],
            ])
        let published = try TimelineTestFixtures.message(
            id: 1, at: 1, type: .audio, clientGeneratedID: "send",
            fields: [
                "message": NSNull(), "hasAttachments": true,
                "attachments": [
                    [
                        "id": "canonical", "url": "https://media.example/voice.ogg",
                        "kind": "audio/ogg",
                        "size": 900, "fileName": "voice.ogg",
                    ]
                ],
            ])
        let (model, source, _) = try makeModel(pages: [.success(try TimelineTestFixtures.page([]))])
        await model.open()
        source.store.replacePending(chatID: "chat", with: [], acknowledging: uploaded)
        let reactions = try reactionFixture()
        source.store.apply(
            .reactionUpdated(.init(messageId: MessageID(1), chatId: "chat", reactions: reactions)))
        source.store.apply(.message(published))
        source.store.apply(.message(uploaded))

        let messages = remoteMessages(model)
        XCTAssertEqual(messages.map(\.id), [MessageID(1)])
        XCTAssertEqual(messages.first?.attachments.first?.url, "https://media.example/voice.ogg")
        XCTAssertEqual(messages.first?.reactions, reactions)

        source.store.apply(.messageDeleted(published.redactedForDeletion()))
        source.store.apply(.message(published))
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testTwoModelsHaveIndependentHistoryGapsAndJumpAvailability() async throws {
        let source = ScriptedTimelineSource(pages: [
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            .success(try livePage(ids: 1...2)),
            .success(try livePage(ids: 3...3)),
        ])
        let historical = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: true, source: source,
            messageStore: source.store)
        let latest = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: true, source: source,
            messageStore: source.store)
        await historical.open()
        await latest.open()
        let created = try TimelineTestFixtures.message(id: 3, at: 3)
        source.store.apply(.message(created))
        source.store.apply(.message(created))
        source.store.apply(
            .messageUpdated(
                try TimelineTestFixtures.message(id: 1, at: 1, text: "edited in both")))
        source.store.apply(
            .messageDeleted(try TimelineTestFixtures.message(id: 2, at: 2).redactedForDeletion()))
        XCTAssertEqual(remoteMessages(historical).map(\.id), [MessageID(1)])
        XCTAssertEqual(remoteMessages(latest).map(\.id), [MessageID(1), MessageID(3)])
        for model in [historical, latest] {
            XCTAssertEqual(remoteMessages(model).first?.message, "edited in both")
        }
        XCTAssertTrue(historical.showsJumpToLatest)
        XCTAssertFalse(latest.showsJumpToLatest)
        await historical.jumpToLiveEdge()
        XCTAssertEqual(
            remoteMessages(historical).map(\.id), [MessageID(3)],
            "A latest replacement must not bridge the old history gap")
        XCTAssertEqual(remoteMessages(latest).map(\.id), [MessageID(1), MessageID(3)])
    }

    func testDeferredMutationsRemainWindowLocalUntilLatestClosesTheGap() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...1, newerCursor: MessageID(1))),
            .success(try livePage(ids: 2...2)),
        ])
        await model.open()
        let created = try TimelineTestFixtures.message(id: 3, at: 3, text: "old")
        source.store.apply(.message(created))
        source.store.apply(
            .messageUpdated(try TimelineTestFixtures.message(id: 3, at: 3, text: "edited")))
        source.store.apply(.messageDeleted(created.redactedForDeletion()))
        source.store.apply(.message(created))
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1)])
        XCTAssertTrue(model.showsJumpToLatest)
        await model.jumpToLiveEdge()
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(2)])
    }

    func testEmptyLatestSnapshotDiscardsOldDeferredRowsButReplaysInFlightCreate() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...1, newerCursor: MessageID(1))),
            .success(try TimelineTestFixtures.page([])),
        ])
        await model.open()
        source.store.apply(.message(try TimelineTestFixtures.message(id: 2, at: 2)))
        source.holdNextRequest()
        let jumping = Task { await model.jumpToLiveEdge() }
        await source.waitUntilHeld()
        let fresh = try TimelineTestFixtures.message(id: 3, at: 3)
        source.store.apply(.message(fresh))
        source.store.apply(.messageDeleted(fresh.redactedForDeletion()))
        source.release()
        await jumping.value
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testReconnectJoinsInitialOpenInsteadOfStartingACompetingReplacement() async throws {
        let (model, source, _) = try makeModel(pages: [.success(try livePage(ids: 1...1))])
        source.holdNextRequest()
        let opening = Task { await model.open() }
        await source.waitUntilHeld()
        let recovering = Task { await model.reconcileAfterReconnect() }
        await source.drain()
        source.release()
        await opening.value
        await recovering.value
        XCTAssertEqual(source.queries.count, 1)
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1)])
    }

    func testThreadScopeFiltersHTTPAndLiveRepliesWithoutLosingRootMetadata() async throws {
        let root = try TimelineTestFixtures.message(id: 1, at: 1)
        let reply = try TimelineTestFixtures.message(
            id: 2, at: 2, fields: ["replyRootId": "1"])
        let other = try TimelineTestFixtures.message(
            id: 3, at: 3, fields: ["replyRootId": "elsewhere"])
        let page = try TimelineTestFixtures.page([root, reply, other])
        let source = ScriptedTimelineSource(pages: [.success(page), .success(page)])
        let chat = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: true, source: source,
            messageStore: source.store)
        let thread = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: true, source: source,
            messageStore: source.store, threadID: "1")
        await chat.open()
        await thread.open()
        source.store.apply(
            .message(
                try TimelineTestFixtures.message(
                    id: 4, at: 4, fields: ["replyRootId": "1"])))
        source.store.apply(
            .threadUpdate(
                .init(
                    threadRootId: "1", chatId: "chat", lastReplyAt: root.createdAt, replyCount: 2
                )))
        XCTAssertEqual(remoteMessages(chat).map(\.id), [MessageID(1)])
        XCTAssertEqual(
            remoteMessages(thread).map(\.id), [MessageID(1), MessageID(2), MessageID(4)])
        XCTAssertEqual(remoteMessages(chat).first?.threadInfo?.replyCount, 2)
        XCTAssertEqual(remoteMessages(thread).first?.message, root.message)
    }

    func testBulkDeletionRedactsReplyPreviewsAndEmptyReactionArrayClearsKnownRecord() async throws {
        let root = try TimelineTestFixtures.message(id: 1, at: 1)
        let preview: [String: Any] = [
            "id": "1", "clientGeneratedId": "client-1", "createdAt": "2026-09-01T00:00:01Z",
            "sender": ["uid": 1, "gender": 0], "messageType": "text", "message": "secret",
            "attachments": [["kind": "image/png"]], "mentions": [], "isDeleted": false,
        ]
        let reply = try TimelineTestFixtures.message(
            id: 2, at: 2, fields: ["replyToMessage": preview])
        let (model, source, _) = try makeModel(pages: [
            .success(try TimelineTestFixtures.page([root, reply]))
        ])
        await model.open()
        source.store.apply(
            .reactionUpdated(
                .init(messageId: MessageID(2), chatId: "chat", reactions: try reactionFixture())))
        XCTAssertEqual(remoteMessages(model).last?.reactions.first?.count, 3)
        source.store.apply(
            .reactionUpdated(.init(messageId: MessageID(2), chatId: "chat", reactions: [])))
        source.store.apply(
            .messagesBulkDeleted(.init(chatId: "chat", messageIds: [MessageID(1), MessageID(99)])))
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(2)])
        let quoted = try XCTUnwrap(remoteMessages(model).last?.replyToMessage)
        XCTAssertEqual(quoted.id, MessageID(1))
        XCTAssertTrue(quoted.isDeleted)
        XCTAssertNil(quoted.message)
        XCTAssertTrue(quoted.attachments.isEmpty)
        XCTAssertTrue(try XCTUnwrap(remoteMessages(model).last).reactions.isEmpty)
        source.store.apply(.messageUpdated(reply))
        XCTAssertNil(
            remoteMessages(model).last?.replyToMessage?.message,
            "A later WS record cannot restore a deleted quote")
    }

    func testReopenSameModelAlwaysFetchesAndDiscardsPreviousRemoteRows() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try livePage(ids: 1...2)), .success(try livePage(ids: 3...3)),
        ])
        await model.open()
        model.close()
        source.store.apply(.message(try TimelineTestFixtures.message(id: 4, at: 4)))
        await model.open()
        XCTAssertEqual(source.queries.count, 2)
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(3)])
    }

    func testRecoveryRetainsVisibleRowsThenReplaysAroundAnchorWithoutJumping() async throws {
        let old = try TimelineTestFixtures.message(id: 11, senderID: 2, at: 11, text: "old")
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 10...12, newerCursor: MessageID(12))),
            .success(
                try TimelineTestFixtures.page(
                    [old], olderCursor: MessageID(11), newerCursor: MessageID(11))),
        ])
        await model.open()
        model.userScrollBegan()
        let anchorIndex = try XCTUnwrap(model.rows.firstIndex { $0.messageID == MessageID(11) })
        model.viewportDidChange(
            .init(
                firstVisibleIndex: anchorIndex, lastVisibleIndex: anchorIndex, distanceToTop: 5_000,
                distanceToBottom: 5_000, height: 400), reason: .user,
            revision: model.updates.value.revision)
        source.holdNextRequest()
        let recovering = Task { await model.reconcileAfterReconnect() }
        await source.waitUntilHeld()
        XCTAssertEqual(source.queries.last?.around, MessageID(11))
        XCTAssertEqual(model.state.content, .ready)
        XCTAssertEqual(
            remoteMessages(model).map(\.id), [MessageID(10), MessageID(11), MessageID(12)])
        source.store.apply(
            .messageUpdated(
                try TimelineTestFixtures.message(id: 11, senderID: 2, at: 11, text: "new")))
        source.store.apply(.message(try TimelineTestFixtures.message(id: 13, at: 13)))
        source.release()
        await recovering.value
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(11)])
        XCTAssertEqual(remoteMessages(model).first?.message, "new")
        XCTAssertTrue(model.showsJumpToLatest)
        XCTAssertFalse(model.state.live.followsLatest)
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent,
            .reveal(.message(old.timelineStableKey), animated: false, highlight: false))
    }

    func testRecoveryFailureKeepsRowsAndEmptyRetryDoesNotResurrectOldContent() async throws {
        let (model, _, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            .failure(StubError()), .success(try TimelineTestFixtures.page([])),
        ])
        await model.open()
        model.userScrollBegan()
        await model.reconcileAfterReconnect()
        XCTAssertTrue(model.state.reconciliationFailed)
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1), MessageID(2)])
        await model.reconcileAfterReconnect()
        XCTAssertFalse(model.state.reconciliationFailed)
        XCTAssertTrue(remoteMessages(model).isEmpty)
        XCTAssertFalse(model.state.live.followsLatest)
    }

    func testNavigationSupersedesSuspendedRecoveryAndCloseInvalidatesInitialResponse() async throws
    {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            .success(try livePage(ids: 1...2)),
            .success(try livePage(ids: 10...11)),
            .success(try livePage(ids: 20...21)),
        ])
        await model.open()
        source.holdNextRequest()
        let recovering = Task { await model.reconcileAfterReconnect() }
        await source.waitUntilHeld()
        await model.jumpToLiveEdge()
        source.release()
        await recovering.value
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(10), MessageID(11)])
        model.close()
        source.holdNextRequest()
        let reopening = Task { await model.open() }
        await source.waitUntilHeld()
        model.close()
        source.release()
        await reopening.value
        XCTAssertTrue(remoteMessages(model).isEmpty)
    }

    func testCancellingRecoveryKeepsObservationAliveForForegroundRetry() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try livePage(ids: 1...1)), .success(try livePage(ids: 8...8)),
            .success(try livePage(ids: 3...3)),
        ])
        await model.open()
        source.holdNextRequest()
        let recovering = Task { await model.reconcileAfterReconnect() }
        await source.waitUntilHeld()
        recovering.cancel()
        await source.drain()
        source.store.apply(.message(try TimelineTestFixtures.message(id: 2, at: 2)))
        source.release()
        await recovering.value
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(1), MessageID(2)])
        await model.reconcileAfterReconnect()
        XCTAssertEqual(remoteMessages(model).map(\.id), [MessageID(3)])
    }

    func testUnreadEntryAtSettledLiveBottomMarksVisibleMessagesWithoutShowingJump() async throws {
        var reads: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...3))],
            markRead: { reads.append($0) })
        model.updateReadState(unreadCount: 2, lastReadMessageID: MessageID(1))
        model.setReadTrackingActive(true)
        await model.open(position: .unread(after: MessageID(1)))
        XCTAssertFalse(model.showsJumpToLatest, "Wait for actual geometry before showing a jump.")
        let request = try XCTUnwrap(model.updates.value.pendingScroll)
        let viewport = TimelineViewport(
            firstVisibleIndex: 0, lastVisibleIndex: model.rows.count - 1,
            distanceToTop: 0, distanceToBottom: 0, height: 600,
            visibleMessageIDs: [MessageID(1), MessageID(2), MessageID(3)])
        model.viewportDidChange(viewport, reason: .layout, revision: model.updates.value.revision)
        XCTAssertFalse(
            model.state.live.followsLatest, "An unfinished reveal still owns navigation.")
        XCTAssertTrue(reads.isEmpty, "Do not mark messages read before the entry scroll settles.")
        model.scrollRequestDidFinish(id: request.id)
        model.viewportDidChange(
            viewport, reason: .programmatic, revision: model.updates.value.revision)
        await source.drain()
        XCTAssertEqual(
            reads, [MessageID(3)], "Entering reads through the last visible message.")
        XCTAssertTrue(model.state.live.isPinnedToBottom)
        XCTAssertTrue(model.state.live.followsLatest)
        XCTAssertFalse(
            model.showsJumpToLatest, "Unread metadata does not mean the viewport is away.")
        model.updateReadState(unreadCount: 0, lastReadMessageID: MessageID(3))
        source.store.apply(.message(try TimelineTestFixtures.message(id: 4, senderID: 2, at: 4)))
        XCTAssertTrue(model.updates.value.animateFollowing)
    }

    func testUnreadEntryAtHistoricalWindowBottomDoesNotFollowLatest() async throws {
        let (model, _, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...3, newerCursor: MessageID(3)))
        ])
        await model.open(position: .unread(after: MessageID(2)))
        model.scrollRequestDidFinish(id: try XCTUnwrap(model.updates.value.pendingScroll).id)
        model.viewportDidChange(
            .init(
                firstVisibleIndex: 0, lastVisibleIndex: model.rows.count - 1,
                distanceToTop: 0, distanceToBottom: 0, height: 600),
            reason: .programmatic, revision: model.updates.value.revision)
        XCTAssertTrue(model.state.live.isPinnedToBottom)
        XCTAssertFalse(model.state.live.followsLatest)
        XCTAssertFalse(model.isAtLiveEdge)
    }

    func testUnreadEntryRevealsFirstServerMessageAfterLastCachedReadMessage() async throws {
        let (cache, local) = try await makeHistoryCache()
        let lastRead = MessageID(10)
        let epoch = try await local.cacheEpoch()
        try await local.cacheHistory(
            ConversationKey(chatID: "chat"), query: .init(max: 50),
            response: try livePage(ids: 1...10), epoch: epoch)

        let source = ScriptedTimelineSource(pages: [.success(try livePage(ids: 1...13))])
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false, source: source,
            messageStore: source.store, historyCache: cache, canFetchHistory: { true })
        defer { model.close() }
        await model.open(position: .unread(after: lastRead))

        XCTAssertEqual(model.state.history, .server)
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent,
            .reveal(.unreadSeparator, animated: false, highlight: false))
        let marker = try XCTUnwrap(model.rows.firstIndex { $0.id == .unreadSeparator })
        XCTAssertEqual(model.rows.dropFirst(marker + 1).first?.messageID, MessageID(11))
    }

    func testScrollingSavedUnreadChatDuringReconnectKeepsReaderPosition() async throws {
        let (cache, local) = try await makeHistoryCache()
        let epoch = try await local.cacheEpoch()
        try await local.cacheHistory(
            ConversationKey(chatID: "chat"), query: .init(max: 50),
            response: try livePage(ids: 1...10), epoch: epoch)
        let page = try livePage(ids: 1...13)
        let source = ScriptedTimelineSource(pages: [.success(page), .success(page)])
        var online = false
        let model = ConversationTimelineModel(
            chatID: "chat", currentUserID: 1, isGroupChat: false, source: source,
            messageStore: source.store, historyCache: cache, canFetchHistory: { online })
        defer { model.close() }
        await model.open(position: .unread(after: MessageID(10)))

        online = true
        source.holdNextRequest()
        let refreshing = Task { await model.resumeNetworkHistory() }
        await source.waitUntilHeld()
        model.userScrollBegan()
        reportVisible([MessageID(4)], to: model, reason: .user)
        source.release()
        await refreshing.value

        XCTAssertEqual(source.queries.last?.around, MessageID(4))
        XCTAssertEqual(model.state.history, .server)
        XCTAssertNil(model.updates.value.pendingScroll, "Keep the visible row's offset.")
    }

    func testUnreadEntryRevealsFrozenBoundaryAndPreservesOlderPagination() async throws {
        let read = try TimelineTestFixtures.message(id: 2, at: 2)
        let unread = try TimelineTestFixtures.message(id: 3, at: 3)
        let (model, source, _) = try makeModel(pages: [
            .success(
                try TimelineTestFixtures.page(
                    [read, unread], olderCursor: MessageID(2), newerCursor: nil)),
            .success(try livePage(ids: 1...1)),
        ])
        await model.open(position: .unread(after: read.id))

        XCTAssertEqual(source.queries.first?.around, read.id)
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent,
            .reveal(.unreadSeparator, animated: false, highlight: false))
        XCTAssertFalse(model.state.live.followsLatest)
        model.retryOlder()
        await source.drain()
        source.store.apply(.message(try TimelineTestFixtures.message(id: 4, at: 4)))
        let boundary = try XCTUnwrap(model.rows.firstIndex { $0.id == .unreadSeparator })
        XCTAssertEqual(model.rows[boundary - 1].messageID, read.id)
        XCTAssertEqual(model.rows[boundary + 1].messageID, unread.id)
        XCTAssertEqual(
            model.rows.compactMap(\.messageID), [MessageID(1), read.id, unread.id, MessageID(4)])
    }

    func testUnreadEntryFetchesBeyondBoundaryAtEndOfAroundPage() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            .success(try livePage(ids: 3...4)),
        ])
        await model.open(position: .unread(after: MessageID(2)))

        XCTAssertEqual(source.queries.map(\.after), [nil, MessageID(2)])
        let boundary = try XCTUnwrap(model.rows.firstIndex { $0.id == .unreadSeparator })
        XCTAssertEqual(model.rows[boundary - 1].messageID, MessageID(2))
        XCTAssertEqual(model.rows[boundary + 1].messageID, MessageID(3))
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent,
            .reveal(.unreadSeparator, animated: false, highlight: false))
    }

    func testUnreadWithoutCursorSeeksOldestPageWithoutRetainingEntireHistory() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 5...6, olderCursor: MessageID(5), newerCursor: nil)),
            .success(
                try historyPage(ids: 3...4, olderCursor: MessageID(3), newerCursor: MessageID(4))),
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            .success(try historyPage(ids: 3...4, newerCursor: MessageID(4))),
        ])
        await model.open(position: .unread(after: nil))

        XCTAssertEqual(source.queries.map(\.before), [nil, MessageID(5), MessageID(3)])
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(1), MessageID(2)])
        XCTAssertFalse(model.isAtLiveEdge)
        let boundary = try XCTUnwrap(model.rows.firstIndex { $0.id == .unreadSeparator })
        XCTAssertEqual(model.rows[boundary + 1].messageID, MessageID(1))
        model.retryNewer()
        await source.drain()
        XCTAssertEqual(source.queries.last?.after, MessageID(2))
        XCTAssertEqual(
            model.rows.compactMap(\.messageID),
            [MessageID(1), MessageID(2), MessageID(3), MessageID(4)])
        XCTAssertEqual(model.rows.firstIndex { $0.id == .unreadSeparator }, boundary)
    }

    func testMissingUnreadTargetUsesAccessibleBeginningWithoutAcknowledgingKnownReadMessages()
        async throws
    {
        var marked: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [
                .success(try historyPage(ids: 3...4, olderCursor: MessageID(3), newerCursor: nil)),
                .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            ], markRead: { marked.append($0) })
        model.setReadTrackingActive(true)
        await model.open(position: .unread(after: MessageID(99)))

        XCTAssertEqual(source.queries.first?.around, MessageID(99))
        let boundary = try XCTUnwrap(model.rows.firstIndex { $0.id == .unreadSeparator })
        XCTAssertEqual(model.rows[boundary + 1].messageID, MessageID(1))
        reportVisible([MessageID(1), MessageID(2)], to: model)
        await source.drain()
        XCTAssertTrue(marked.isEmpty, "A missing cursor is still authoritative read progress.")
        XCTAssertEqual(
            model.rows[boundary + 1].messageID, MessageID(1),
            "Read suppression does not move the entry boundary.")
        model.close()
    }

    func testDeletedUnreadTarget404FallsBackButOtherFailuresRemainRetryable() async throws {
        let (model, source, _) = try makeModel(pages: [
            .failure(APIError.http(status: 404, body: Data())),
            .success(try livePage(ids: 1...2)),
            .failure(StubError()),
        ])
        await model.open(position: .unread(after: MessageID(99)))
        XCTAssertEqual(model.state.content, .ready)
        XCTAssertEqual(source.queries.count, 2)
        XCTAssertTrue(model.rows.contains { $0.id == .unreadSeparator })

        await model.open(position: .unread(after: MessageID(100)))
        XCTAssertEqual(model.state.content, .initialLoadFailed)
        XCTAssertEqual(source.queries.count, 3)
    }

    func testEmptyUnreadHistoryAndFullyReadBoundaryDoNotInventSeparator() async throws {
        let (model, _, _) = try makeModel(pages: [
            .success(try TimelineTestFixtures.page([])),
            .success(try livePage(ids: 1...2)),
        ])
        await model.open(position: .unread(after: nil))
        XCTAssertEqual(model.state.content, .ready)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.updates.value.pendingScroll?.intent, .bottom(animated: false))

        await model.open(position: .unread(after: MessageID(2)))
        XCTAssertFalse(model.rows.contains { $0.id == .unreadSeparator })
        XCTAssertTrue(model.state.live.followsLatest)
    }

    func testEmptyAroundResponseDoesNotHideAccessibleUnreadHistory() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try TimelineTestFixtures.page([])),
            .success(try historyPage(ids: 3...4, olderCursor: MessageID(3), newerCursor: nil)),
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
        ])
        await model.open(position: .unread(after: MessageID(99)))

        XCTAssertEqual(model.state.content, .ready)
        XCTAssertEqual(source.queries.map(\.before), [nil, nil, MessageID(3)])
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(1), MessageID(2)])
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent,
            .reveal(.unreadSeparator, animated: false, highlight: false))
    }

    func testUnreadSeekRejectsRepeatedCursorInsteadOfPublishingWrongBeginning() async throws {
        let (model, _, _) = try makeModel(pages: [
            .success(try historyPage(ids: 3...4, olderCursor: MessageID(3), newerCursor: nil)),
            .success(
                try historyPage(ids: 1...2, olderCursor: MessageID(3), newerCursor: MessageID(2))),
        ])
        await model.open(position: .unread(after: nil))
        XCTAssertEqual(model.state.content, .initialLoadFailed)
        XCTAssertFalse(model.rows.contains { $0.id == .unreadSeparator })
    }

    func testKnownReadCursorOutsideWindowSuppressesEntryAndReentry() async throws {
        var marked: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [
                .success(try historyPage(ids: 1...3, newerCursor: MessageID(3))),
                .success(try historyPage(ids: 1...3, newerCursor: MessageID(3))),
            ], markRead: { marked.append($0) })
        model.updateReadState(unreadCount: 0, lastReadMessageID: MessageID(99))
        model.setReadTrackingActive(true)
        await model.open(position: .message(MessageID(1)))
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        reportVisible([MessageID(2), MessageID(3)], to: model)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(marked.isEmpty, "Historical visible rows are already known to be read.")

        model.close()
        model.setReadTrackingActive(true)
        await model.open(position: .message(MessageID(1)))
        reportVisible([MessageID(2), MessageID(3)], to: model)
        await source.drain()
        XCTAssertTrue(marked.isEmpty, "Reentry must not bypass the authoritative cursor.")
        model.close()
    }

    func testNewerRemoteReadCursorSuppressesQueuedDwellDespiteOlderMetadata() async throws {
        var marked: [MessageID] = []
        var releaseFirst: CheckedContinuation<Void, Never>?
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...3))],
            markRead: { id in
                marked.append(id)
                if id == MessageID(1) { await withCheckedContinuation { releaseFirst = $0 } }
            })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(1)])
        reportVisible([MessageID(3)], to: model)
        try await Task.sleep(for: .milliseconds(600))
        model.updateReadState(unreadCount: 0, lastReadMessageID: MessageID(99))
        releaseFirst?.resume()
        await source.drain()
        XCTAssertEqual(marked, [MessageID(1)], "Remote progress invalidates mature queued work.")

        model.updateReadState(unreadCount: 2, lastReadMessageID: MessageID(1))
        reportVisible([MessageID(3)], to: model)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            marked, [MessageID(1)],
            "An older snapshot cannot erase authoritative progress outside the window.")
        model.close()
    }

    func testNewerRemoteReadCursorCancelsEntryBeforeItsRequestStarts() async throws {
        var marked: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...2))], markRead: { marked.append($0) })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(1)], to: model)
        model.updateReadState(unreadCount: 0, lastReadMessageID: MessageID(99))
        await source.drain()
        XCTAssertTrue(marked.isEmpty, "A queued entry must revalidate newer authoritative state.")
        model.close()
    }

    func testThreadRootDoesNotConsumeImmediateReadWithUnknownCursor() async throws {
        var marked: [MessageID] = []
        let root = try TimelineTestFixtures.message(id: 1, at: 1)
        let reply = try TimelineTestFixtures.message(
            id: 2, at: 2, fields: ["replyRootId": "1"])
        let (model, source, _) = try makeModel(
            pages: [.success(try TimelineTestFixtures.page([root, reply]))],
            threadID: "1", markRead: { marked.append($0) })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertTrue(marked.isEmpty, "The root belongs to the parent conversation's read scope.")
        reportVisible([MessageID(2)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(2)], "The first actual topic reply remains immediate.")
        model.close()
    }

    func testExplicitUnreadResetAllowsRereadingWithoutMovingEntrySeparator() async throws {
        var marked: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...3))], markRead: { marked.append($0) })
        model.updateReadState(unreadCount: 2, lastReadMessageID: MessageID(1))
        model.setReadTrackingActive(true)
        await model.open(position: .unread(after: MessageID(1)))
        let boundary = try XCTUnwrap(model.rows.firstIndex { $0.id == .unreadSeparator })
        XCTAssertEqual(model.rows[boundary + 1].messageID, MessageID(2))
        reportVisible([MessageID(3)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(3)])
        model.updateReadState(unreadCount: 0, lastReadMessageID: MessageID(3))

        model.resetReadWatermark(to: MessageID(1))
        model.updateReadState(unreadCount: 2, lastReadMessageID: MessageID(1))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(marked, [MessageID(3), MessageID(3)], "Explicit unread permits rereading.")
        XCTAssertEqual(
            model.rows[boundary + 1].messageID, MessageID(2),
            "Read resets do not redefine the frozen entry separator.")

        model.resetReadWatermark(to: nil)
        reportVisible([MessageID(1)], to: model)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            marked, [MessageID(3), MessageID(3), MessageID(1)],
            "A nil unread cursor permits reading from the beginning again.")
        model.close()
    }

    func testExplicitUnreadResetFencesLateInFlightReadCompletion() async throws {
        var marked: [MessageID] = []
        var releaseFirst: CheckedContinuation<Void, Never>?
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...3))],
            markRead: { id in
                marked.append(id)
                if marked.count == 1 { await withCheckedContinuation { releaseFirst = $0 } }
            })
        model.updateReadState(unreadCount: 2, lastReadMessageID: MessageID(1))
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(3)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(3)])

        model.resetReadWatermark(to: MessageID(1))
        reportVisible([MessageID(2)], to: model)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(marked, [MessageID(3)], "The reset cannot overlap an in-flight callback.")
        releaseFirst?.resume()
        await source.drain()
        XCTAssertEqual(
            marked, [MessageID(3), MessageID(2)],
            "A pre-reset completion must not restore its superseded watermark.")
        reportVisible([MessageID(3)], to: model)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(marked, [MessageID(3), MessageID(2), MessageID(3)])
        model.close()
    }

    func testExplicitUnreadResetDuringEntryFetchSupersedesEntryCursor() async throws {
        var marked: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...3))], markRead: { marked.append($0) })
        source.holdNextRequest()
        model.setReadTrackingActive(true)
        let opening = Task { await model.open(position: .unread(after: MessageID(99))) }
        await source.waitUntilHeld()
        model.resetReadWatermark(to: MessageID(1))
        source.release()
        await opening.value
        reportVisible([MessageID(3)], to: model)
        await source.drain()
        XCTAssertEqual(
            marked, [MessageID(3)],
            "A stale entry snapshot must not undo an intervening unread reset.")
        model.close()
    }

    func testAccountResetPreventsOldModelFromStartingAnotherRead() async throws {
        var marked: [MessageID] = []
        var releaseFirst: CheckedContinuation<Void, Never>?
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...2)), .success(try livePage(ids: 1...2))],
            markRead: { id in
                marked.append(id)
                if marked.count == 1 { await withCheckedContinuation { releaseFirst = $0 } }
            })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(1)])
        source.store.reset()
        releaseFirst?.resume()
        await source.drain()
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(2)], to: model)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(marked, [MessageID(1)], "An old account model cannot resume read tracking.")
        model.close()
    }

    func testExplicitUnreadResetBeforeReentrySupersedesFrozenEntryCursor() async throws {
        var marked: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...3)), .success(try livePage(ids: 1...3))],
            markRead: { marked.append($0) })
        model.setReadTrackingActive(true)
        await model.open(position: .unread(after: MessageID(99)))
        reportVisible([MessageID(3)], to: model)
        await source.drain()
        XCTAssertTrue(marked.isEmpty)
        model.close()

        model.resetReadWatermark(to: nil)
        model.setReadTrackingActive(true)
        await model.open(position: .unread(after: MessageID(99)))
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertEqual(
            marked, [MessageID(1)], "A frozen entry cursor cannot undo explicit unread on reentry.")
        model.close()
    }

    func testEntryReadIsImmediateThenDwellUsesStableVisibleCandidate()
        async throws
    {
        var marked: [MessageID] = []
        let messages = [
            try TimelineTestFixtures.message(id: 1, at: 1),
            try TimelineTestFixtures.message(id: 2, at: 2),
            try TimelineTestFixtures.message(id: 3, at: 3),
            try TimelineTestFixtures.message(id: 4, at: 4),
        ]
        let (model, source, _) = try makeModel(
            pages: [.success(try TimelineTestFixtures.page(messages))],
            markRead: { marked.append($0) })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([], to: model)
        await source.drain()
        XCTAssertTrue(marked.isEmpty, "Opening must not mark an unseen latest message.")
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertEqual(
            marked, [MessageID(1)], "The first eligible visible candidate bypasses dwell.")
        reportVisible([MessageID(1), MessageID(2)], to: model)
        try await Task.sleep(for: .milliseconds(300))
        reportVisible([MessageID(2), MessageID(3)], to: model)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(
            marked, [MessageID(1)],
            "Changing the latest visible message restarts subsequent dwell.")
        reportVisible([MessageID(3)], to: model)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(
            marked, [MessageID(1), MessageID(3)],
            "Repeated geometry reports for the same candidate do not restart dwell.")
        reportVisible([MessageID(2)], to: model)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            marked, [MessageID(1), MessageID(3)],
            "Scrolling backwards cannot regress local progress.")
        reportVisible([MessageID(4)], to: model)
        try await Task.sleep(for: .milliseconds(200))
        reportVisible([], to: model)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(
            marked, [MessageID(1), MessageID(3)], "Losing all visible rows cancels dwell.")
        model.close()
    }

    func testReadDwellCancelsForInactiveStaleInvalidAndClosedViewports() async throws {
        var marked: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...2))], markRead: { marked.append($0) })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(1)])
        reportVisible([MessageID(2)], to: model)
        model.setReadTrackingActive(false)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(marked, [MessageID(1)])

        model.setReadTrackingActive(true)
        reportVisible([MessageID(2)], to: model, revision: model.updates.value.revision - 1)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            marked, [MessageID(1)], "Activation requires a fresh matching host viewport.")
        reportVisible([MessageID(2)], to: model)
        source.store.apply(.message(try TimelineTestFixtures.message(id: 3, at: 3)))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            marked, [MessageID(1)], "Publication invalidates the previous viewport's dwell.")

        reportVisible([MessageID(3)], to: model)
        model.viewportDidChange(.empty, reason: .layout, revision: model.updates.value.revision)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            marked, [MessageID(1)], "A fully obscured host cancels the previous candidate.")
        reportVisible([MessageID(3)], to: model)
        model.close()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(marked, [MessageID(1)])
    }

    func testReadRequestsSerializeAndRevalidateQueuedCandidates() async throws {
        var marked: [MessageID] = []
        var releaseFirst: CheckedContinuation<Void, Never>?
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...3))],
            markRead: { id in
                marked.append(id)
                if id == MessageID(1) { await withCheckedContinuation { releaseFirst = $0 } }
            })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(1)])
        reportVisible([MessageID(2)], to: model)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            marked, [MessageID(1)], "A mature candidate waits for the in-flight receipt.")
        reportVisible([MessageID(3)], to: model)
        releaseFirst?.resume()
        await source.drain()
        XCTAssertEqual(marked, [MessageID(1)], "An obsolete mature candidate must not be sent.")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(marked, [MessageID(1), MessageID(3)])
        model.close()
    }

    func testReadFailureRetriesOnlyAfterAnotherStableViewport() async throws {
        var marked: [MessageID] = []
        let (model, _, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...1))],
            markRead: { id in
                marked.append(id)
                if marked.count == 1 { throw StubError() }
            })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(1)], to: model)
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertEqual(marked, [MessageID(1)], "Failures cannot trigger an automatic retry loop.")
        reportVisible([MessageID(1)], to: model)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(marked, [MessageID(1), MessageID(1)])
        model.close()
    }

    func testExistingWindowScrollCancelsDwellUntilFreshCompletedViewport() async throws {
        var marked: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...3))], markRead: { marked.append($0) })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(1)])
        reportVisible([MessageID(2)], to: model)
        await model.jumpToLiveEdge()
        XCTAssertEqual(model.updates.value.pendingScroll?.intent, .bottom(animated: true))

        var duringAnimation = TimelineViewport(
            firstVisibleIndex: 0, lastVisibleIndex: model.rows.count - 1, distanceToTop: 0,
            distanceToBottom: 0, height: 400)
        duringAnimation.visibleMessageIDs = [MessageID(2)]
        model.viewportDidChange(
            duringAnimation, reason: .programmatic, revision: model.updates.value.revision)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(
            marked, [MessageID(1)],
            "A scroll command invalidates old geometry even without changing rows.")

        reportVisible([MessageID(3)], to: model)
        await source.drain()
        XCTAssertEqual(
            marked, [MessageID(1)], "A jump does not reset the entry-only immediate read allowance."
        )
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(marked, [MessageID(1), MessageID(3)])
        model.close()
    }

    func testJumpVisibilityTracksActualViewportNotScrollDirectionOrUnreadMetadata() async throws {
        let (model, _, _) = try makeModel(pages: [.success(try livePage(ids: 1...5))])
        await model.open()
        reportVisible([MessageID(4)], to: model)
        model.userScrollBegan()
        reportVisible([MessageID(3)], to: model, reason: .user)
        XCTAssertTrue(model.showsJumpToLatest, "Scrolling upward leaves the live bottom.")
        reportVisible([MessageID(4)], to: model, reason: .layout)
        XCTAssertTrue(model.showsJumpToLatest, "Layout updates retain actual viewport position.")
        reportVisible([MessageID(5)], to: model, reason: .user, distanceToBottom: 0)
        XCTAssertFalse(model.showsJumpToLatest, "The absolute latest edge has nowhere to jump.")
        model.updateReadState(unreadCount: 2, lastReadMessageID: MessageID(3))
        XCTAssertFalse(
            model.showsJumpToLatest, "Unread metadata cannot show a button at the bottom.")
        model.updateReadState(unreadCount: 0, lastReadMessageID: MessageID(5))
        XCTAssertFalse(model.showsJumpToLatest)
    }

    func testJumpUsesChangingReadBoundaryWhileUnreadSeparatorStaysFrozen() async throws {
        let (model, source, _) = try makeModel(pages: [.success(try livePage(ids: 1...5))])
        model.updateReadState(unreadCount: 3, lastReadMessageID: MessageID(2))
        await model.open(position: .unread(after: MessageID(2)))
        reportVisible([MessageID(1)], to: model)
        await model.jumpTowardLatest()
        let firstBoundary = try XCTUnwrap(model.rows.first { $0.messageID == MessageID(2) }?.id)
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent, .readBoundary(firstBoundary, animated: true))
        reportVisible([MessageID(2)], to: model)
        await model.jumpTowardLatest()
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent, .bottom(animated: true),
            "A repeat click at the read boundary reaches latest.")

        reportVisible([MessageID(1)], to: model)
        model.updateReadState(unreadCount: 1, lastReadMessageID: MessageID(4))
        await model.jumpTowardLatest()
        let currentBoundary = try XCTUnwrap(model.rows.first { $0.messageID == MessageID(4) }?.id)
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent,
            .readBoundary(currentBoundary, animated: true))
        let separator = try XCTUnwrap(model.rows.firstIndex { $0.id == .unreadSeparator })
        XCTAssertEqual(
            model.rows[separator + 1].messageID, MessageID(3),
            "Read receipts must not move the entry separator.")
        XCTAssertEqual(model.jumpUnreadCount, 1)
        XCTAssertEqual(source.queries.count, 1, "Loaded read boundaries reuse the native window.")
    }

    func testJumpLoadsUnreadBoundaryThenAbsoluteLatestAcrossDisjointWindows() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            .success(try historyPage(ids: 40...42, newerCursor: MessageID(42))),
            .success(try livePage(ids: 98...99)),
        ])
        model.updateReadState(unreadCount: 9, lastReadMessageID: MessageID(41))
        await model.open(position: .message(MessageID(1)))
        reportVisible([MessageID(2)], to: model)
        await model.jumpTowardLatest()
        let boundary = try XCTUnwrap(model.rows.first { $0.messageID == MessageID(41) }?.id)
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent, .readBoundary(boundary, animated: false))
        XCTAssertEqual(source.queries.last?.around, MessageID(41))
        reportVisible([MessageID(41)], to: model)
        await model.jumpTowardLatest()
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(98), MessageID(99)])
        XCTAssertEqual(model.updates.value.pendingScroll?.intent, .bottom(animated: false))
        XCTAssertTrue(model.isAtLiveEdge)
    }

    func testUnavailableUnreadBoundarySilentlyFallsBackToLatest() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...2, newerCursor: MessageID(2))),
            .success(try historyPage(ids: 40...41, newerCursor: MessageID(41))),
            .success(try livePage(ids: 98...99)),
        ])
        model.updateReadState(unreadCount: 3, lastReadMessageID: MessageID(39))
        await model.open(position: .message(MessageID(1)))
        reportVisible([MessageID(2)], to: model)
        await model.jumpTowardLatest()
        XCTAssertEqual(source.queries[1].around, MessageID(39))
        XCTAssertEqual(model.rows.compactMap(\.messageID), [MessageID(98), MessageID(99)])
        XCTAssertEqual(model.updates.value.pendingScroll?.intent, .bottom(animated: false))
        XCTAssertNil(model.state.repositionFailure)
    }

    func testJumpDoesNotGoBackToUnreadBoundaryBeforeTheVisibleWindow() async throws {
        let (model, source, _) = try makeModel(pages: [.success(try livePage(ids: 98...99))])
        model.updateReadState(unreadCount: 2, lastReadMessageID: MessageID(50))
        await model.open()
        reportVisible([MessageID(98)], to: model)
        await model.jumpTowardLatest()
        XCTAssertEqual(model.updates.value.pendingScroll?.intent, .bottom(animated: true))
        XCTAssertEqual(source.queries.count, 1)
    }

    func testUnreadBadgeUsesAuthoritativeMetadataWithoutAddingDeferredArrivals() async throws {
        let (model, source, _) = try makeModel(pages: [
            .success(try historyPage(ids: 1...3, newerCursor: MessageID(3)))
        ])
        model.updateReadState(unreadCount: 8, lastReadMessageID: MessageID(1))
        await model.open(position: .unread(after: MessageID(1)))
        reportVisible([MessageID(2)], to: model)
        source.store.apply(.message(try TimelineTestFixtures.message(id: 4, at: 4)))
        XCTAssertEqual(
            model.jumpUnreadCount, 8,
            "The same incoming message is already included in server unread metadata.")
        model.updateReadState(unreadCount: 5, lastReadMessageID: MessageID(2))
        XCTAssertEqual(
            model.jumpUnreadCount, 5, "A read confirmation updates the current conversation badge.")
        model.updateReadState(unreadCount: 0, lastReadMessageID: MessageID(4))
        XCTAssertEqual(model.jumpUnreadCount, 0)
        XCTAssertTrue(
            model.showsJumpToLatest,
            "Deferred live messages keep navigation available without inventing an unread badge.")
    }

    func testHistoricalEntrySuppressesKnownReadsWithoutConsumingImmediateAcknowledgement()
        async throws
    {
        var marked: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...5))], markRead: { marked.append($0) })
        model.updateReadState(unreadCount: 1, lastReadMessageID: MessageID(4))
        model.setReadTrackingActive(true)
        await model.open(position: .message(MessageID(2)))
        reportVisible([MessageID(2)], to: model)
        await source.drain()
        XCTAssertTrue(marked.isEmpty, "Historical entry must not acknowledge already-read rows.")
        reportVisible([MessageID(3)], to: model)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(marked.isEmpty, "Scrolling behind the known cursor needs no acknowledgement.")
        reportVisible([MessageID(5)], to: model)
        await source.drain()
        XCTAssertEqual(
            marked, [MessageID(5)], "The first genuinely unread visible candidate is immediate.")
        model.close()
    }

    func testReactivationKeepsDwellButReopeningAllowsAnotherImmediateVisibleRead() async throws {
        var marked: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [
                .success(try livePage(ids: 1...4)),
                .success(try livePage(ids: 1...4)),
            ], markRead: { marked.append($0) })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(1)])
        model.setReadTrackingActive(false)
        model.setReadTrackingActive(true)
        reportVisible([MessageID(2)], to: model)
        await source.drain()
        XCTAssertEqual(
            marked, [MessageID(1)], "Foreground activation is not a new conversation entry.")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(marked, [MessageID(1), MessageID(2)])
        model.close()
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(3)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(1), MessageID(2), MessageID(3)])
        reportVisible([MessageID(4)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(1), MessageID(2), MessageID(3)])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(marked, [MessageID(1), MessageID(2), MessageID(3), MessageID(4)])
        model.close()
    }

    func testCancelledEntryReadDoesNotConsumeFirstValidActiveViewport() async throws {
        var marked: [MessageID] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...2))], markRead: { marked.append($0) })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(1)], to: model)
        model.setReadTrackingActive(false)
        model.setReadTrackingActive(true)
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertEqual(
            marked, [MessageID(1)],
            "Cancellation before sending must leave the fresh visible candidate eligible.")
        model.close()
    }

    func testReopenedEntryImmediateReadWaitsForCancelledInFlightWrite() async throws {
        var marked: [MessageID] = []
        var releaseFirst: CheckedContinuation<Void, Never>?
        let (model, source, _) = try makeModel(
            pages: [
                .success(try livePage(ids: 1...3)),
                .success(try livePage(ids: 1...3)),
            ],
            markRead: { id in
                marked.append(id)
                if id == MessageID(1) { await withCheckedContinuation { releaseFirst = $0 } }
            })
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertEqual(marked, [MessageID(1)])
        model.close()
        model.setReadTrackingActive(true)
        await model.open()
        reportVisible([MessageID(2)], to: model)
        await source.drain()
        XCTAssertEqual(
            marked, [MessageID(1)],
            "Cancelled callbacks may ignore cancellation; entries cannot overlap writes.")
        releaseFirst?.resume()
        await source.drain()
        XCTAssertEqual(
            marked, [MessageID(1), MessageID(2)],
            "The first visible candidate in the new entry needs no dwell after serialization.")
        model.close()
    }

    func testThreadReadMetadataAndImmediateReadStayScopedWhileJumpGoesToLatest() async throws {
        var marked: [MessageID] = []
        let root = try TimelineTestFixtures.message(id: 1, at: 1)
        let reply = try TimelineTestFixtures.message(
            id: 2, at: 2, fields: ["replyRootId": "1"])
        let latest = try TimelineTestFixtures.message(
            id: 3, at: 3, fields: ["replyRootId": "1"])
        let parentOnly = try TimelineTestFixtures.message(id: 4, at: 4)
        let (model, source, _) = try makeModel(
            pages: [.success(try TimelineTestFixtures.page([root, reply, latest, parentOnly]))],
            threadID: "1", markRead: { marked.append($0) }
        )
        model.updateReadState(unreadCount: 2, lastReadMessageID: MessageID(1))
        model.setReadTrackingActive(true)
        await model.open(position: .unread(after: MessageID(1)))
        reportVisible([MessageID(1)], to: model)
        await source.drain()
        XCTAssertTrue(marked.isEmpty, "A visible topic root is not topic read progress.")
        reportVisible([MessageID(2)], to: model)
        await source.drain()
        XCTAssertEqual(
            marked, [MessageID(2)], "The first unread topic reply is acknowledged immediately.")
        model.updateReadState(unreadCount: 1, lastReadMessageID: MessageID(2))
        reportVisible([MessageID(1)], to: model)
        await model.jumpTowardLatest()
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent, .bottom(animated: true),
            "Thread jump does not stop at the chat-only read boundary.")
        XCTAssertEqual(model.jumpUnreadCount, 1)
        XCTAssertEqual(
            model.rows.compactMap(\.messageID), [MessageID(1), MessageID(2), MessageID(3)])
        XCTAssertEqual(source.queries.first?.threadID, "1")
        model.close()
    }

    func testActivityResumeReusesLoadedResultsAndReconnectRefreshesScopedStreams() async throws {
        for isGroup in [false, true] {
            for scope in [nil, "1"] as [String?] {
                var mentions: [String?] = []
                var reactions: [String?] = []
                let (model, source, _) = try makeModel(
                    pages: [], threadID: scope, isGroupChat: isGroup,
                    fetchUnreadMentions: {
                        mentions.append($0)
                        return .init(messageIds: [])
                    },
                    fetchUnreadReactions: { scope, after in
                        XCTAssertNil(after, "Reconnect starts from a full snapshot.")
                        reactions.append(scope)
                        return .init(messageIds: [], readThrough: "snapshot")
                    })
                model.updateReadState(unreadCount: 0, lastReadMessageID: nil)
                model.setReadTrackingActive(true)
                await source.drain()
                model.setReadTrackingActive(false)
                await source.drain()
                XCTAssertEqual(reactions.count, 1, "Background invalidations do not query.")
                model.setReadTrackingActive(true)
                await source.drain()
                XCTAssertEqual(reactions.count, 1, "Successful foreground data remains fresh.")
                XCTAssertEqual(mentions.count, isGroup ? 1 : 0)
                model.setRealtimeStatus(.reconnecting)
                await source.drain()
                model.setRealtimeStatus(.connected)
                await source.drain()
                XCTAssertEqual(reactions.count, 2)
                XCTAssertTrue(reactions.allSatisfy { $0 == scope })
                XCTAssertEqual(mentions.count, isGroup ? 2 : 0)
                XCTAssertTrue(mentions.allSatisfy { $0 == scope })
                model.close()
            }
        }
    }

    func testReactionRegionDwellIsIndependentOfMessageCursorAndPreservesOffscreenTargets()
        async throws
    {
        let reading = expectation(description: "Visible message read sent")
        var releaseRead: CheckedContinuation<Void, Never>?
        var boundaries: [String?] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...3))],
            markRead: { _ in
                await withCheckedContinuation {
                    releaseRead = $0
                    reading.fulfill()
                }
            },
            fetchUnreadMentions: { _ in .init(messageIds: [MessageID(1), MessageID(2)]) },
            fetchUnreadReactions: { _, _ in
                .init(messageIds: [MessageID(1), MessageID(2)], readThrough: "snapshot")
            },
            acknowledgeReactions: { _, boundary in
                boundaries.append(boundary)
                return .init(unreadReactions: 0)
            })
        await model.open()
        model.setReadTrackingActive(true)
        await source.drain()
        reportVisible([MessageID(2)], to: model)
        await fulfillment(of: [reading], timeout: 2)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(
            boundaries.isEmpty, "Fetching or seeing the body never acknowledges reactions.")
        XCTAssertEqual(model.unreadMentionJumpCount, 2)
        XCTAssertEqual(model.unreadReactionJumpCount, 2)
        reportVisible([MessageID(2)], to: model, reactions: [MessageID(2)])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.unreadReactionJumpCount, 1)
        XCTAssertTrue(boundaries.isEmpty, "Offscreen targets keep the snapshot unacknowledged.")
        releaseRead?.resume()
        await source.drain()
        XCTAssertEqual(
            model.unreadMentionJumpCount, 0, "Mentions at or below the shared cursor clear.")
        model.setReadTrackingActive(false)
        reportVisible([MessageID(1)], to: model, reactions: [MessageID(1)])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.unreadReactionJumpCount, 1)
        model.setReadTrackingActive(true)
        reportVisible([MessageID(1)], to: model, reactions: [MessageID(1)])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.unreadReactionJumpCount, 0)
        XCTAssertEqual(boundaries, ["snapshot"])
        model.close()
    }

    func testReactionSnapshotsUseIncrementalBoundsRearmViewedMessagesAndRetainBoundaryAfterAck()
        async throws
    {
        var afters: [String?] = []
        var boundaries: [String?] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...3))],
            fetchUnreadReactions: { _, after in
                afters.append(after)
                switch afters.count {
                case 1:
                    return .init(messageIds: [MessageID(1), MessageID(2)], readThrough: "first")
                case 2: return .init(messageIds: [MessageID(1)], readThrough: "second")
                default: return .init(messageIds: [], readThrough: "empty-delta")
                }
            },
            acknowledgeReactions: { _, boundary in
                boundaries.append(boundary)
                return .init(unreadReactions: 0)
            })
        await model.open()
        model.setReadTrackingActive(true)
        await source.drain()
        reportVisible([MessageID(1)], to: model, reactions: [MessageID(1)])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.unreadReactionJumpCount, 1)
        reportVisible([], to: model)
        model.refreshUnreadActivity(mentions: false)
        await source.drain()
        XCTAssertEqual(afters, [nil, "first"])
        XCTAssertEqual(
            model.unreadReactionJumpCount, 2, "A delta rearms an already viewed message.")
        XCTAssertTrue(boundaries.isEmpty)
        reportVisible(
            [MessageID(1), MessageID(2)], to: model, reactions: [MessageID(1), MessageID(2)])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(boundaries, ["second"], "All targets use the latest accepted boundary.")
        model.refreshUnreadActivity(mentions: false)
        await source.drain()
        model.refreshUnreadActivity(mentions: false)
        await source.drain()
        XCTAssertEqual(afters, [nil, "first", "second", "empty-delta"])
        XCTAssertEqual(
            boundaries, ["second"], "Empty deltas advance the query bound without a write.")
        model.close()
    }

    func testActivityInvalidationsCoalesceIndependentlyWhileRequestsAreInFlight() async throws {
        let held = expectation(description: "Both streams held")
        held.expectedFulfillmentCount = 2
        let rerun = expectation(description: "Both dirty streams rerun")
        rerun.expectedFulfillmentCount = 2
        var releaseMention: CheckedContinuation<Void, Never>?
        var releaseReaction: CheckedContinuation<Void, Never>?
        var mentions = 0
        var reactions = 0
        var acknowledgements = 0
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...3))],
            fetchUnreadMentions: { _ in
                mentions += 1
                if mentions == 1 {
                    await withCheckedContinuation {
                        releaseMention = $0
                        held.fulfill()
                    }
                } else {
                    rerun.fulfill()
                }
                return .init(messageIds: [MessageID(2)])
            },
            fetchUnreadReactions: { _, _ in
                reactions += 1
                if reactions == 1 {
                    await withCheckedContinuation {
                        releaseReaction = $0
                        held.fulfill()
                    }
                } else {
                    rerun.fulfill()
                }
                return .init(messageIds: [MessageID(3)], readThrough: "boundary")
            },
            acknowledgeReactions: { _, _ in
                acknowledgements += 1
                return .init(unreadReactions: 0)
            })
        model.setReadTrackingActive(true)
        await fulfillment(of: [held], timeout: 2)
        for _ in 0..<3 { model.refreshUnreadActivity() }
        await model.open()
        XCTAssertEqual(mentions, 1)
        XCTAssertEqual(reactions, 1)
        releaseMention?.resume()
        releaseReaction?.resume()
        await fulfillment(of: [rerun], timeout: 2)
        await source.drain()
        XCTAssertEqual(mentions, 2)
        XCTAssertEqual(reactions, 2)
        XCTAssertEqual(acknowledgements, 0, "Unviewed snapshots never acknowledge activity.")
        XCTAssertEqual(model.unreadMentionJumpCount, 1)
        XCTAssertEqual(model.unreadReactionJumpCount, 1)
        model.close()
    }

    func testFailedReactionGetDoesNotAcknowledgeOrDiscardTargets() async throws {
        var fetches = 0
        var acknowledgements = 0
        let (model, source, _) = try makeModel(
            pages: [],
            fetchUnreadReactions: { _, after in
                XCTAssertEqual(after, fetches == 0 ? nil : "same")
                fetches += 1
                if fetches == 2 { throw StubError() }
                return .init(messageIds: fetches == 1 ? [MessageID(2)] : [], readThrough: "same")
            },
            acknowledgeReactions: { _, _ in
                acknowledgements += 1
                return .init(unreadReactions: 0)
            })
        model.setReadTrackingActive(true)
        await source.drain()
        model.refreshUnreadActivity(mentions: false)
        await source.drain()
        XCTAssertEqual(fetches, 2)
        XCTAssertEqual(acknowledgements, 0)
        XCTAssertEqual(model.unreadReactionJumpCount, 1)
        model.refreshUnreadActivity(mentions: false)
        await source.drain()
        XCTAssertEqual(acknowledgements, 0)
        XCTAssertEqual(
            model.unreadReactionJumpCount, 1, "An empty snapshot does not replace the queue.")
        model.close()
    }

    func testBackgroundFencesLateReactionGetAndRestoreWaitsForSingleFlight() async throws {
        let held = expectation(description: "GET held")
        let restored = expectation(description: "Restored session fetched")
        var release: CheckedContinuation<Void, Never>?
        var fetches = 0
        var boundaries: [String?] = []
        let (model, source, _) = try makeModel(
            pages: [],
            fetchUnreadReactions: { _, after in
                XCTAssertNil(after, "Discarded snapshots must not become the incremental bound.")
                fetches += 1
                let request = fetches
                if request == 1 {
                    await withCheckedContinuation {
                        release = $0
                        held.fulfill()
                    }
                } else {
                    restored.fulfill()
                }
                return .init(messageIds: [MessageID(UInt64(request))], readThrough: "\(request)")
            },
            acknowledgeReactions: { _, boundary in
                boundaries.append(boundary)
                XCTFail("Unviewed snapshots must not be acknowledged")
                return .init(unreadReactions: 0)
            })
        model.setReadTrackingActive(true)
        await fulfillment(of: [held], timeout: 2)
        model.setReadTrackingActive(false)
        model.setReadTrackingActive(true)
        await source.drain()
        XCTAssertEqual(fetches, 1, "Cancellation-ignoring GETs cannot overlap on restore.")
        release?.resume()
        await fulfillment(of: [restored], timeout: 2)
        await source.drain()
        XCTAssertTrue(boundaries.isEmpty, "A backgrounded response must never be acknowledged.")
        XCTAssertEqual(model.unreadReactionJumpCount, 1)
        model.close()
    }

    func testForegroundLeaveAcknowledgesSavedThreadScopeWithoutBoundaryAndClearsQueues()
        async throws
    {
        var scopes: [String?] = []
        var boundaries: [String?] = []
        let leave = expectation(description: "Final scoped acknowledgement")
        let (model, source, _) = try makeModel(
            pages: [], threadID: "42",
            fetchUnreadReactions: { _, _ in
                .init(messageIds: [MessageID(43)], readThrough: "snapshot")
            },
            acknowledgeReactions: { scope, boundary in
                scopes.append(scope)
                boundaries.append(boundary)
                if boundary == nil { leave.fulfill() }
                return .init(unreadReactions: 0)
            })
        model.setReadTrackingActive(true)
        await source.drain()
        model.close(acknowledgingActivity: true)
        await fulfillment(of: [leave], timeout: 2)
        XCTAssertEqual(scopes, ["42"])
        XCTAssertEqual(boundaries, [nil])
        XCTAssertEqual(model.unreadReactionJumpCount, 0)
    }

    func testAccountResetFencesLateActivityAndCannotReactivateOldAccount() async throws {
        let held = expectation(description: "GET held")
        var release: CheckedContinuation<Void, Never>?
        var fetches = 0
        var acknowledgements = 0
        let (model, source, _) = try makeModel(
            pages: [],
            fetchUnreadReactions: { _, _ in
                fetches += 1
                await withCheckedContinuation {
                    release = $0
                    held.fulfill()
                }
                return .init(messageIds: [MessageID(2)], readThrough: "old-account")
            },
            acknowledgeReactions: { _, _ in
                acknowledgements += 1
                return .init(unreadReactions: 0)
            })
        model.setReadTrackingActive(true)
        await fulfillment(of: [held], timeout: 2)
        source.store.reset()
        release?.resume()
        await source.drain()
        model.setReadTrackingActive(true)
        model.refreshUnreadActivity()
        model.close(acknowledgingActivity: true)
        await source.drain()
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(acknowledgements, 0)
        XCTAssertEqual(model.unreadReactionJumpCount, 0)
    }

    func testActivityJumpsOldestFirstSkipMissingAndRetainTransientFailures() async throws {
        let (model, source, _) = try makeModel(
            pages: [
                .success(try livePage(ids: 10...12)),
                .success(try livePage(ids: 10...12)),
                .failure(StubError()),
                .success(try historyPage(ids: 1...3, newerCursor: MessageID(3))),
            ],
            fetchUnreadMentions: { _ in
                .init(messageIds: [MessageID(11), MessageID(2), MessageID(1), MessageID(2)])
            })
        await model.open()
        model.setReadTrackingActive(true)
        await source.drain()
        XCTAssertEqual(model.unreadMentionJumpCount, 3)
        await model.jumpToNextMention()
        XCTAssertEqual(source.queries.suffix(2).map(\.around), [MessageID(1), MessageID(2)])
        XCTAssertEqual(
            model.unreadMentionJumpCount, 2, "Missing is removed; transient failure stays.")
        await model.jumpToNextMention()
        XCTAssertEqual(model.unreadMentionJumpCount, 1)
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent,
            .reveal(
                .message(TimelineTestFixtures.stableKey("client-2")), animated: false,
                highlight: true))
        model.close()
    }

    func testActivityJumpSingleFlightAndRealtimeDeletionPrunesBothQueues() async throws {
        let (model, source, _) = try makeModel(
            pages: [
                .success(try livePage(ids: 10...12)),
                .success(try historyPage(ids: 1...3, newerCursor: MessageID(3))),
            ],
            fetchUnreadMentions: { _ in .init(messageIds: [MessageID(2), MessageID(11)]) },
            fetchUnreadReactions: { _, _ in
                .init(messageIds: [MessageID(2), MessageID(11)], readThrough: "snapshot")
            })
        await model.open()
        model.setReadTrackingActive(true)
        await source.drain()
        source.holdNextRequest()
        let jump = Task { await model.jumpToNextMention() }
        await source.waitUntilHeld()
        XCTAssertTrue(model.activityJumpInProgress)
        await model.jumpToNextReaction()
        XCTAssertEqual(source.queries.count, 2)
        source.store.apply(.messageDeleted(try TimelineTestFixtures.message(id: 11, at: 11)))
        XCTAssertEqual(model.unreadMentionJumpCount, 1)
        XCTAssertEqual(model.unreadReactionJumpCount, 1)
        source.release()
        await jump.value
        XCTAssertFalse(model.activityJumpInProgress)
        XCTAssertEqual(model.unreadMentionJumpCount, 0)
        XCTAssertEqual(model.unreadReactionJumpCount, 1)
        model.close()
    }

    func testInvalidationDuringReactionAckWaitsThenFetchesWithoutAcknowledgingNewTargets()
        async throws
    {
        let held = expectation(description: "ACK held")
        let rerun = expectation(description: "Dirty delta fetched")
        var release: CheckedContinuation<Void, Never>?
        var fetches = 0
        var boundaries: [String?] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...3))],
            fetchUnreadReactions: { _, after in
                fetches += 1
                if fetches == 2 {
                    XCTAssertEqual(after, "1")
                    rerun.fulfill()
                }
                return .init(messageIds: [MessageID(UInt64(fetches))], readThrough: "\(fetches)")
            },
            acknowledgeReactions: { _, boundary in
                boundaries.append(boundary)
                await withCheckedContinuation {
                    release = $0
                    held.fulfill()
                }
                return .init(unreadReactions: 0)
            })
        await model.open()
        model.setReadTrackingActive(true)
        await source.drain()
        reportVisible([MessageID(1)], to: model, reactions: [MessageID(1)])
        await fulfillment(of: [held], timeout: 2)
        for _ in 0..<3 { model.refreshUnreadActivity(mentions: false) }
        await source.drain()
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(boundaries, ["1"])
        reportVisible([], to: model)
        release?.resume()
        await fulfillment(of: [rerun], timeout: 2)
        await source.drain()
        XCTAssertEqual(boundaries, ["1"])
        XCTAssertEqual(model.unreadReactionJumpCount, 1)
        model.close()
    }

    func testReopenFencesPendingFinalAckAndCoveredLeaveAcknowledgesEnteredScope() async throws {
        let held = expectation(description: "Old GET held")
        let restored = expectation(description: "New session fetched")
        var release: CheckedContinuation<Void, Never>?
        var fetches = 0
        var boundaries: [String?] = []
        let (model, source, _) = try makeModel(
            pages: [],
            fetchUnreadReactions: { _, after in
                XCTAssertNil(after)
                fetches += 1
                let request = fetches
                if request == 1 {
                    await withCheckedContinuation {
                        release = $0
                        held.fulfill()
                    }
                } else {
                    restored.fulfill()
                }
                return .init(messageIds: [MessageID(UInt64(request))], readThrough: "\(request)")
            },
            acknowledgeReactions: { _, boundary in
                boundaries.append(boundary)
                return .init(unreadReactions: 0)
            })
        model.setReadTrackingActive(true)
        await fulfillment(of: [held], timeout: 2)
        model.close(acknowledgingActivity: true)
        model.setReadTrackingActive(true)
        await source.drain()
        XCTAssertEqual(fetches, 1)
        release?.resume()
        await fulfillment(of: [restored], timeout: 2)
        await source.drain()
        XCTAssertTrue(boundaries.isEmpty, "A final ACK cannot cross an immediate reopen.")
        model.setReadTrackingActive(false)
        model.close(acknowledgingActivity: true)
        await source.drain()
        XCTAssertEqual(boundaries, [nil], "Covering the view retains its entered reaction session.")
    }

    func testDeletedCachedTargetsAndHTTPNotFoundAreMissingNotTransientFailures() async throws {
        let deleted = try TimelineTestFixtures.message(id: 1, at: 1).redactedForDeletion()
        let (model, source, _) = try makeModel(
            pages: [
                .success(try TimelineTestFixtures.page([deleted])),
                .failure(APIError.invalidResponse(statusCode: 404)),
            ],
            fetchUnreadMentions: { _ in .init(messageIds: [MessageID(1), MessageID(2)]) })
        await model.open()
        model.setReadTrackingActive(true)
        await source.drain()
        XCTAssertEqual(model.unreadMentionJumpCount, 1, "Cached tombstones never become targets.")
        let cached = await model.jumpToMessage(MessageID(1))
        XCTAssertEqual(cached, .missing)
        XCTAssertEqual(source.queries.count, 1)
        await model.jumpToNextMention()
        XCTAssertEqual(
            model.unreadMentionJumpCount, 0, "HTTP 404 drops a confirmed missing target.")
        model.close()
    }

    func testAccountResetAfterCloseCancelsDeferredFinalAcknowledgement() async throws {
        let held = expectation(description: "Old GET held")
        var release: CheckedContinuation<Void, Never>?
        var acknowledgements = 0
        let (model, source, _) = try makeModel(
            pages: [],
            fetchUnreadReactions: { _, _ in
                await withCheckedContinuation {
                    release = $0
                    held.fulfill()
                }
                return .init(messageIds: [MessageID(2)], readThrough: "old-account")
            },
            acknowledgeReactions: { _, _ in
                acknowledgements += 1
                return .init(unreadReactions: 0)
            })
        model.setReadTrackingActive(true)
        await fulfillment(of: [held], timeout: 2)
        model.close(acknowledgingActivity: true)
        source.store.reset()
        release?.resume()
        await source.drain()
        XCTAssertEqual(
            acknowledgements, 0, "Unregistered old models cannot acknowledge a new account.")
    }

    func testReactionDwellRequiresContinuousVisibilityAndRestartsForNewNotification() async throws {
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...2))],
            fetchUnreadReactions: { _, _ in
                .init(messageIds: [MessageID(1)], readThrough: "snapshot")
            })
        await model.open()
        model.setReadTrackingActive(true)
        await source.drain()
        reportVisible([MessageID(1)], to: model, reactions: [MessageID(1)])
        try await Task.sleep(for: .milliseconds(300))
        reportVisible([MessageID(1)], to: model)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.unreadReactionJumpCount, 1, "Separate exposures must not accumulate.")
        reportVisible([MessageID(1)], to: model, reactions: [MessageID(1)])
        try await Task.sleep(for: .milliseconds(300))
        model.refreshUnreadActivity(mentions: false, reactionMessageID: MessageID(1))
        await source.drain()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(
            model.unreadReactionJumpCount, 1, "A new reaction restarts the visible dwell.")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.unreadReactionJumpCount, 0)
        model.close()
    }

    func testFailedBoundedReactionAckRetriesOnResumeWithoutLosingQueryBoundary() async throws {
        var afters: [String?] = []
        var boundaries: [String?] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...2))],
            fetchUnreadReactions: { _, after in
                afters.append(after)
                return .init(
                    messageIds: after == nil ? [MessageID(1)] : [], readThrough: "snapshot")
            },
            acknowledgeReactions: { _, boundary in
                boundaries.append(boundary)
                if boundaries.count == 1 { throw StubError() }
                return .init(unreadReactions: 0)
            })
        await model.open()
        model.setReadTrackingActive(true)
        await source.drain()
        reportVisible([MessageID(1)], to: model, reactions: [MessageID(1)])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(boundaries, ["snapshot"])
        XCTAssertEqual(model.unreadReactionJumpCount, 0)
        model.setReadTrackingActive(false)
        model.setReadTrackingActive(true)
        await source.drain()
        XCTAssertEqual(boundaries, ["snapshot", "snapshot"])
        XCTAssertEqual(afters, [nil], "Retry the write, not the already accepted snapshot.")
        model.refreshUnreadActivity(mentions: false)
        await source.drain()
        XCTAssertEqual(afters, [nil, "snapshot"])
        model.close()
    }

    func testReconnectDiscardsInFlightDeltaAndRearmsPreviouslyViewedMessage() async throws {
        let held = expectation(description: "Delta held")
        let refreshed = expectation(description: "Full reconnect snapshot accepted")
        var release: CheckedContinuation<Void, Never>?
        var afters: [String?] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...2))],
            fetchUnreadReactions: { _, after in
                afters.append(after)
                if afters.count == 2 {
                    await withCheckedContinuation {
                        release = $0
                        held.fulfill()
                    }
                    return .init(messageIds: [MessageID(2)], readThrough: "obsolete")
                }
                if afters.count == 3 { refreshed.fulfill() }
                return .init(messageIds: [MessageID(1)], readThrough: "accepted")
            })
        await model.open()
        model.setReadTrackingActive(true)
        await source.drain()
        reportVisible([MessageID(1)], to: model, reactions: [MessageID(1)])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.unreadReactionJumpCount, 0)
        reportVisible([], to: model)
        model.refreshUnreadActivity(mentions: false)
        await fulfillment(of: [held], timeout: 2)
        model.setRealtimeStatus(.reconnecting)
        model.setRealtimeStatus(.connected)
        release?.resume()
        await fulfillment(of: [refreshed], timeout: 2)
        await source.drain()
        XCTAssertEqual(afters, [nil, "accepted", nil])
        XCTAssertEqual(model.unreadReactionJumpCount, 1, "Reconnect rearms the missed reaction.")
        model.refreshUnreadActivity(mentions: false)
        await source.drain()
        XCTAssertEqual(afters.last!, "accepted", "An obsolete delta never advances the boundary.")
        model.close()
    }

    func testReactionJumpRetainsTargetUntilRegionDwellAndSkipsMissingReactionRegion() async throws {
        let reactionMessage = try TimelineTestFixtures.message(
            id: 2, at: 2,
            fields: ["reactions": [["emoji": "like", "count": 3, "reactors": [["uid": 2]]]]])
        let page = try TimelineTestFixtures.page([
            TimelineTestFixtures.message(id: 1, at: 1), reactionMessage,
        ])
        let (model, source, _) = try makeModel(
            pages: [.success(page)],
            fetchUnreadReactions: { _, _ in
                .init(messageIds: [MessageID(1), MessageID(2)], readThrough: "snapshot")
            })
        await model.open()
        model.setReadTrackingActive(true)
        await source.drain()
        await model.jumpToNextReaction()
        XCTAssertEqual(model.unreadReactionJumpCount, 1, "A missing reaction region is handled.")
        XCTAssertEqual(
            model.updates.value.pendingScroll?.intent,
            .reaction(.message(reactionMessage.timelineStableKey), animated: true, highlight: true))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.unreadReactionJumpCount, 1, "Jump completion alone is not a read.")
        reportVisible([MessageID(2)], to: model, reactions: [MessageID(2)])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.unreadReactionJumpCount, 0)
        model.close()
    }

    func testUnreadAfterBoundedAckFetchesDeltaButWaitsForNewTargetToBeViewed() async throws {
        var fetches = 0
        var boundaries: [String?] = []
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...2))],
            fetchUnreadReactions: { _, after in
                fetches += 1
                XCTAssertEqual(after, fetches == 1 ? nil : "first")
                return .init(
                    messageIds: [MessageID(fetches == 1 ? 1 : 2)],
                    readThrough: fetches == 1 ? "first" : "second")
            },
            acknowledgeReactions: { _, boundary in
                boundaries.append(boundary)
                return .init(unreadReactions: boundaries.count == 1 ? 1 : 0)
            })
        await model.open()
        model.setReadTrackingActive(true)
        await source.drain()
        reportVisible([MessageID(1)], to: model, reactions: [MessageID(1)])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(fetches, 2)
        XCTAssertEqual(boundaries, ["first"])
        XCTAssertEqual(model.unreadReactionJumpCount, 1)
        reportVisible([MessageID(2)], to: model, reactions: [MessageID(2)])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(boundaries, ["first", "second"])
        model.close()
    }

    func testReactionDwellCancelsOnNavigationPublicationAndInvalidViewport() async throws {
        let (model, source, _) = try makeModel(
            pages: [.success(try livePage(ids: 1...2))],
            fetchUnreadReactions: { _, _ in
                .init(messageIds: [MessageID(1)], readThrough: "snapshot")
            })
        await model.open()
        model.setReadTrackingActive(true)
        await source.drain()
        reportVisible([MessageID(1)], to: model, reactions: [MessageID(1)])
        await model.jumpToMessage(MessageID(2))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.unreadReactionJumpCount, 1)
        reportVisible([MessageID(1)], to: model, reactions: [MessageID(1)])
        source.store.apply(.message(try TimelineTestFixtures.message(id: 3, at: 3)))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.unreadReactionJumpCount, 1)
        reportVisible([MessageID(1)], to: model, reactions: [MessageID(1)])
        model.viewportDidChange(.empty, reason: .layout, revision: model.updates.value.revision)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.unreadReactionJumpCount, 1)
        reportVisible([MessageID(1)], to: model, reactions: [MessageID(1)])
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.unreadReactionJumpCount, 0)
        model.close()
    }

    private func reportVisible(
        _ ids: [MessageID], to model: ConversationTimelineModel, revision: Int? = nil,
        reason: TimelineViewportChangeReason = .layout, distanceToBottom: CGFloat = 5_000,
        distanceToTop: CGFloat = 5_000, reactions: [MessageID] = []
    ) {
        if let request = model.updates.value.pendingScroll {
            model.scrollRequestDidFinish(id: request.id)
        }
        let first = ids.first.flatMap { id in model.rows.firstIndex { $0.messageID == id } } ?? 0
        let last =
            ids.last.flatMap { id in model.rows.firstIndex { $0.messageID == id } } ?? model.rows
            .count - 1
        var viewport = TimelineViewport(
            firstVisibleIndex: first, lastVisibleIndex: last, distanceToTop: distanceToTop,
            distanceToBottom: distanceToBottom, height: 400)
        viewport.visibleMessageIDs = ids
        viewport.visibleReactionMessageIDs = reactions
        model.viewportDidChange(
            viewport, reason: reason, revision: revision ?? model.updates.value.revision)
    }

    private func remoteMessages(_ model: ConversationTimelineModel) -> [MessageResponse] {
        model.rows.compactMap {
            guard case .message(let row) = $0 else { return nil }
            return row.entry.remoteMessage
        }
    }

    private func pending(id: String) -> PendingOutgoingMessage {
        TimelineTestFixtures.pending(id: id, text: "sending", phase: .sending)
    }

    private func reactionFixture() throws -> [ReactionSummary] {
        try JSONDecoder().decode(
            [ReactionSummary].self,
            from: Data(
                "[{\"emoji\":\"like\",\"count\":3,\"reactors\":[{\"uid\":2}]}]".utf8
            ))
    }

    // MARK: Helpers

    private func makeHistoryCache() async throws -> (AccountHistoryCache, ChahuaLocalStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TimelineHistory-\(UUID().uuidString)")
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let local = try await Task.detached {
            try ChahuaLocalStore(directory: root, userID: 1)
        }.value
        let owner = AccountLocalStoreOwner(factory: { _ in local })
        owner.setSession(uid: 1)
        let cache = AccountHistoryCache(owner: owner)
        cache.setSession(uid: 1)
        return (cache, local)
    }

    private func seedSyncTail(
        _ messages: [MessageResponse], for key: ConversationKey, at cursor: String,
        in local: ChahuaLocalStore
    ) async throws {
        let epoch = try await local.cacheEpoch()
        try await local.resetSyncChat(
            chatID: key.chatID, cursor: cursor, purge: false, epoch: epoch)
        let accepted = try await local.cacheHistory(
            key, query: .init(max: 50), response: .init(messages: messages), at: cursor,
            epoch: epoch)
        XCTAssertTrue(accepted)
    }

    private func makeModel(
        pages: [Result<ListMessagesResponse, Error>],
        threadID: String? = nil,
        isGroupChat: Bool = true,
        markRead: (@MainActor (MessageID) async throws -> Void)? = nil,
        fetchUnreadMentions: (@MainActor (String?) async throws -> UnreadMentionIDsResponse)? = nil,
        fetchUnreadReactions: (
            @MainActor (String?, String?) async throws -> UnreadReactionIDsResponse
        )? =
            nil,
        acknowledgeReactions:
            (@MainActor (String?, String?) async throws -> UnreadReactionsAckResponse)? = nil
    ) throws -> (
        ConversationTimelineModel, ScriptedTimelineSource,
        CurrentValueSubject<[TimelineHostSnapshot], Never>
    ) {
        let source = ScriptedTimelineSource(pages: pages)
        let model = ConversationTimelineModel(
            chatID: "chat",
            currentUserID: 1,
            isGroupChat: isGroupChat,
            source: source,
            messageStore: source.store,
            threadID: threadID,
            markRead: markRead,
            fetchUnreadMentions: fetchUnreadMentions,
            fetchUnreadReactions: fetchUnreadReactions,
            acknowledgeReactions: acknowledgeReactions
        )
        let updates = CurrentValueSubject<[TimelineHostSnapshot], Never>([])
        model.updates.sink { updates.value.append($0) }.store(in: &cancellables)
        return (model, source, updates)
    }

    private func livePage(ids: ClosedRange<Int>) throws -> ListMessagesResponse {
        try historyPage(ids: ids, olderCursor: nil, newerCursor: nil)
    }

    private func historyPage(
        ids: ClosedRange<Int>, olderCursor: MessageID? = nil, newerCursor: MessageID?
    ) throws -> ListMessagesResponse {
        try TimelineTestFixtures.page(
            ids.map {
                try TimelineTestFixtures.message(
                    id: UInt64($0), senderID: Int32($0 % 2 + 1), at: $0 % 60, minute: $0 / 60)
            },
            olderCursor: olderCursor,
            newerCursor: newerCursor
        )
    }
}

private struct StubError: Error {}

@MainActor
private final class SavedRefreshRetryClock {
    private(set) var delays: [Duration] = []
    private var sleeping: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?

    // Deliberately ignores cancellation to exercise the generation and lifecycle fences.
    func sleep(_ delay: Duration) async {
        await withCheckedContinuation { continuation in
            precondition(sleeping == nil)
            delays.append(delay)
            sleeping = continuation
            waiting?.resume()
            waiting = nil
        }
    }

    func waitForSleep() async {
        if sleeping != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func wake() {
        sleeping?.resume()
        sleeping = nil
    }
}

@MainActor
final class ScriptedTimelineSource: TimelineMessageSource {
    let store = ConversationMessageStore()
    private(set) var queries: [ListMessagesQuery] = []
    var syncCoverage: Set<ConversationKey> = []
    var waitForSync: (@MainActor () async throws -> Void)?
    private var pages: [Result<TimelinePage, Error>]
    private var onHold: (() -> Void)?
    private var heldResponse: CheckedContinuation<Void, Never>?
    private var heldWaiter: CheckedContinuation<Void, Never>?

    convenience init(pages: [Result<ListMessagesResponse, Error>]) {
        self.init(timelinePages: pages.map { $0.map { TimelinePage(response: $0) } })
    }

    init(timelinePages: [Result<TimelinePage, Error>]) {
        pages = timelinePages
    }

    func waitForTimelineSync() async throws {
        if let waitForSync { try await waitForSync() }
    }

    func canPromoteCachedTail(_ key: ConversationKey) -> Bool { syncCoverage.contains(key) }

    func fetchMessages(chatID: String, query: ListMessagesQuery) async throws -> TimelinePage {
        queries.append(query)
        precondition(!pages.isEmpty, "Unscripted fetch: \(query)")
        let result = pages.removeFirst()
        if let onHold {
            self.onHold = nil
            await withCheckedContinuation { continuation in
                heldResponse = continuation
                heldWaiter?.resume()
                heldWaiter = nil
                onHold()
            }
        } else {
            await Task.yield()
        }
        return try result.get()
    }

    func holdNextRequest(onHold: @escaping () -> Void = {}) { self.onHold = onHold }

    func waitUntilHeld() async {
        guard heldResponse == nil else { return }
        await withCheckedContinuation { heldWaiter = $0 }
    }

    func release() {
        heldResponse?.resume()
        heldResponse = nil
    }

    /// Lets detached edge-load tasks run to completion.
    func drain() async {
        for _ in 0..<8 { await Task.yield() }
    }
}
