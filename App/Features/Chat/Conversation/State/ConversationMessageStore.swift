import Combine
import ChahuaAPI
import Foundation

struct ConversationProjection: Hashable {
    let entries: [ConversationTimelineEntry]
}

enum ConversationChange {
    case pendingChanged(chatID: String)
    case realtime(RealtimeServerEvent)
    case reset
}

/// Shared pending sends and synchronous ingress, not a canonical message database.
@MainActor
final class ConversationMessageStore: ObservableObject {
    let changes = PassthroughSubject<ConversationChange, Never>()

    private var pendingOutgoing: [ConversationKey: [PendingOutgoingMessage]] = [:]
    private var deletedReplyIDs: [String: Set<String>] = [:]
    private var receiveRevision: UInt64 = 0
    private struct Snapshot {
        let chatID: String
        let revision: UInt64
    }
    private struct JournalEntry {
        let revision: UInt64
        let event: RealtimeServerEvent
    }
    private var snapshots: [UUID: Snapshot] = [:]
    private var journals: [String: [JournalEntry]] = [:]

    func replacePending(chatID: String, threadID: String? = nil, with pending: [PendingOutgoingMessage], acknowledging message: MessageResponse? = nil) {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        pendingOutgoing[key] = deletedReplyIDs[chatID]?.isEmpty == false ? pending.map(normalizingReply) : pending
        if let message {
            precondition(message.chatId == chatID && message.replyRootId == threadID, "Acknowledgement and pending batch must belong to the same conversation.")
            apply(.message(message))
        } else {
            changes.send(.pendingChanged(chatID: chatID))
        }
    }

    func enqueue(_ pending: PendingOutgoingMessage) {
        precondition(!pending.clientGeneratedID.isEmpty, "Queued messages require a client-generated ID.")
        precondition(pending.body.clientGeneratedId == pending.clientGeneratedID, "Queue and request IDs must match.")
        let key = ConversationKey(chatID: pending.chatID, threadID: pending.threadID)
        precondition(
            !(pendingOutgoing[key, default: []].contains { $0.clientGeneratedID == pending.clientGeneratedID }),
            "A client-generated ID may be queued only once per chat."
        )
        pendingOutgoing[key, default: []].append(normalizingReply(pending))
        changes.send(.pendingChanged(chatID: pending.chatID))
    }

    func markSending(chatID: String, threadID: String? = nil, clientGeneratedID: String) {
        mutatePending(chatID: chatID, threadID: threadID, clientGeneratedID: clientGeneratedID) { $0.state = .sending }
    }

    func markFailed(chatID: String, threadID: String? = nil, clientGeneratedID: String) {
        mutatePending(chatID: chatID, threadID: threadID, clientGeneratedID: clientGeneratedID) { $0.state = .failed }
    }

    func discard(chatID: String, threadID: String? = nil, clientGeneratedID: String) {
        guard removePending(chatID: chatID, threadID: threadID, clientGeneratedID: clientGeneratedID) else { return }
        changes.send(.pendingChanged(chatID: chatID))
    }

    func acknowledge(_ message: MessageResponse) { apply(.message(message)) }

    func apply(_ event: RealtimeServerEvent) {
        // Acknowledgement and remote insertion are one observable transition.
        if case .message(let message) = event {
            removePending(chatID: message.chatId, threadID: message.replyRootId, clientGeneratedID: message.clientGeneratedId)
        }
        switch event {
        case .messageDeleted(let message):
            redactPendingReplies([message.id], chatID: message.chatId)
        case .messagesBulkDeleted(let payload):
            redactPendingReplies(Set(payload.messageIds), chatID: payload.chatId)
        default:
            break
        }
        receiveRevision &+= 1
        if let chatID = event.conversationChatID, snapshots.values.contains(where: { $0.chatID == chatID }) {
            journals[chatID, default: []].append(.init(revision: receiveRevision, event: event))
        }
        changes.send(.realtime(event))
    }

    func beginSnapshot(chatID: String) -> UUID {
        let token = UUID()
        snapshots[token] = Snapshot(chatID: chatID, revision: receiveRevision)
        return token
    }

    func eventsDuringSnapshot(_ token: UUID) -> [RealtimeServerEvent] {
        guard let snapshot = snapshots[token] else { return [] }
        return journals[snapshot.chatID, default: []].compactMap { $0.revision > snapshot.revision ? $0.event : nil }
    }

    func endSnapshot(_ token: UUID) {
        guard let snapshot = snapshots.removeValue(forKey: token) else { return }
        guard let oldest = snapshots.values.filter({ $0.chatID == snapshot.chatID }).map(\.revision).min() else {
            journals.removeValue(forKey: snapshot.chatID)
            return
        }
        journals[snapshot.chatID]?.removeAll { $0.revision <= oldest }
    }

    func reset() {
        pendingOutgoing.removeAll()
        deletedReplyIDs.removeAll()
        snapshots.removeAll()
        journals.removeAll()
        receiveRevision = 0
        changes.send(.reset)
    }

    func projection(
        for chatID: String,
        threadID: String? = nil,
        remoteMessages: [MessageResponse],
        includePendingOutgoing: Bool
    ) -> ConversationProjection {
        var entriesByKey: [ConversationMessageStableKey: ConversationTimelineEntry] = [:]
        for message in remoteMessages { entriesByKey[message.timelineStableKey] = .remote(message) }
        if includePendingOutgoing {
            for pending in pendingOutgoing[ConversationKey(chatID: chatID, threadID: threadID), default: []] where entriesByKey[.clientGenerated(pending.clientGeneratedID)] == nil {
                entriesByKey[.clientGenerated(pending.clientGeneratedID)] = .pending(pending)
            }
        }
        return ConversationProjection(entries: entriesByKey.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.stableKey.sortValue < $1.stableKey.sortValue
        })
    }

    private func normalizingReply(_ pending: PendingOutgoingMessage) -> PendingOutgoingMessage {
        guard let reply = pending.replyToMessage, !reply.isDeleted,
              deletedReplyIDs[pending.chatID]?.contains(reply.id) == true else { return pending }
        var pending = pending
        pending.replyToMessage = reply.redactedForDeletion()
        return pending
    }

    private func redactPendingReplies(_ messageIDs: Set<String>, chatID: String) {
        deletedReplyIDs[chatID, default: []].formUnion(messageIDs)
        for key in pendingOutgoing.keys where key.chatID == chatID {
            pendingOutgoing[key] = pendingOutgoing[key, default: []].map(normalizingReply)
        }
    }

    private func mutatePending(
        chatID: String,
        threadID: String?,
        clientGeneratedID: String,
        mutation: (inout PendingOutgoingMessage) -> Void
    ) {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        guard var pending = pendingOutgoing[key], let index = pending.firstIndex(where: { $0.clientGeneratedID == clientGeneratedID }) else { return }
        mutation(&pending[index])
        pendingOutgoing[key] = pending
        changes.send(.pendingChanged(chatID: chatID))
    }

    @discardableResult
    private func removePending(chatID: String, threadID: String?, clientGeneratedID: String) -> Bool {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        guard !clientGeneratedID.isEmpty, var pending = pendingOutgoing[key], let index = pending.firstIndex(where: { $0.clientGeneratedID == clientGeneratedID }) else { return false }
        pending.remove(at: index)
        pendingOutgoing[key] = pending
        return true
    }
}

extension RealtimeServerEvent {
    /// Only mutations relevant to message snapshots belong in the request journal.
    var conversationChatID: String? {
        switch self {
        case .message(let message), .messageUpdated(let message), .messageDeleted(let message): message.chatId
        case .messagesBulkDeleted(let payload): payload.chatId
        case .reactionUpdated(let payload): payload.chatId
        case .threadUpdate(let payload): payload.chatId
        case .pong, .chatArchiveStateChanged, .presenceUpdate, .threadMembershipChanged,
             .pinAdded, .threadPinAdded, .pinRemoved, .threadPinRemoved, .stickerPackOrderUpdated,
             .friendRequestReceived, .friendRequestResolved, .friendshipRemoved, .unknown: nil
        }
    }
}
