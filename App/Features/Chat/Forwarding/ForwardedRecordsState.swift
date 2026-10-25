import ChahuaAPI
import Combine
import Foundation

/// The only source for a record timeline. Every query, including a reply jump,
/// stays inside this immediate captured bundle and has no live-chat fallback.
@MainActor
private final class ForwardedRecordMessageSource: TimelineMessageSource {
    private var snapshot: ListMessagesResponse?

    init(messages: [MessageResponse]) {
        snapshot = ListMessagesResponse(messages: messages)
    }

    func fetchMessages(chatID: String, query: ListMessagesQuery) async throws
        -> ListMessagesResponse
    {
        try Task.checkCancellation()
        guard let snapshot else { throw CancellationError() }
        // Detail responses contain all immediate items, even when larger than the
        // live timeline's page size. Both ends are complete: all cursors are nil.
        return snapshot
    }

    func invalidate() { snapshot = nil }
}

@MainActor
final class ForwardedRecordSnapshot {
    let timeline: ConversationTimelineModel
    let messageIDs: Set<MessageID>
    let childBundleIDs: Set<String>
    private let source: ForwardedRecordMessageSource
    private let messages = ConversationMessageStore()

    init(response: ForwardedMessagesResponse, currentUserID: Int32) {
        let captured = response.messages.map(\.timelineMessage)
        messageIDs = Set(captured.map(\.id))
        childBundleIDs = Set(
            captured.compactMap { $0.messageType == .forwarded ? $0.forwardedBundleId : nil })
        source = ForwardedRecordMessageSource(messages: captured)
        let redactedIDs = Set(
            response.messages.compactMap { message -> MessageID? in
                if case .redacted? = message.reply { return message.originalMessageId }
                return nil
            })
        // The source scope is an acceptance key only. It is never registered as a
        // live timeline and the dedicated message store never receives chat events.
        // Captured authors remain visible regardless of the enclosing DM preference.
        // Avatar density still flows through the shared native timeline environment.
        timeline = ConversationTimelineModel(
            chatID: captured.first?.chatId ?? "captured-empty",
            currentUserID: currentUserID, isGroupChat: true,
            source: source, messageStore: messages,
            capturedReplyRedactedIDs: redactedIDs)
    }

    func invalidate() {
        source.invalidate()
        messages.reset()
        timeline.close()
    }
}

/// Shared by every pushed child so authority always remains the original chat
/// wrapper (or saved row), never an original source chat or a bare bundle ID.
@MainActor
final class ForwardedRecordsSession: ObservableObject {
    enum Root {
        case chat(chatID: String, messageID: MessageID)
        case saved(messageID: String)
    }

    enum Key: Hashable {
        case root
        case bundle(String)

        init(bundleID: String?) {
            self = bundleID.map(Self.bundle) ?? .root
        }

        var bundleID: String? {
            if case .bundle(let value) = self { return value }
            return nil
        }
    }

    enum Phase {
        case loading
        case ready(ForwardedRecordSnapshot)
        case failed
        case unavailable
    }

    @Published private(set) var records: [Key: Phase] = [:]
    @Published private(set) var revision = 0
    let store: ChatStore
    private let root: Root
    private let accountID: Int32?
    private var observations: Set<AnyCancellable> = []
    private var requests: [Key: Task<Void, Never>] = [:]
    private var permanentlyUnavailable = false
    private var suspended = false

    init(store: ChatStore, root: Root) {
        self.store = store
        self.root = root
        accountID = store.currentUserProfile?.uid
        store.savedMessages.removedSnapshots.sink { [weak self] savedMessageID in
            guard let self, case .saved(let rootID) = root, rootID == savedMessageID else {
                return
            }
            invalidate(permanently: true)
        }.store(in: &observations)
        store.conversationMessages.changes.sink { [weak self] change in
            self?.receive(change)
        }.store(in: &observations)
        store.$currentUserProfile.map { $0?.uid }.removeDuplicates().dropFirst()
            .sink { [weak self] uid in
                guard let self, uid != accountID else { return }
                invalidate(permanently: true)
            }.store(in: &observations)
        store.chatAccessInvalidations.sink { [weak self] chatID in
            guard let self, case .chat(let rootChatID, _) = root, rootChatID == chatID else {
                return
            }
            invalidate(permanently: true)
        }.store(in: &observations)
        store.$state.map(\.realtimeStatus).removeDuplicates().dropFirst()
            .sink { [weak self] status in
                guard let self, status == .connected, !suspended else { return }
                invalidate(permanently: false)
            }.store(in: &observations)
    }

    func phase(for key: Key) -> Phase {
        permanentlyUnavailable ? .unavailable : records[key] ?? .loading
    }

    func load(_ key: Key, retry: Bool = false) {
        guard !permanentlyUnavailable, !suspended, requests[key] == nil,
            retry || records[key] == nil
        else { return }
        guard let accountID, store.currentUserProfile?.uid == accountID else {
            invalidate(permanently: true)
            return
        }
        let requestRevision = revision
        records[key] = .loading
        requests[key] = Task { [weak self] in
            guard let self else { return }
            defer {
                if revision == requestRevision { requests[key] = nil }
            }
            do {
                let response: ForwardedMessagesResponse
                switch root {
                case .chat(let chatID, let messageID):
                    response = try await store.forwardedMessages(
                        chatID: chatID, messageID: messageID, bundleID: key.bundleID)
                case .saved(let messageID):
                    response = try await store.savedForwardedMessages(
                        savedMessageID: messageID, bundleID: key.bundleID)
                }
                guard !Task.isCancelled, revision == requestRevision,
                    store.currentUserProfile?.uid == accountID, !permanentlyUnavailable
                else { return }
                let snapshot = ForwardedRecordSnapshot(
                    response: response, currentUserID: accountID)
                await snapshot.timeline.open()
                guard !Task.isCancelled, revision == requestRevision,
                    store.currentUserProfile?.uid == accountID, !permanentlyUnavailable
                else {
                    snapshot.invalidate()
                    return
                }
                records[key] = .ready(snapshot)
            } catch {
                guard !Task.isCancelled, revision == requestRevision else { return }
                if Self.isUnavailable(error) {
                    // Child reads authorize the same root. A denied/missing root
                    // must also remove any cached parent or sibling content.
                    invalidate(permanently: true)
                } else {
                    records[key] = .failed
                }
            }
        }
    }

    func setSceneActive(_ active: Bool) {
        guard suspended == active else { return }
        suspended = !active
        // Clear before background snapshots and reauthorize before redisplaying.
        invalidate(permanently: false)
    }

    private func receive(_ change: ConversationChange) {
        switch change {
        case .reset:
            invalidate(permanently: true)
        case .realtime(let event):
            guard case .chat(let chatID, let messageID) = root else { return }
            switch event {
            case .messageDeleted(let message):
                if message.chatId == chatID, message.id == messageID {
                    invalidate(permanently: true)
                }
            case .messageUpdated(let message):
                if message.chatId == chatID, message.id == messageID, message.isDeleted {
                    invalidate(permanently: true)
                }
            case .messagesBulkDeleted(let payload):
                if payload.chatId == chatID, payload.messageIds.contains(messageID) {
                    invalidate(permanently: true)
                }
            default: break
            }
        case .pendingChanged, .membershipVisibilityChanged: break
        }
    }

    private func invalidate(permanently: Bool) {
        permanentlyUnavailable = permanentlyUnavailable || permanently
        for request in requests.values { request.cancel() }
        requests.removeAll()
        for phase in records.values {
            if case .ready(let snapshot) = phase { snapshot.invalidate() }
        }
        records.removeAll()
        revision &+= 1
    }

    private static func isUnavailable(_ error: Error) -> Bool {
        guard let error = error as? APIError else { return false }
        switch error {
        case .unauthorized, .invalidToken: return true
        case .http(let status, _), .invalidResponse(let status):
            return status == 401 || status == 403 || status == 404 || status == 410
        default: return false
        }
    }
}
