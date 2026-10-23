import ChahuaAPI
import Combine
import Foundation

enum ThreadSubscriptionChange: Equatable {
    case subscribe
    case archive
    case unarchive
}

extension ThreadListItem {
    func withArchived(_ archived: Bool) -> ThreadListItem {
        ThreadListItem(
            chatId: chatId, chatName: chatName, chatAvatar: chatAvatar,
            threadRootMessage: threadRootMessage, participants: participants,
            lastReply: lastReply, replyCount: replyCount, lastReplyAt: lastReplyAt,
            unreadCount: unreadCount, unreadMentions: unreadMentions,
            unreadReactions: unreadReactions, lastReadMessageId: lastReadMessageId,
            peerLastReadMessageId: peerLastReadMessageId,
            chatKind: chatKind,
            subscribedAt: subscribedAt, archived: archived)
    }
}

/// The current user's subscription to the visible thread, for thread detail.
///
/// State changes apply only after the server accepts them. Absolute realtime
/// membership snapshots supersede reads already in flight; legacy invalidations
/// without a snapshot re-read the server state.
@MainActor
final class ThreadSubscriptionModel: ObservableObject {
    let key: ConversationKey
    @Published private(set) var status: ThreadSubscriptionStatus?
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false
    @Published private(set) var isMutating = false
    @Published var failureMessage: String?

    private let chatID: String
    private let threadID: String
    private let store: ChatStore
    /// Fences reads that started before a newer read or a mutation.
    private var revision = 0
    private var loadTask: Task<Void, Never>?
    private var invalidations: AnyCancellable?
    private var snapshots: AnyCancellable?

    init(chatID: String, threadID: String, store: ChatStore) {
        self.chatID = chatID
        self.threadID = threadID
        self.store = store
        key = ConversationKey(chatID: chatID, threadID: threadID)
        invalidations = store.threadSubscriptionInvalidations
            .filter { [key] in $0 == key }
            .sink { [weak self] _ in self?.reload() }
        snapshots = store.threadSubscriptionChanges
            .filter { [key] in $0.key == key }
            .sink { [weak self] change in self?.applySnapshot(change.status) }
        reload()
    }

    deinit {
        loadTask?.cancel()
    }

    private func applySnapshot(_ status: ThreadSubscriptionStatus) {
        revision &+= 1
        loadTask?.cancel()
        loadTask = nil
        self.status = status
        isLoading = false
        loadFailed = false
    }

    func reload() {
        guard !isMutating else { return }
        revision &+= 1
        let requestRevision = revision
        loadTask?.cancel()
        isLoading = true
        loadFailed = false
        loadTask = Task { [weak self, chatID, threadID, store] in
            do {
                let status = try await store.threadSubscriptionStatus(
                    chatID: chatID, threadID: threadID)
                guard let self, self.revision == requestRevision else { return }
                self.status = status
                self.isLoading = false
            } catch is CancellationError {
                // A newer read, a mutation, or dismissal owns state.
            } catch {
                guard let self, self.revision == requestRevision else { return }
                self.isLoading = false
                self.loadFailed = true
            }
        }
    }

    func perform(_ change: ThreadSubscriptionChange) async {
        guard !isMutating else { return }
        revision &+= 1
        let requestRevision = revision
        loadTask?.cancel()
        isLoading = false
        isMutating = true
        defer { isMutating = false }
        do {
            let updated = try await store.changeThreadSubscription(
                change, chatID: chatID, threadID: threadID)
            guard revision == requestRevision else { return }
            status = updated
            loadFailed = false
        } catch is CancellationError {
            return
        } catch {
            guard revision == requestRevision else { return }
            failureMessage = AppLanguage.localized(
                "Couldn’t update the thread subscription. Please try again.")
        }
    }
}
