import ChahuaAPI
import Foundation
import os

/// One ordered stream for accepted state across all windows. SQL and payload
/// codecs run on the account writer, not on the main actor.
@MainActor
final class AccountHistoryCache {
    struct PrivacyStamp: Equatable {
        let policy: UInt64
        let chat: UInt64
    }

    struct PageToken {
        fileprivate let revision: UInt64
        fileprivate let serial: UInt64
        fileprivate let key: ConversationKey
        fileprivate let socketAttempt: Int?
        fileprivate let privacyRevision: UInt64
        fileprivate let chatPrivacyRevision: UInt64
    }

    struct ListPageToken {
        let state: ListSyncState
        let request: ListSyncRequest
        let cursor: String?
        fileprivate let revision: UInt64
        fileprivate let epoch: Int64
        fileprivate let privacy: UInt64
        fileprivate let chatPrivacy: [String: UInt64]
    }

    private struct Coverage {
        let key: ConversationKey
        let serial: UInt64
        let bounds: ClosedRange<MessageID>
    }

    private let owner: AccountLocalStoreOwner
    private var uid: Int32?
    private var tail: Task<Void, Never>?
    private var serial: UInt64 = 0
    private var pending = Set<UInt64>()
    private var queuedPages = Set<UInt64>()
    private var accountRevision: UInt64 = 0
    private var privacyRevision: UInt64 = 0
    private var chatPrivacyRevisions: [String: UInt64] = [:]
    private var committed: [Coverage] = []
    private var liveEnds: [ConversationKey: MessageID] = [:]
    private var syncAlignedScopes = Set<ConversationKey>()
    private var socketAttempt: Int?
    private var revoked = Set<String>()
    private var confirmedAccess = Set<String>()
    private var paused = false
    private var signingOut = false
    private var clearing = false
    private(set) var revision: UInt64 = 0
    var isAvailable: Bool { uid != nil && !signingOut && !clearing }
    var onDiskFull: (() -> Void)?
    var onClear: (() -> Void)?

    init(owner: AccountLocalStoreOwner) { self.owner = owner }

    func setSession(uid: Int32?) {
        guard self.uid != uid else { return }
        accountRevision &+= 1
        let prior = tail
        let retiring = owner.store
        resetIngress()
        confirmedAccess.removeAll()
        revoked.removeAll()
        socketAttempt = nil
        signingOut = false
        paused = false
        clearing = false
        self.uid = uid
        let fence = Task {
            await prior?.value
            if let retiring { _ = try? await retiring.advanceCacheEpoch() }
        }
        owner.fenceNextOpen(through: fence)
        tail = fence
    }

    func read<T: Sendable>(_ action: @escaping @Sendable (ChahuaLocalStore) async throws -> T)
        async throws -> T
    {
        guard isAvailable, let uid else { throw CancellationError() }
        let current = revision
        let queued = tail
        await queued?.value
        let store = try await owner.open(uid: uid)
        guard revision == current else { throw CancellationError() }
        let value = try await action(store)
        try Task.checkCancellation()
        guard revision == current else { throw CancellationError() }
        return value
    }

    func submit(
        required: Bool = false,
        _ action: @escaping @Sendable (ChahuaLocalStore, Int64) async throws -> Void
    ) {
        enqueue { cache, store, epoch in
            guard required || !cache.paused else { return }
            try await action(store, epoch)
        }
    }

    /// Read intents are durable account work, not disposable history. Use the
    /// same ordered writer, but let enqueued operations survive Clear History.
    func accessPendingReads<T: Sendable>(
        _ action: @escaping @Sendable (ChahuaLocalStore) async throws -> T
    ) -> Task<T, Error>? {
        guard !signingOut, let uid else { return nil }
        let previous = tail
        let current = accountRevision
        let task = Task { [weak self] in
            await previous?.value
            guard let self, self.accountRevision == current else { throw CancellationError() }
            do {
                let store = try await self.owner.open(uid: uid)
                guard self.accountRevision == current else { throw CancellationError() }
                return try await action(store)
            } catch {
                if self.accountRevision == current { self.report(error) }
                throw error
            }
        }
        tail = Task { _ = await task.result }
        return task
    }

    func fenceForSignOut() async {
        signingOut = true
        clearing = false
        resetIngress()
        await tail?.value
    }

    func resumeAfterSignOutFailure() { signingOut = false }

    func pauseForDiskFull() {
        guard !paused else { return }
        paused = true
        onDiskFull?()
    }

    func clear() async throws {
        guard isAvailable, let uid else { throw CancellationError() }
        let prior = tail
        clearing = true
        resetIngress()
        let current = revision
        let task = Task {
            await prior?.value
            guard revision == current else { throw CancellationError() }
            defer { if revision == current { clearing = false } }
            let store = try await owner.open(uid: uid)
            guard revision == current else { throw CancellationError() }
            try await store.clearMessageHistory()
            guard revision == current else { throw CancellationError() }
            paused = false
            clearing = false
            onClear?()
        }
        tail = Task { _ = await task.result }
        try await task.value
    }

    /// Capture state through the same writer that will accept the response.
    func startListPage(forced: Bool) async throws -> ListPageToken {
        guard
            let task = enqueueSync({ cache, store, epoch in
                let state = try await store.listSyncState(epoch: epoch)
                let request: ListSyncRequest =
                    forced || (state.stagingToken == nil && state.installedToken == nil)
                    ? .forcedStart : (state.stagingToken != nil ? .staged : .installed)
                return ListPageToken(
                    state: state, request: request,
                    cursor: forced ? nil : state.stagingToken ?? state.installedToken,
                    revision: cache.revision, epoch: epoch, privacy: cache.privacyRevision,
                    chatPrivacy: cache.chatPrivacyRevisions)
            }), let token = try await task.value
        else { throw CancellationError() }
        return token
    }

    func commitListPage(
        _ page: ConversationDifference, token: ListPageToken,
        accepting: @escaping @MainActor () -> Bool
    ) async throws -> SyncCommit {
        guard
            let task = enqueueSync({ cache, store, epoch in
                guard cache.revision == token.revision, epoch == token.epoch,
                    cache.privacyRevision == token.privacy,
                    cache.chatPrivacyRevisions == token.chatPrivacy,
                    accepting()
                else { return SyncCommit.stale }
                let rejoins = Set(page.chats.map(\.id))
                let result = try await store.commitListDifference(
                    page, expected: token.state, request: token.request, epoch: epoch,
                    authorizedRejoins: rejoins)
                if result == .committed, cache.revision == token.revision,
                    cache.privacyRevision == token.privacy,
                    cache.chatPrivacyRevisions == token.chatPrivacy
                {
                    cache.revoked.subtract(rejoins)
                    cache.confirmedAccess.formUnion(rejoins)
                }
                return result
            })
        else { return .stale }
        let result = try await task.value
        return revision == token.revision ? result ?? .stale : .stale
    }

    func invalidateListSync() async throws {
        guard
            let task = enqueueSync({ _, store, epoch in
                try await store.invalidateListSync(epoch: epoch)
                return true
            }), try await task.value == true
        else { throw CancellationError() }
    }

    func commitLegacyList(
        _ scope: CachedListScope, items: [CachedConversation], seen: Set<ConversationKey>?,
        accepting: @escaping @MainActor () -> Bool
    ) async throws -> Bool {
        guard
            let task = enqueueSync({ _, store, epoch in
                guard accepting() else { return false }
                try await store.cacheList(scope, items: items, seen: seen, epoch: epoch)
                return true
            })
        else { return false }
        return try await task.value == true
    }

    func syncManifest() async throws -> [MessageSyncCheckpoint] {
        let current = revision
        guard
            let task = enqueueSync({ _, store, epoch in
                try await store.syncResumeManifest(epoch: epoch)
            }), let manifest = try await task.value, revision == current
        else { throw CancellationError() }
        return manifest
    }

    func commitSyncBatch(
        chatID: String, from: String, to: String, changes: [MessageSyncChange]
    ) async throws -> SyncCommit {
        let current = revision
        guard
            let task = enqueueSync({ _, store, epoch in
                try await store.commitSyncBatch(
                    chatID: chatID, from: from, to: to, changes: changes, epoch: epoch)
            })
        else { return .stale }
        let result = try await task.value
        return revision == current ? result ?? .stale : .stale
    }

    func resetSyncChat(chatID: String, cursor: String, purge: Bool) async throws {
        guard isAvailable else { throw CancellationError() }
        if purge {
            chatPrivacyRevisions[chatID, default: 0] &+= 1
            committed.removeAll { $0.key.chatID == chatID }
        }
        liveEnds = liveEnds.filter { $0.key.chatID != chatID }
        syncAlignedScopes = syncAlignedScopes.filter { $0.chatID != chatID }
        let chatPrivacyRevision = chatPrivacyRevisions[chatID, default: 0]
        let current = revision
        guard
            let task = enqueueSync({ cache, store, epoch in
                guard cache.chatPrivacyRevisions[chatID, default: 0] == chatPrivacyRevision,
                    try await store.resetSyncChat(
                        chatID: chatID, cursor: cursor, purge: purge, epoch: epoch),
                    cache.revision == current,
                    cache.chatPrivacyRevisions[chatID, default: 0] == chatPrivacyRevision
                else { throw CancellationError() }
                cache.revoked.remove(chatID)
                return true
            }), try await task.value == true, revision == current
        else { throw CancellationError() }
    }

    private func enqueueSync<T: Sendable>(
        _ action:
            @escaping @MainActor (AccountHistoryCache, ChahuaLocalStore, Int64) async throws -> T
    ) -> Task<T?, Error>? {
        guard isAvailable, let uid else { return nil }
        let previous = tail
        let current = revision
        let task = Task<T?, Error> { [weak self] in
            await previous?.value
            guard let self, self.revision == current else { return nil }
            do {
                let store = try await self.owner.open(uid: uid)
                let epoch = try await store.cacheEpoch()
                guard self.revision == current else { return nil }
                let result = try await action(self, store, epoch)
                return self.revision == current ? result : nil
            } catch {
                guard self.revision == current else { return nil }
                self.report(error)
                throw error
            }
        }
        tail = Task { _ = await task.result }
        return task
    }

    func startPage(_ key: ConversationKey) -> PageToken? {
        guard isAvailable, !revoked.contains(key.chatID) else { return nil }
        serial &+= 1
        pending.insert(serial)
        return PageToken(
            revision: revision, serial: serial, key: key, socketAttempt: socketAttempt,
            privacyRevision: privacyRevision,
            chatPrivacyRevision: chatPrivacyRevisions[key.chatID, default: 0])
    }

    func finishPage(_ token: PageToken) {
        guard !queuedPages.contains(token.serial) else { return }
        pending.remove(token.serial)
        pruneCoverage()
    }

    @discardableResult
    func acceptPage(
        _ token: PageToken, query: ListMessagesQuery, response: ListMessagesResponse,
        journal: [RealtimeServerEvent],
        at: String? = nil
    ) -> Task<Bool, Error>? {
        guard isCurrent(token, at: at), let uid else { return nil }
        queuedPages.insert(token.serial)
        let coverage = Coverage(
            key: token.key, serial: token.serial, bounds: Self.bounds(query, response))
        let replay = journal.compactMap { Self.change($0) }
        let attempt = token.socketAttempt
        let previous = tail
        let task = Task<Bool, Error> { [weak self] in
            await previous?.value
            guard let self else { return false }
            defer {
                self.queuedPages.remove(token.serial)
                self.finishPage(token)
            }
            guard self.isCurrent(token, at: at), !self.paused,
                !self.committed.contains(where: {
                    $0.key.chatID == coverage.key.chatID && $0.serial > coverage.serial
                        && $0.bounds.overlaps(coverage.bounds)
                })
            else { return false }
            do {
                let store = try await self.owner.open(uid: uid)
                let epoch = try await store.cacheEpoch()
                guard self.isCurrent(token, at: at),
                    try await store.cacheHistory(
                        token.key, query: query, response: response, replay: replay, at: at,
                        epoch: epoch),
                    self.isCurrent(token, at: at)
                else { return false }
                self.committed.append(coverage)
                if at == nil {
                    self.syncAlignedScopes.remove(token.key)
                } else if response.newerCursor == nil, query.before == nil {
                    self.syncAlignedScopes.insert(token.key)
                }
                if let attempt, self.socketAttempt == attempt, response.newerCursor == nil,
                    let edge = response.messages.map(\.id).max()
                {
                    self.liveEnds[token.key] = max(self.liveEnds[token.key] ?? edge, edge)
                }
                return true
            } catch {
                if self.isCurrent(token, at: at) { self.report(error) }
                throw error
            }
        }
        tail = Task { _ = await task.result }
        return task
    }

    private func isCurrent(_ token: PageToken, at: String?) -> Bool {
        token.revision == revision && token.privacyRevision == privacyRevision
            && token.chatPrivacyRevision == chatPrivacyRevisions[token.key.chatID, default: 0]
            && !revoked.contains(token.key.chatID)
            && (at == nil || socketAttempt == token.socketAttempt)
    }

    func hasAlignedSyncTail(_ key: ConversationKey) -> Bool { syncAlignedScopes.contains(key) }

    func privacyStamp(chatID: String) -> PrivacyStamp {
        .init(policy: privacyRevision, chat: chatPrivacyRevisions[chatID, default: 0])
    }

    func setSocketAttempt(_ attempt: Int?) {
        guard socketAttempt != attempt else { return }
        socketAttempt = attempt
        liveEnds.removeAll()
        syncAlignedScopes.removeAll()
    }

    func accept(_ event: RealtimeServerEvent, fromSocket: Bool) {
        guard let chatID = event.conversationChatID, !revoked.contains(chatID),
            let mutation = Self.change(event)
        else { return }
        let normalized: CachedMessageChange
        if case .create(let message, let key, _) = mutation, fromSocket, socketAttempt != nil,
            let edge = liveEnds[key], edge < message.id
        {
            normalized = .create(message, key, adjoining: edge)
            liveEnds[key] = message.id
        } else {
            normalized = mutation
        }
        // Redaction must still be attempted when disk pressure pauses growth.
        let required: Bool
        if case .delete = normalized { required = true } else { required = false }
        submit(required: required) { try await $0.cacheChange(normalized, epoch: $1) }
    }

    func invalidatePolicy(
        chatID: String? = nil, policy: MembershipMessagePolicy? = nil, settings: ChatSettings? = nil
    ) {
        if let chatID {
            chatPrivacyRevisions[chatID, default: 0] &+= 1
            liveEnds = liveEnds.filter { $0.key.chatID != chatID }
            syncAlignedScopes = syncAlignedScopes.filter { $0.chatID != chatID }
        } else {
            privacyRevision &+= 1
            liveEnds.removeAll()
            syncAlignedScopes.removeAll()
        }
        enqueue { _, store, epoch in
            try await store.invalidateCachedPolicy(
                chatID: chatID, policy: policy, settings: settings, epoch: epoch)
        }
    }

    func revoke(_ chatID: String) {
        revoked.insert(chatID)
        confirmedAccess.remove(chatID)
        chatPrivacyRevisions[chatID, default: 0] &+= 1
        liveEnds = liveEnds.filter { $0.key.chatID != chatID }
        syncAlignedScopes = syncAlignedScopes.filter { $0.chatID != chatID }
        enqueue { _, store, epoch in try await store.purgeCachedChat(chatID, epoch: epoch) }
    }

    func confirmAccess(_ chatID: String) {
        revoked.remove(chatID)
        guard confirmedAccess.insert(chatID).inserted else { return }
        enqueue { _, store, epoch in try await store.confirmChatAccess(chatID, epoch: epoch) }
    }
    func accessRevoked(_ chatID: String) -> Bool { revoked.contains(chatID) }

    private func enqueue(
        _ action:
            @escaping @MainActor (AccountHistoryCache, ChahuaLocalStore, Int64) async throws -> Void
    ) {
        guard isAvailable, let uid else { return }
        let previous = tail
        let current = revision
        tail = Task { [weak self] in
            await previous?.value
            guard let self, self.revision == current else { return }
            do {
                let store = try await self.owner.open(uid: uid)
                let epoch = try await store.cacheEpoch()
                guard self.revision == current else { return }
                try await action(self, store, epoch)
            } catch { self.report(error) }
        }
    }

    private func resetIngress() {
        revision &+= 1
        pending.removeAll()
        queuedPages.removeAll()
        chatPrivacyRevisions.removeAll()
        committed.removeAll()
        liveEnds.removeAll()
        syncAlignedScopes.removeAll()
    }

    private func pruneCoverage() {
        if let earliest = pending.min() {
            committed.removeAll { $0.serial <= earliest }
        } else {
            committed.removeAll()
        }
    }

    private func report(_ error: Error) {
        guard !(error is CancellationError) else { return }
        if ChahuaLocalStore.isDiskFull(error) { pauseForDiskFull() }
        Logger(subsystem: "app.chahua.chat", category: "history-cache")
            .error(
                "Cache operation failed: \(String(reflecting: type(of: error)), privacy: .public)")
    }

    private static func bounds(_ query: ListMessagesQuery, _ page: ListMessagesResponse)
        -> ClosedRange<MessageID>
    {
        let minID = MessageID(0)
        let maxID = MessageID(UInt64.max)
        let first = page.messages.lazy.map(\.id).min()
        let last = page.messages.lazy.map(\.id).max()
        if let before = query.before {
            return min(before, page.olderCursor == nil ? minID : first ?? before)...before
        }
        if let after = query.after {
            return after...max(after, page.newerCursor == nil ? maxID : last ?? after)
        }
        if let around = query.around, first == nil { return around...around }
        return
            (page.olderCursor == nil ? minID : first ?? minID)...(page.newerCursor == nil
            ? maxID : last ?? maxID)
    }

    private static func change(_ event: RealtimeServerEvent) -> CachedMessageChange? {
        switch event {
        case .message(let value) where !value.isDeleted:
            .create(value, .init(chatID: value.chatId, threadID: value.replyRootId))
        case .messageUpdated(let value) where !value.isDeleted:
            .update(value, .init(chatID: value.chatId, threadID: value.replyRootId))
        case .message(let value), .messageUpdated(let value), .messageDeleted(let value):
            .delete(chatID: value.chatId, ids: [value.id])
        case .messagesBulkDeleted(let payload):
            .delete(chatID: payload.chatId, ids: Set(payload.messageIds))
        case .reactionUpdated(let payload):
            .reactions(payload)
        case .threadUpdate(let payload):
            MessageID(payload.threadRootId).map {
                .threadCount(chatID: payload.chatId, id: $0, count: payload.replyCount)
            }
        default: nil
        }
    }
}
