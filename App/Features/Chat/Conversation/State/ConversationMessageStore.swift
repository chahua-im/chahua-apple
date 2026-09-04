import Combine
import ChahuaAPI
import Foundation

struct ConversationProjection: Hashable {
    let entries: [ConversationTimelineEntry]
}

@MainActor
final class ConversationMessageStore: ObservableObject {
    @Published private(set) var revision = 0

    private var pendingOutgoingByChatID: [String: [PendingOutgoingMessage]] = [:]
    private var deferredLiveByChatID: [String: [ConversationMessageStableKey: MessageResponse]] = [:]

    func enqueue(_ pending: PendingOutgoingMessage) {
        precondition(!pending.clientGeneratedID.isEmpty, "Queued messages require a client-generated ID.")
        precondition(pending.body.clientGeneratedId == pending.clientGeneratedID, "Queue and request IDs must match.")
        precondition(
            !(pendingOutgoingByChatID[pending.chatID, default: []].contains { $0.clientGeneratedID == pending.clientGeneratedID }),
            "A client-generated ID may be queued only once per chat."
        )
        pendingOutgoingByChatID[pending.chatID, default: []].append(pending)
        publishChange()
    }

    func markSending(chatID: String, clientGeneratedID: String) {
        mutatePending(chatID: chatID, clientGeneratedID: clientGeneratedID) { $0.state = .sending }
    }

    func markFailed(chatID: String, clientGeneratedID: String) {
        mutatePending(chatID: chatID, clientGeneratedID: clientGeneratedID) { $0.state = .failed }
    }

    func discard(chatID: String, clientGeneratedID: String) {
        guard var pending = pendingOutgoingByChatID[chatID], let index = pending.firstIndex(where: { $0.clientGeneratedID == clientGeneratedID }) else {
            return
        }
        pending.remove(at: index)
        pendingOutgoingByChatID[chatID] = pending
        publishChange()
    }

    func acknowledge(_ message: MessageResponse) {
        removePending(chatID: message.chatId, clientGeneratedID: message.clientGeneratedId)
        upsertDeferredLive(message)
        publishChange()
    }

    func receiveLive(_ message: MessageResponse) {
        removePending(chatID: message.chatId, clientGeneratedID: message.clientGeneratedId)
        upsertDeferredLive(message)
        publishChange()
    }

    func applyLiveUpdate(_ message: MessageResponse) {
        upsertDeferredLive(message)
        publishChange()
    }

    func applyLiveRemoval(chatID: String, serverMessageID: String) {
        guard var deferred = deferredLiveByChatID[chatID] else { return }
        let keys = deferred.compactMap { $0.value.id == serverMessageID ? $0.key : nil }
        let removed = !keys.isEmpty
        keys.forEach { deferred.removeValue(forKey: $0) }
        if removed {
            deferredLiveByChatID[chatID] = deferred
            publishChange()
        }
    }

    func projection(
        for chatID: String,
        remoteMessages: [MessageResponse],
        includeDeferredLive: Bool
    ) -> ConversationProjection {
        var entriesByKey = Dictionary(uniqueKeysWithValues: remoteMessages.map {
            (ConversationMessageStableKey($0), ConversationTimelineEntry.remote($0))
        })
        if includeDeferredLive {
            for message in deferredLiveByChatID[chatID, default: [:]].values where entriesByKey[message.timelineStableKey] == nil {
                entriesByKey[message.timelineStableKey] = .remote(message)
            }
        }
        for pending in pendingOutgoingByChatID[chatID, default: []] where entriesByKey[.clientGenerated(pending.clientGeneratedID)] == nil {
            entriesByKey[.clientGenerated(pending.clientGeneratedID)] = .pending(pending)
        }

        let entries = entriesByKey.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.stableKey.sortValue < $1.stableKey.sortValue
        }
        return ConversationProjection(entries: entries)
    }


    func consumeDeferredLive(chatID: String, projectedKeys: Set<ConversationMessageStableKey>) {
        guard var deferred = deferredLiveByChatID[chatID] else { return }
        let originalCount = deferred.count
        deferred = deferred.filter { !projectedKeys.contains($0.key) }
        guard deferred.count != originalCount else { return }
        deferredLiveByChatID[chatID] = deferred
        publishChange()
    }

    /// Reconciles the buffer against a freshly installed live window. Drops anything the page
    /// already contains (server copy wins) and anything older than the page's newest row, which
    /// is now covered by server history and will arrive in order via older-paging. Keeps arrivals
    /// at or after the newest row's timestamp that the page did not include: a tie is a message
    /// created in the same second the page cut off, and nothing newer exists to page toward, so
    /// dropping it would lose it until the next reload. Identity, not `createdAt`, decides
    /// duplicates so clock skew cannot resurrect a covered message.
    ///
    /// `installedKeys` are the stable keys of every row in the new window; a buffered entry and
    /// the page's copy of the same message share a stable key, so one set covers identity.
    func reconcileDeferredLive(
        chatID: String,
        installedKeys: Set<ConversationMessageStableKey>,
        newestCreatedAt: Date
    ) {
        guard var deferred = deferredLiveByChatID[chatID] else { return }
        let originalCount = deferred.count
        deferred = deferred.filter { key, message in
            !installedKeys.contains(key) && message.createdAt >= newestCreatedAt
        }
        guard deferred.count != originalCount else { return }
        deferredLiveByChatID[chatID] = deferred
        publishChange()
    }

    private func mutatePending(
        chatID: String,
        clientGeneratedID: String,
        mutation: (inout PendingOutgoingMessage) -> Void
    ) {
        guard var pending = pendingOutgoingByChatID[chatID], let index = pending.firstIndex(where: { $0.clientGeneratedID == clientGeneratedID }) else {
            return
        }
        mutation(&pending[index])
        pendingOutgoingByChatID[chatID] = pending

        publishChange()
    }

    private func removePending(chatID: String, clientGeneratedID: String) {
        guard var pending = pendingOutgoingByChatID[chatID], let index = pending.firstIndex(where: { $0.clientGeneratedID == clientGeneratedID }) else {
            return
        }
        pending.remove(at: index)
        pendingOutgoingByChatID[chatID] = pending
    }

    private func upsertDeferredLive(_ message: MessageResponse) {
        deferredLiveByChatID[message.chatId, default: [:]][message.timelineStableKey] = message
    }

    private func publishChange() {
        revision &+= 1
    }
}
#if DEBUG
extension ConversationMessageStore {
    /// Test observation only. Production UI must use server-backed unread state, never this
    /// ephemeral render-buffer occupancy.
    func bufferedLiveEventCountForTesting(chatID: String) -> Int {
        deferredLiveByChatID[chatID, default: [:]].count
    }
}
#endif
