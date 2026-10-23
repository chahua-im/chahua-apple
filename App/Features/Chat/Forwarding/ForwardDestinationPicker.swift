import ChahuaAPI
import Combine
import SwiftUI

/// Present directly as a sheet; this view owns its shared iOS/macOS navigation stack.
struct ForwardDestinationPicker: View {
    enum SourceError: Error {
        case tooMany, unavailable
    }

    @ObservedObject private var store: ChatStore
    @StateObject private var model: ForwardDestinationPickerModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private let onEnqueued: () -> Void

    init(
        store: ChatStore, sources: [MessageResponse],
        loadSources: (@MainActor () async throws -> [MessageResponse])? = nil,
        onEnqueued: @escaping () -> Void
    ) {
        self.store = store
        self.onEnqueued = onEnqueued
        _model = StateObject(
            wrappedValue: ForwardDestinationPickerModel(
                store: store, sources: sources, loadSources: loadSources))
    }

    var body: some View {
        NavigationStack {
            List {
                if let failure = model.failure {
                    Text(failure.localizedDescription)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("forward-selection-error")
                }
                if model.isResolving || model.isSubmitting {
                    ProgressView("Preparing forward…")
                }
                let targets = model.targets(matching: query)
                ForEach(targets) { target in
                    Button {
                        model.select(target) {
                            onEnqueued()
                            dismiss()
                        }
                    } label: {
                        destinationRow(target)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.selectionBlocked)
                }
                if targets.isEmpty {
                    if model.isLoading {
                        ProgressView("Loading conversations…")
                    } else if !model.chatsFailed && !model.threadsFailed {
                        Text("No forwarding destinations found")
                            .foregroundStyle(.secondary)
                    }
                }
                if model.chatsFailed {
                    retryRow("Could not load chats", action: model.retryChats)
                }
                if model.threadsFailed {
                    retryRow("Could not load threads", action: model.retryThreads)
                }
                // Search is local to loaded pages. Keep paging outside the results branch.
                if model.moreAvailable {
                    Button("Load More", action: model.loadMore)
                        .disabled(model.isLoading)
                        .frame(maxWidth: .infinity)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Forward to")
            .searchable(text: $query, prompt: "Search chats and threads")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.stop()
                        dismiss()
                    }
                }
            }
            .alert(
                "Replace unavailable content?",
                isPresented: Binding(
                    get: { model.confirmation != nil },
                    set: { if !$0 { model.cancelConfirmation() } }),
                presenting: model.confirmation
            ) { confirmation in
                Button("Cancel", role: .cancel) { model.cancelConfirmation() }
                Button("Continue") {
                    model.confirm(confirmation) {
                        onEnqueued()
                        dismiss()
                    }
                }
            } message: { confirmation in
                Text(confirmation.prompt)
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: store.currentUserProfile?.uid) { _, _ in
            model.stop()
            dismiss()
        }
    }

    private func destinationRow(_ target: ConversationListItem) -> some View {
        HStack(spacing: 12) {
            ConversationAvatarView(
                item: target, store: store, currentUserID: store.currentUserProfile?.uid ?? 0)
            VStack(alignment: .leading, spacing: 4) {
                switch target {
                case .chat(let chat):
                    Text(chat.chatDisplayName).font(.headline)
                case .thread(let thread):
                    Label(thread.chatName, systemImage: "text.bubble")
                        .font(.headline)
                    MessageSummaryText(thread.threadRootMessage, fontSize: 14, color: .secondary)
                    Text("\(thread.replyCount) replies")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func retryRow(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Button("Retry", action: action)
        }
    }
}

@MainActor
private final class ForwardDestinationPickerModel: ObservableObject {
    enum Failure: Error, LocalizedError, Equatable {
        case unavailable, stale, tooMany, topicUnavailable, loadFailed, enqueueFailed

        var errorDescription: String? {
            switch self {
            case .unavailable:
                AppLanguage.localized(
                    "Some selected messages cannot be forwarded. Close this picker and select again."
                )
            case .stale:
                AppLanguage.localized(
                    "Some selected messages are no longer available. Close this picker and select again."
                )
            case .tooMany:
                AppLanguage.localized("You can forward at most 100 messages at once.")
            case .topicUnavailable:
                AppLanguage.localized("This thread no longer has messages that can be forwarded.")
            case .loadFailed:
                AppLanguage.localized(
                    "Could not reload the messages. Choose a destination to retry.")
            case .enqueueFailed:
                AppLanguage.localized("Could not start forwarding. Choose a destination to retry.")
            }
        }
    }

    struct Confirmation {
        let target: ConversationListItem
        let sources: [MessageResponse]
        let pendingAudio: Bool
        let nestedForward: Bool

        var prompt: String {
            if pendingAudio && nestedForward {
                return AppLanguage.localized(
                    "Audio still processing and deeply nested forwarded messages will be replaced with placeholders. Continue forwarding?"
                )
            }
            if pendingAudio {
                return AppLanguage.localized(
                    "Audio still processing will be replaced with a placeholder. Continue forwarding?"
                )
            }
            return AppLanguage.localized(
                "Deeply nested forwarded messages will be replaced with placeholders. Continue forwarding?"
            )
        }
    }

    @Published private(set) var failure: Failure?
    @Published private(set) var confirmation: Confirmation?
    @Published private(set) var isResolving = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var chatsFailed = false
    @Published private(set) var threadsFailed = false
    @Published private(set) var chatsLoading = false
    @Published private(set) var threadsLoading = false
    @Published private var chats: [ChatListItem] = []
    @Published private var threads: [ThreadListItem] = []
    @Published private var chatsHaveMore = true
    @Published private var threadsHaveMore = true

    private let store: ChatStore
    private let sources: [MessageResponse]
    private let loadSources: (@MainActor () async throws -> [MessageResponse])?
    private let accountID: Int32?
    private var chatCursor: String?
    private var threadCursor: String?
    private var chatBoundary = Date.distantFuture
    private var threadBoundary = Date.distantFuture
    private var chatTask: Task<Void, Never>?
    private var threadTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var observation: AnyCancellable?
    private var removedIDs = Set<MessageID>()
    private var resolvedSources: [MessageResponse] = []
    private var generation = 0
    private var isOpen = false
    private var didEnqueue = false

    init(
        store: ChatStore, sources: [MessageResponse],
        loadSources: (@MainActor () async throws -> [MessageResponse])?
    ) {
        self.store = store
        self.sources = sources
        self.loadSources = loadSources
        accountID = store.currentUserProfile?.uid
    }

    var isLoading: Bool { chatsLoading || threadsLoading }
    var moreAvailable: Bool {
        (chatsHaveMore && !chatsFailed) || (threadsHaveMore && !threadsFailed)
    }
    var selectionBlocked: Bool {
        !isOpen || didEnqueue || isResolving || isSubmitting || confirmation != nil
            || failure == .stale || failure == .unavailable
            || (loadSources == nil && failure == .tooMany)
    }

    func targets(matching query: String) -> [ConversationListItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (chats.map(ConversationListItem.chat) + threads.map(ConversationListItem.thread))
            .filter { target in
                guard !query.isEmpty else { return true }
                switch target {
                case .chat(let chat):
                    return chat.chatDisplayName.localizedStandardContains(query)
                case .thread(let thread):
                    return (thread.chatName + " " + (thread.threadRootMessage.message ?? ""))
                        .localizedStandardContains(query)
                }
            }
            .sorted {
                if $0.activityDate != $1.activityDate { return $0.activityDate > $1.activityDate }
                if $0.id.chatID != $1.id.chatID { return $0.id.chatID < $1.id.chatID }
                return ($0.id.threadID ?? "") < ($1.id.threadID ?? "")
            }
    }

    func start() {
        guard !isOpen, !didEnqueue else { return }
        isOpen = true
        generation += 1
        guard accountID != nil, store.currentUserProfile?.uid == accountID else {
            failure = .unavailable
            return
        }
        do { try validate(sources) } catch let error as Failure { failure = error } catch {
            failure = .unavailable
        }
        observation = store.conversationMessages.changes.sink { [weak self] change in
            self?.receive(change)
        }
        retryChats()
        retryThreads()
    }

    func stop() {
        isOpen = false
        generation += 1
        chatTask?.cancel()
        threadTask?.cancel()
        selectionTask?.cancel()
        chatTask = nil
        threadTask = nil
        selectionTask = nil
        observation = nil
        confirmation = nil
    }

    private func current(_ token: Int) -> Bool {
        isOpen && generation == token && store.currentUserProfile?.uid == accountID
            && !Task.isCancelled
    }

    func retryChats() {
        guard isOpen, !chatsLoading else { return }
        chatsFailed = false
        chatsLoading = true
        let token = generation
        chatTask = Task { [weak self] in await self?.loadChats(token: token) }
    }

    func retryThreads() {
        guard isOpen, !threadsLoading else { return }
        threadsFailed = false
        threadsLoading = true
        let token = generation
        threadTask = Task { [weak self] in await self?.loadThreads(token: token) }
    }

    func loadMore() {
        guard !isLoading else { return }
        let canLoadChats = chatsHaveMore && !chatsFailed
        let canLoadThreads = threadsHaveMore && !threadsFailed
        // Advance whichever source has the newer loaded-through boundary, preserving
        // the mixed recent ordering instead of exhausting one list ahead of the other.
        if canLoadChats && (!canLoadThreads || chatBoundary >= threadBoundary) { retryChats() }
        if canLoadThreads && (!canLoadChats || threadBoundary >= chatBoundary) { retryThreads() }
    }

    private func loadChats(token: Int) async {
        defer {
            if current(token) {
                chatsLoading = false
                chatTask = nil
            }
        }
        do {
            let page = try await store.forwardDestinationChats(
                query: .init(limit: 30, after: chatCursor, archived: false))
            guard current(token) else { return }
            guard page.nextCursor == nil || page.nextCursor != chatCursor else {
                throw APIError.unexpectedResponse
            }
            var known = Set(chats.map(\.id))
            chats.append(
                contentsOf: page.chats.filter { !$0.archived && known.insert($0.id).inserted })
            chatBoundary = page.chats.last?.lastMessageAt ?? .distantPast
            chatCursor = page.nextCursor
            chatsHaveMore = page.nextCursor != nil
        } catch {
            guard current(token) else { return }
            chatsFailed = true
        }
    }

    private func loadThreads(token: Int) async {
        defer {
            if current(token) {
                threadsLoading = false
                threadTask = nil
            }
        }
        do {
            let page = try await store.forwardDestinationThreads(
                query: .init(limit: 30, before: threadCursor, archived: false))
            guard current(token) else { return }
            guard page.nextCursor == nil || page.nextCursor != threadCursor else {
                throw APIError.unexpectedResponse
            }
            var known = Set(threads.map(\.conversationKey))
            threads.append(
                contentsOf: page.threads.filter {
                    !$0.archived && known.insert($0.conversationKey).inserted
                })
            threadBoundary = page.threads.last?.lastReplyAt ?? .distantPast
            threadCursor = page.nextCursor
            threadsHaveMore = page.nextCursor != nil
        } catch {
            guard current(token) else { return }
            threadsFailed = true
        }
    }

    func select(_ target: ConversationListItem, onEnqueued: @escaping () -> Void) {
        guard !selectionBlocked else { return }
        isResolving = true
        let token = generation
        selectionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.current(token) {
                    self.isResolving = false
                    self.selectionTask = nil
                }
            }
            do {
                let selection = try await self.resolveSources(token: token)
                guard self.current(token), self.failure != .stale else { return }
                try self.validate(selection)
                self.resolvedSources = selection
                self.failure = nil
                let pendingAudio = selection.contains(where: self.isPendingAudio)
                let nestedForward =
                    selection.count > 1
                    && selection.contains {
                        $0.messageType == .forwarded
                            && $0.forwardedPreview?.containsForwardedMessages == true
                    }
                if pendingAudio || nestedForward {
                    self.confirmation = Confirmation(
                        target: target, sources: selection,
                        pendingAudio: pendingAudio, nestedForward: nestedForward)
                } else {
                    await self.submit(
                        target, sources: selection, allowPlaceholders: false,
                        token: token, onEnqueued: onEnqueued)
                }
            } catch {
                guard self.current(token), self.failure != .stale else { return }
                self.failure = error as? Failure ?? .loadFailed
            }
        }
    }

    func cancelConfirmation() { confirmation = nil }

    func confirm(_ value: Confirmation, onEnqueued: @escaping () -> Void) {
        guard isOpen, !isSubmitting, !didEnqueue, failure != .stale else { return }
        confirmation = nil
        let token = generation
        selectionTask = Task { [weak self] in
            guard let self else { return }
            await self.submit(
                value.target, sources: value.sources, allowPlaceholders: true,
                token: token, onEnqueued: onEnqueued)
            if self.current(token) { self.selectionTask = nil }
        }
    }

    private func resolveSources(token: Int) async throws -> [MessageResponse] {
        if let loadSources {
            do {
                let loaded = try await loadSources()
                guard current(token) else { throw CancellationError() }
                try validate(loaded)
                return loaded
            } catch let error as ForwardDestinationPicker.SourceError {
                guard current(token) else { throw CancellationError() }
                switch error {
                case .tooMany: throw Failure.tooMany
                case .unavailable: throw Failure.topicUnavailable
                }
            }
        }
        try validate(sources)
        return sources
    }

    private func validate(_ selection: [MessageResponse]) throws {
        guard !selection.isEmpty else {
            throw loadSources == nil ? Failure.unavailable : Failure.topicUnavailable
        }
        guard selection.count <= 100 else { throw Failure.tooMany }
        guard let chatID = sources.first?.chatId, !chatID.isEmpty,
            Set(selection.map(\.id)).count == selection.count,
            selection.allSatisfy({ $0.chatId == chatID })
        else { throw Failure.unavailable }
        guard !selection.contains(where: { $0.isDeleted || removedIDs.contains($0.id) }) else {
            throw Failure.stale
        }
        guard selection.allSatisfy({ $0.messageType != .system && $0.messageType != .invite })
        else {
            throw loadSources == nil ? Failure.unavailable : Failure.topicUnavailable
        }
    }

    private func isPendingAudio(_ message: MessageResponse) -> Bool {
        store.outgoingQueue.forwardPlaceholderReason(for: message, merging: false) == "pendingAudio"
    }

    private func submit(
        _ target: ConversationListItem, sources selection: [MessageResponse],
        allowPlaceholders: Bool, token: Int, onEnqueued: @escaping () -> Void
    ) async {
        guard current(token), !didEnqueue, failure != .stale else { return }
        do {
            try validate(selection)
            isSubmitting = true
            defer { if current(token) { isSubmitting = false } }
            try await store.outgoingQueue.enqueueForward(
                chatID: target.id.chatID, threadID: target.id.threadID,
                sources: selection, allowPlaceholders: allowPlaceholders)
            guard current(token) else { return }
            didEnqueue = true
            onEnqueued()
        } catch {
            guard current(token), failure != .stale else { return }
            failure = error as? Failure ?? .enqueueFailed
        }
    }

    private func receive(_ change: ConversationChange) {
        guard isOpen else { return }
        let deleted: [MessageID]
        let chatID: String
        switch change {
        case .reset:
            stop()
            return
        case .realtime(.messageDeleted(let message)):
            chatID = message.chatId
            deleted = [message.id]
        case .realtime(.messagesBulkDeleted(let payload)):
            chatID = payload.chatId
            deleted = payload.messageIds
        default:
            return
        }
        guard chatID == sources.first?.chatId else { return }
        removedIDs.formUnion(deleted)
        let watched = confirmation?.sources ?? (resolvedSources.isEmpty ? sources : resolvedSources)
        if watched.contains(where: { removedIDs.contains($0.id) }) {
            failure = .stale
            confirmation = nil
            selectionTask?.cancel()
            selectionTask = nil
            isResolving = false
            isSubmitting = false
        }
    }
}
