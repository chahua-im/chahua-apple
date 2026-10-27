import ChahuaAPI
import Combine
import Foundation

/// Only the store values rendered by one detail screen. The timeline, drafts,
/// outbox, reactions, pins and saved messages retain their own observation paths.
@MainActor
final class ChatDetailObservation: ObservableObject {
    struct Permissions: Equatable {
        var role: GroupRole?
        var speakingMode: SpeakingMode?

        init(_ info: GroupInfoResponse?) {
            role = info?.myRole
            speakingMode = info?.effectiveSpeakingMode
        }
    }

    struct Session: Equatable {
        let accountID: Int32?
        let revision: Int
    }

    @Published private(set) var permissions: Permissions
    @Published private(set) var threadReplyCount: Int64?
    @Published private(set) var session: Session
    private let initialSession: Session
    private var observations = Set<AnyCancellable>()

    var isCurrentSession: Bool { session == initialSession }

    init(store: ChatStore, chatID: String, threadID: String?) {
        permissions = Permissions(store.groupInfoByChatID[chatID])
        let threadRootID = threadID.flatMap(MessageID.init)
        threadReplyCount = Self.replyCount(in: store.state, chatID: chatID, rootID: threadRootID)
        let session = Session(
            accountID: store.currentUserProfile?.uid, revision: store.sessionRevision)
        self.session = session
        initialSession = session

        // @Published emits before assignment. Project the emitted dictionaries/state,
        // never synchronously reread the store from their sinks.
        store.$groupInfoByChatID
            .map { Permissions($0[chatID]) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] in self?.permissions = $0 }
            .store(in: &observations)

        // Main-chat details need no list-state subscription at all. A thread keeps
        // one scalar, not a ThreadListItem (whose unread fields change on scrolling).
        if let threadRootID {
            store.$state
                .map { Self.replyCount(in: $0, chatID: chatID, rootID: threadRootID) }
                .removeDuplicates()
                .dropFirst()
                .sink { [weak self] in self?.threadReplyCount = $0 }
                .store(in: &observations)
        }

        store.$currentUserProfile.map { $0?.uid }.removeDuplicates()
            .combineLatest(store.$sessionRevision.removeDuplicates())
            .map { Session(accountID: $0.0, revision: $0.1) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] in self?.session = $0 }
            .store(in: &observations)
    }

    private static func replyCount(in state: ChatState, chatID: String, rootID: MessageID?)
        -> Int64?
    {
        guard let rootID else { return nil }
        let matches: (ThreadListItem) -> Bool = {
            $0.chatId == chatID && $0.threadRootMessage.id == rootID
        }
        return (state.threads.first(where: matches) ?? state.archivedThreads.first(where: matches))?
            .replyCount
    }
}
