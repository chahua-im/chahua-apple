import ChahuaAPI
import SwiftUI
import UniformTypeIdentifiers

struct ChatDetailView: View {
    let chat: ChatListItem
    let navigationTitle: String?
    let threadID: String?
    let initialPosition: TimelineInitialPosition
    private let onOpenThread: ((MessageResponse) -> Void)?
    private var conversationKey: ConversationKey { .init(chatID: chat.id, threadID: threadID) }
    @ObservedObject private var store: ChatStore
    @StateObject private var model: ConversationTimelineModel
    @ObservedObject private var reactions: MessageReactionController
    @ObservedObject private var pins: ChatPinController
    @ObservedObject private var savedMessages: SavedMessageController
    @ObservedObject private var drafts: ChatDraftStore
    @ObservedObject private var outgoingQueue: OutgoingMessageQueue
    @State private var interactionContext: MessageInteractionContext
    @State private var hasLoadedInteractionPermissions = false
    @State private var permissionRequestRevision = 0
    @State private var failedMessageID: String?
    @State private var showsRetryOptions = false
    @State private var isTimelineVisible = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.openUserProfile) private var openUserProfile
    @Environment(\.openGroupInvite) private var openGroupInvite
    @Environment(\.imageDetailPresenter) private var imageDetailPresenter
    @State private var replyFocusRequest = 0
    @State private var editingMessage: MessageResponse?
    @State private var editText = ""
    @State private var isUpdatingMessage = false
    @State private var isComposerComposing = false
    @State private var editError: String?
    @State private var outboxError: String?
    @State private var savedMessageToRetry: MessageResponse?
    @StateObject private var composerAttachments = ComposerAttachmentState()
    @State private var isMediaDropTargeted = false
    @State private var showsPinnedMessages = false
    @State private var showsThreadInfo = false
    @State private var infoMessageTarget: MessageResponse?
    @State private var infoProfileUID: Int32?
    @State private var infoChatTarget: ChatListItem?
    @State private var presentedFile: AttachmentResponse?
    @State private var pinToUnpin: PinResponse?
    @State private var messageToDelete: MessageResponse?
    @State private var deleteError = false
    @State private var stickerToView: StickerSelection?
    @State private var reactionDetailsMessage: ReactionDetailsSelection?
    @State private var forwardRequest: ForwardSelection?
    @State private var recordRequest: RecordSelection?
    @State private var systemMessageTarget: MessageResponse?
    @State private var systemTargetError: String?
    @State private var systemTargetTask: Task<Void, Never>?
    @State private var keepsTimelineForPushedDetail = false
    @State private var showsForwardStarted = false
    @State private var selectionToDelete: TimelineBubbleActions?
    @State private var selectionDeleteTask: Task<Void, Never>?
    @State private var isDeletingSelection = false
    @State private var forwardingThreadRoot: MessageResponse?
    @State private var forwardingThreadReplyCount: Int64?

    private struct ForwardSelection: Identifiable {
        let id = UUID()
        let sources: [MessageResponse]
        var wholeThread = false
        var moveFrom: ConversationKey?
        var expectedForwardID: UUID?
        var onPrepared: () -> Void = {}
    }

    private struct RecordSelection: Identifiable, Hashable {
        let id: MessageID
        let chatID: String
    }

    private struct StickerSelection: Identifiable {
        let id: String
    }

    private struct ReactionDetailsSelection: Identifiable {
        let chatID: String
        let id: MessageID
    }

    init(
        chat: ChatListItem,
        currentUserID: Int32,
        store: ChatStore,
        navigationTitle: String? = nil,
        threadID: String? = nil,
        initialPosition: TimelineInitialPosition? = nil,
        onOpenThread: ((MessageResponse) -> Void)? = nil
    ) {
        self.chat = chat
        self.navigationTitle = navigationTitle
        self.threadID = threadID
        self.onOpenThread = onOpenThread
        self.initialPosition =
            initialPosition
            ?? (chat.unreadCount > 0 ? .unread(after: chat.lastReadMessageId) : .liveEdge)
        self.store = store
        self.reactions = store.reactions
        self.pins = store.pins
        self.savedMessages = store.savedMessages
        self.drafts = store.drafts
        self.outgoingQueue = store.outgoingQueue
        _interactionContext = State(
            initialValue: .init(isDM: chat.kind == .dm, isThreadView: threadID != nil))
        let fetchReadReceipt: (@MainActor (String?) async throws -> MessageID?)?
        if chat.kind == .dm {
            fetchReadReceipt = { threadID in
                let receipt = try await store.readReceipt(
                    chatID: chat.id, threadID: threadID.flatMap(MessageID.init))
                return receipt.lastReadMessageId
            }
        } else {
            fetchReadReceipt = nil
        }
        _model = StateObject(
            wrappedValue: ConversationTimelineModel(
                chatID: chat.id,
                currentUserID: currentUserID,
                isGroupChat: chat.kind == .group,
                source: store,
                messageStore: store.conversationMessages,
                threadID: threadID,
                markRead: { messageID in
                    try await store.markRead(
                        chatID: chat.id, threadID: threadID, messageID: messageID)
                },
                fetchReadReceipt: fetchReadReceipt,
                fetchUnreadMentions: { scope in
                    try await store.unreadMentions(chatID: chat.id, threadID: scope)
                },
                fetchUnreadReactions: { scope in
                    try await store.unreadReactions(chatID: chat.id, threadID: scope)
                },
                acknowledgeReactions: { scope, readThrough in
                    try await store.acknowledgeReactions(
                        chatID: chat.id, threadID: scope, readThrough: readThrough)
                }
            ))
    }

    private var initialTimelineSurface: some View {
        forwardingSurface
            .navigationTitle(navigationTitle ?? chat.chatDisplayName)
            .onAppear {
                isTimelineVisible = true
                if threadID == nil {
                    model.updateReadState(
                        unreadCount: chat.unreadCount, lastReadMessageID: chat.lastReadMessageId)
                }
                store.registerTimeline(model)
                model.setReadTrackingActive(scenePhase == .active)
            }
            .task {
                if keepsTimelineForPushedDetail, model.state.content == .ready {
                    keepsTimelineForPushedDetail = false
                } else {
                    await model.open(position: initialPosition)
                }
            }
            .task(id: threadID) {
                guard let threadID, let rootID = MessageID(threadID) else { return }
                forwardingThreadRoot = try? await store.forwardSourceMessage(
                    chatID: chat.id, messageID: rootID)
                synchronizeSpeakingPermissions()
            }
            .task { await loadInteractionPermissions() }
            .onChange(of: store.groupInfoByChatID[chat.id]) { _, _ in
                synchronizeSpeakingPermissions()
            }
            .task { await savedMessages.ensure(chatID: chat.id) }
    }

    private var attachmentPresentationSurface: some View {
        initialTimelineSurface
            .toolbar {
                if threadID != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Thread Info", systemImage: "info.circle") {
                            showsThreadInfo = true
                        }
                    }
                }
            }
            .sheet(isPresented: $showsThreadInfo) {
                if let threadID {
                    NavigationStack {
                        ThreadInfoView(
                            store: store, chat: chat, threadID: threadID, timeline: model,
                            onOpenMessage: { infoMessageTarget = $0 }
                        )
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showsThreadInfo = false }
                            }
                        }
                        .navigationDestination(item: $infoMessageTarget) { message in
                            ChatDetailView(
                                chat: chat, currentUserID: model.currentUserID, store: store,
                                threadID: message.replyRootId,
                                initialPosition: .message(message.id))
                        }
                        .navigationDestination(item: $infoProfileUID) { uid in
                            UserProfileView(
                                uid: uid, currentUserID: model.currentUserID, store: store,
                                onOpenChat: { infoChatTarget = $0 })
                        }
                        .navigationDestination(item: $infoChatTarget) { target in
                            ChatDetailView(
                                chat: target, currentUserID: model.currentUserID, store: store)
                        }
                    }
                    .environment(\.openUserProfile, { infoProfileUID = $0 })
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { presentedFile != nil },
                    set: { if !$0 { presentedFile = nil } })
            ) {
                if let file = presentedFile {
                    NavigationStack {
                        MessageFileAttachmentView(
                            url: URL(string: file.url), fileName: file.fileName,
                            contentType: file.kind, byteCount: file.size
                        )
                        .padding()
                        .frame(minWidth: 300, minHeight: 180)
                        .navigationTitle(file.fileName)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { presentedFile = nil }
                            }
                        }
                    }
                }
            }
    }

    private var savedAndPermissionSurface: some View {
        attachmentPresentationSurface
            .alert(
                "Saved Messages",
                isPresented: Binding(
                    get: { savedMessages.errorMessage != nil },
                    set: { if !$0 { savedMessages.clearError() } })
            ) {
                if let message = savedMessageToRetry {
                    Button("Retry") {
                        savedMessages.clearError()
                        Task { await savedMessages.toggle(message) }
                    }
                }
                Button("OK") { savedMessages.clearError() }
            } message: {
                Text(savedMessages.errorMessage ?? "")
            }
            .onReceive(store.chatAccessInvalidations) { chatID in
                guard chatID == chat.id else { return }
                invalidateInteractionPermissions()
            }
            .onReceive(store.socialInvalidations) { _ in
                guard chat.kind == .dm else { return }
                invalidateInteractionPermissions()
            }
            .task {
                if threadID == nil { await pins.load(chatID: chat.id, force: true) }
            }
    }

    private var pinPresentationSurface: some View {
        savedAndPermissionSurface
            .sheet(item: $stickerToView) { selection in
                StickerPackSheet(
                    stickerID: selection.id, library: store.stickers,
                    currentUserID: model.currentUserID)
            }
            .sheet(item: $reactionDetailsMessage) { message in
                ReactionDetailsView(chatID: message.chatID, messageID: message.id) {
                    try await store.reactionDetails(chatID: message.chatID, messageID: message.id)
                }
            }
            .alert(
                "Unpin Message",
                isPresented: Binding(
                    get: { pinToUnpin != nil }, set: { if !$0 { pinToUnpin = nil } }
                )
            ) {
                if let pin = pinToUnpin {
                    Button("Unpin", role: .destructive) {
                        guard canManagePins else { return }
                        Task { await pins.unpin(pin) }
                    }
                }
                Button("Cancel", role: .cancel) { pinToUnpin = nil }
            } message: {
                Text("Would you like to unpin this message?")
            }
            .alert(
                "Pinned messages",
                isPresented: Binding(
                    get: { pins.error != nil && !showsPinnedMessages },
                    set: { if !$0 { pins.error = nil } }
                )
            ) {
                Button("OK") { pins.error = nil }
            } message: {
                Text(pins.error ?? "")
            }
    }

    private var mutationFeedbackSurface: some View {
        pinPresentationSurface
            .onChange(of: scenePhase) { _, phase in
                model.setReadTrackingActive(isTimelineVisible && phase == .active)
            }
            .alert(
                "Message actions",
                isPresented: Binding(
                    get: { reactions.error != nil },
                    set: { if !$0 { reactions.error = nil } }
                )
            ) {
                if !hasLoadedInteractionPermissions {
                    Button("Retry") { Task { await loadInteractionPermissions() } }
                }
                Button("OK") { reactions.error = nil }
            } message: {
                Text(reactions.error ?? "")
            }
            .confirmationDialog(
                "Message not sent", isPresented: $showsRetryOptions, titleVisibility: .visible
            ) {
                Button("Resend this message") { retry(.message) }
                Button("Retry this and subsequent messages") { retry(.messageAndSubsequent) }
                Button("Cancel", role: .cancel) { failedMessageID = nil }
            } message: {
                if let failedMessageID,
                    let mode = outgoingQueue.pendingMessages(chatID: chat.id, threadID: threadID)
                        .first(where: { $0.clientGeneratedID == failedMessageID })?
                        .speakingRestriction
                {
                    Text(mode.restrictionExplanation)
                }
            }
            .alert(
                "Couldn’t open message",
                isPresented: Binding(
                    get: { systemTargetError != nil },
                    set: { if !$0 { systemTargetError = nil } })
            ) {
                Button("OK") { systemTargetError = nil }
            } message: {
                Text(systemTargetError ?? "")
            }
            .alert(
                "Couldn’t edit message",
                isPresented: Binding(get: { editError != nil }, set: { if !$0 { editError = nil } })
            ) {
                Button("OK") { editError = nil }
            } message: {
                Text(editError ?? "")
            }
            .alert(
                "Couldn’t update outbox",
                isPresented: Binding(
                    get: { outboxError != nil }, set: { if !$0 { outboxError = nil } })
            ) {
                Button("OK") { outboxError = nil }
            } message: {
                Text(outboxError ?? "")
            }
    }

    var body: some View {
        mutationFeedbackSurface
            .onReceive(store.outgoingQueue.events) { _ in
                guard let failedMessageID else { return }
                if !store.outgoingQueue.pendingMessages(chatID: chat.id, threadID: threadID)
                    .contains(where: {
                        $0.clientGeneratedID == failedMessageID && $0.state == .failed
                    })
                {
                    showsRetryOptions = false
                    self.failedMessageID = nil
                }
            }
            .onReceive(store.conversationMessages.changes) { change in
                guard case .realtime(.threadUpdate(let update)) = change,
                    update.chatId == chat.id, update.threadRootId == threadID
                else { return }
                forwardingThreadReplyCount = update.replyCount
                interactionContext.hasExistingThread = true
            }
            .onDisappear {
                selectionDeleteTask?.cancel()
                systemTargetTask?.cancel()
                systemTargetTask = nil
                selectionDeleteTask = nil
                forwardRequest = nil
                isTimelineVisible = false
                if keepsTimelineForPushedDetail {
                    model.setReadTrackingActive(false)
                } else {
                    model.close(acknowledgingActivity: scenePhase == .active)
                }
                store.unregisterTimeline(model)
                Task { await drafts.flushDraft(chatID: chat.id, threadID: threadID) }
            }
    }

    private var forwardingSurface: some View {
        forwardingSheets
            .alert(
                "Delete these messages?",
                isPresented: Binding(
                    get: { selectionToDelete != nil },
                    set: { if !$0 { selectionToDelete = nil } })
            ) {
                if let actions = selectionToDelete {
                    Button("Delete", role: .destructive) { deleteSelection(actions: actions) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .preference(key: ForwardThreadActionKey.self, value: wholeThreadForwardAction)
            .preference(
                key: ThreadInfoActionKey.self,
                value: threadID == nil
                    ? nil
                    : ThreadInfoAction(conversation: conversationKey) {
                        showsThreadInfo = true
                    }
            )
            .overlay(alignment: .top) {
                if showsForwardStarted {
                    Text("Forwarding started")
                        .font(.callout)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 72)
                        .allowsHitTesting(false)
                }
            }
            .task(id: showsForwardStarted) {
                guard showsForwardStarted else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                showsForwardStarted = false
            }
    }

    private var forwardingSheets: some View {
        deletionSurface
            .sheet(item: $forwardRequest) { request in forwardingPicker(request) }
            .navigationDestination(item: $systemMessageTarget) { message in
                ChatDetailView(
                    chat: chat, currentUserID: model.currentUserID, store: store,
                    threadID: message.replyRootId, initialPosition: .message(message.id),
                    onOpenThread: onOpenThread)
            }
            .navigationDestination(item: $recordRequest) { request in
                ForwardedRecordsView(
                    store: store, chatID: request.chatID, messageID: request.id)
            }
    }

    private func forwardingPicker(_ request: ForwardSelection) -> some View {
        let loader: (@MainActor () async throws -> [MessageResponse])?
        if request.wholeThread {
            loader = { @MainActor () async throws -> [MessageResponse] in
                try await self.loadWholeThreadForForwarding()
            }
        } else {
            loader = nil
        }
        return ForwardDestinationPicker(
            store: store, sources: request.sources, loadSources: loader,
            moveFrom: request.moveFrom, expectedForwardID: request.expectedForwardID
        ) {
            request.onPrepared()
        }
    }

    private func selectionToolbar(actions: TimelineBubbleActions) -> some View {
        HStack(spacing: 16) {
            Button(role: .destructive) {
                selectionToDelete = actions
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Delete selected messages")
            .disabled(!canDeleteSelection(actions.selectionMessages) || isDeletingSelection)
            Spacer(minLength: 0)
            if isDeletingSelection {
                ProgressView().controlSize(.small)
            }
            Text("\(actions.selectedMessageIDs.count) messages")
                .font(.headline)
            Spacer(minLength: 0)
            Button("Cancel") {
                selectionDeleteTask?.cancel()
                actions.endMessageSelection?()
            }
            Button {
                forwardRequest = ForwardSelection(
                    sources: actions.selectionMessages,
                    onPrepared: { actions.endMessageSelection?() })
            } label: {
                Image(systemName: "arrowshape.turn.up.right")
            }
            .accessibilityLabel("Forward")
            .disabled(actions.selectedMessageIDs.isEmpty || isDeletingSelection)
        }
        .buttonStyle(.borderless)
        .padding()
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private func canDeleteSelection(_ messages: [MessageResponse]) -> Bool {
        interactionContext.canWrite && !messages.isEmpty && messages.count <= 100
            && messages.allSatisfy { $0.chatId == chat.id }
            && messages.allSatisfy {
                !$0.isDeleted
                    && ($0.sender.uid == model.currentUserID || interactionContext.isAdmin)
            }
    }

    private func deleteSelection(actions: TimelineBubbleActions) {
        let messages = actions.selectionMessages
        guard canDeleteSelection(messages), !isDeletingSelection else { return }
        isDeletingSelection = true
        selectionDeleteTask = Task {
            defer {
                isDeletingSelection = false
                selectionDeleteTask = nil
            }
            var ready: [MessageResponse] = []
            var unresolved = false
            for message in messages {
                do {
                    while outgoingQueue.forwardPlaceholderReason(for: message, merging: false)
                        == "pendingAudio"
                    {
                        try await Task.sleep(for: .milliseconds(250))
                    }
                    try Task.checkCancellation()
                    if let current = recallCandidate(message), canDeleteSelection([current]) {
                        ready.append(current)
                    } else {
                        unresolved = true
                    }
                } catch { return }
            }
            do {
                try Task.checkCancellation()
                // Permission and deletion state can change while voice publication waits.
                let batch = ready.compactMap(recallCandidate).filter {
                    canDeleteSelection([$0])
                }
                unresolved = unresolved || batch.count != ready.count
                guard !batch.isEmpty else {
                    deleteError = true
                    return
                }
                let confirmed = try await store.bulkRecallMessages(batch)
                try Task.checkCancellation()
                for id in confirmed { actions.removeSelectedMessage?(id) }
                if !unresolved && confirmed.count == messages.count {
                    actions.endMessageSelection?()
                } else {
                    deleteError = true
                }
            } catch is CancellationError {
                return
            } catch {
                deleteError = true
            }
        }
    }

    private func recallCandidate(_ message: MessageResponse) -> MessageResponse? {
        guard !model.knownDeletedMessageIDs.contains(message.id) else { return nil }
        for case .message(let row) in model.rows {
            if row.entry.remoteMessage?.id == message.id { return row.entry.remoteMessage }
        }
        return message
    }

    private var wholeThreadForwardAction: ForwardThreadAction? {
        guard let threadID else { return nil }
        let known = (store.state.threads + store.state.archivedThreads).first {
            $0.chatId == chat.id && $0.threadRootMessage.id.description == threadID
        }
        let loadedRoot =
            model.rows.compactMap { row -> MessageResponse? in
                guard case .message(let row) = row,
                    row.entry.remoteMessage?.id.description == threadID
                else { return nil }
                return row.entry.remoteMessage
            }.first ?? forwardingThreadRoot
        guard
            let count = forwardingThreadReplyCount.map({ $0 + 1 })
                ?? known.map({ $0.replyCount + 1 })
                ?? loadedRoot.map({ ($0.threadInfo?.replyCount ?? 0) + 1 }),
            count <= 100, let root = loadedRoot, !root.isDeleted,
            !model.knownDeletedMessageIDs.contains(root.id)
        else { return nil }
        return ForwardThreadAction(conversation: conversationKey, count: count) {
            forwardRequest = ForwardSelection(sources: [root], wholeThread: true)
        }
    }

    private func loadWholeThreadForForwarding() async throws -> [MessageResponse] {
        guard let threadID else { throw ForwardDestinationPicker.SourceError.unavailable }
        let page = try await store.fetchMessages(
            chatID: chat.id, query: .init(max: 100, threadID: threadID))
        guard page.olderCursor == nil else { throw ForwardDestinationPicker.SourceError.tooMany }
        return page.messages.filter { !$0.isDeleted && $0.messageType != .system }
    }

    private var deletionSurface: some View {
        conversationDropSurface
            .confirmationDialog(
                AppLanguage.localized("Delete Message"),
                isPresented: Binding(
                    get: { messageToDelete != nil }, set: { if !$0 { messageToDelete = nil } }),
                titleVisibility: .visible,
                presenting: messageToDelete
            ) { message in
                Button("Delete", role: .destructive) {
                    Task {
                        let deleted = await store.deleteMessage(message)
                        if deleted {
                            if editingMessage?.id == message.id { cancelEditing() }
                        } else {
                            deleteError = true
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { message in
                if message.sender.uid == model.currentUserID {
                    Text("Are you sure you want to delete this message?")
                } else {
                    Text(
                        "Are you sure you want to delete this message from \(message.sender.name ?? AppLanguage.localized("this user"))?"
                    )
                }
            }
            .alert("Failed to delete message", isPresented: $deleteError) {
                Button("OK") {}
            }
    }

    private var conversationDropSurface: some View {
        MessageSelectionHost(model: model, actions: bubbleActions) { selectedActions in
            Group {
                #if os(macOS)
                    conversationBody(actions: selectedActions)
                #else
                    MessageInteractionHost(
                        model: model, context: interactionContext, actions: selectedActions
                    ) { actions in
                        conversationBody(actions: actions)
                    }
                #endif
            }
        }
        .contentShape(Rectangle())
        .onDrop(of: [.item, .fileURL], isTargeted: $isMediaDropTargeted) { providers in
            guard interactionContext.canSend, editingMessage == nil,
                outgoingQueue.storageState == .ready,
                !drafts.committingDrafts.contains(conversationKey)
            else { return false }
            return composerAttachments.acceptDrop(providers)
        }
        .overlay {
            if isMediaDropTargeted, interactionContext.canSend, editingMessage == nil,
                !composerAttachments.isAcquiring
            {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    private func conversationBody(actions interactiveActions: TimelineBubbleActions) -> some View {
        GeometryReader { geometry in
            timelineSurface(actions: interactiveActions)
                .modifier(
                    ChatPinnedBarOverlay(isVisible: showsPinBar) {
                        pinnedMessageBar
                    }
                )
                .modifier(
                    ChatComposerOverlay {
                        VStack(spacing: 0) {
                            if interactiveActions.isSelectingMessages {
                                selectionToolbar(actions: interactiveActions)
                            } else {
                                savedStatusFeedback
                                if store.outgoingQueue.storageState == .failed
                                    || drafts.draftSaveFailed
                                {
                                    HStack {
                                        Text("Couldn’t save messages on this device.")
                                            .font(.caption)
                                        Spacer(minLength: 8)
                                        Button("Retry") { Task { await store.retryLocalStorage() } }
                                    }
                                    .padding(12)
                                    .background(
                                        .regularMaterial, in: RoundedRectangle(cornerRadius: 16)
                                    )
                                    .padding(.horizontal, 12)
                                } else if store.outgoingQueue.storageState == .loading {
                                    ProgressView("Loading saved messages…")
                                        .controlSize(.small)
                                        .padding(12)
                                        .background(
                                            .regularMaterial, in: RoundedRectangle(cornerRadius: 16)
                                        )
                                }
                                if let selection = drafts.pendingForwards[conversationKey] {
                                    pendingForwardPreview(selection)
                                }
                                if interactionContext.canWrite,
                                    !(editingMessage.map(isEditable) ?? interactionContext.canSend),
                                    let mode = interactionContext.speakingMode
                                {
                                    Text(mode.restrictionExplanation)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 16).padding(.vertical, 8)
                                }
                                MessageComposerView(
                                    text: composerText,
                                    attachmentState: composerAttachments,
                                    maxHeight: max(36, geometry.size.height / 3),
                                    isEnabled: editingMessage.map(isEditable)
                                        ?? interactionContext.canSend,
                                    canSend: canSubmitComposer,
                                    onSubmit: submitComposer,
                                    onCompositionChanged: { composing in
                                        isComposerComposing = composing
                                        guard editingMessage == nil else { return }
                                        drafts.setDraftComposing(
                                            composing, chatID: chat.id, threadID: threadID)
                                    },
                                    replyToMessage: drafts.draftReply(
                                        chatID: chat.id, threadID: threadID),
                                    replyFocusRequest: replyFocusRequest,
                                    onCancelReply: {
                                        drafts.setDraftReply(
                                            nil, chatID: chat.id, threadID: threadID)
                                    },
                                    onOpenReply: { id in Task { await model.jumpToMessage(id) } },
                                    editingMessage: editingMessage,
                                    onCancelEdit: cancelEditing,
                                    onRequestEditLastMessage: requestEditLastOwnMessage,
                                    attachments: outgoingQueue.draftAttachments(
                                        chatID: chat.id, threadID: threadID),
                                    attachmentProgress: outgoingQueue.attachmentProgress,
                                    compressionEnabled: outgoingQueue.compressionEnabled(
                                        chatID: chat.id, threadID: threadID),
                                    onImportImages: { urls in
                                        try await drafts.flushForAttachmentChange(
                                            chatID: chat.id, threadID: threadID)
                                        try await outgoingQueue.importImages(
                                            urls: urls, chatID: chat.id, threadID: threadID)
                                    },
                                    onImportFiles: { urls in
                                        try await drafts.flushForAttachmentChange(
                                            chatID: chat.id, threadID: threadID)
                                        try await outgoingQueue.importFiles(
                                            urls: urls, chatID: chat.id, threadID: threadID)
                                    },
                                    onRemoveAttachment: { id in
                                        try await drafts.flushForAttachmentChange(
                                            chatID: chat.id, threadID: threadID)
                                        try await outgoingQueue.removeAttachment(
                                            id: id, chatID: chat.id, threadID: threadID)
                                    },
                                    onRetryAttachment: { id in
                                        try await drafts.flushForAttachmentChange(
                                            chatID: chat.id, threadID: threadID)
                                        try await outgoingQueue.retryAttachment(
                                            id: id, chatID: chat.id, threadID: threadID)
                                    },
                                    onCompressionChanged: { enabled in
                                        try await drafts.flushForAttachmentChange(
                                            chatID: chat.id, threadID: threadID)
                                        try await outgoingQueue.setCompressionEnabled(
                                            enabled, chatID: chat.id, threadID: threadID)
                                    },
                                    onReorderAttachments: { ids in
                                        try await drafts.flushForAttachmentChange(
                                            chatID: chat.id, threadID: threadID)
                                        try await outgoingQueue.reorderAttachments(
                                            ids: ids, chatID: chat.id, threadID: threadID)
                                    },
                                    onDiscardAttachments: {
                                        try await drafts.discardAttachments(
                                            chatID: chat.id, threadID: threadID)
                                    },
                                    stickerLibrary: store.stickers,
                                    onSendSticker: sendSticker,
                                    onSendVoice: sendVoice,
                                    onSearchMembers: { query in
                                        try await store.searchMembers(chatID: chat.id, query: query)
                                    }
                                )
                            }
                        }
                    })
        }
    }

    @ViewBuilder
    private var savedStatusFeedback: some View {
        if let error = savedMessages.scopeError(chatID: chat.id) {
            HStack {
                Text(error).font(.caption)
                Spacer(minLength: 8)
                Button("Retry") {
                    Task { await savedMessages.ensure(chatID: chat.id) }
                }
                .disabled(savedMessages.isLoading(chatID: chat.id))
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private func timelineSurface(actions: TimelineBubbleActions) -> some View {
        #if os(macOS)
            ConversationTimelineView(
                model: model, loadsInitialAutomatically: false, actions: actions,
                interactionContext: interactionContext)
        #else
            ConversationTimelineView(
                model: model, loadsInitialAutomatically: false, actions: actions)
        #endif
    }

    private func loadInteractionPermissions() async {
        permissionRequestRevision &+= 1
        let revision = permissionRequestRevision
        do {
            let info = try await store.groupInfo(chatID: chat.id)
            let permissions: MessageInteractionContext?
            if info.kind == .dm {
                permissions = await reactions.loadPermissions(chatID: chat.id)
            } else {
                permissions = MessageInteractionContext(
                    isDM: false, canWrite: info.myRole != nil, isAdmin: info.myRole == .admin)
            }
            guard let permissions, revision == permissionRequestRevision, !Task.isCancelled
            else { return }
            interactionContext = permissions
            interactionContext.isThreadView = threadID != nil
            hasLoadedInteractionPermissions = true
            synchronizeSpeakingPermissions()
        } catch {
            guard revision == permissionRequestRevision, !Task.isCancelled else { return }
            reactions.error = AppLanguage.localized(
                "Couldn’t load message permissions. Please try again.")
        }
    }

    private func synchronizeSpeakingPermissions() {
        interactionContext.hasExistingThread =
            interactionContext.hasExistingThread
            || forwardingThreadRoot?.threadInfo != nil
            || (store.state.threads + store.state.archivedThreads).contains {
                $0.chatId == chat.id && $0.threadRootMessage.id.description == threadID
            }
        guard chat.kind != .dm else { return }
        let info = store.groupInfoByChatID[chat.id]
        interactionContext.canWrite = info?.myRole != nil
        interactionContext.isAdmin = info?.myRole == .admin
        interactionContext.speakingMode = store.speakingMode(chatID: chat.id)
    }

    private func invalidateInteractionPermissions() {
        // Fence stale responses and open action snapshots before the async reload.
        permissionRequestRevision &+= 1
        interactionContext.canWrite = false
        hasLoadedInteractionPermissions = false
        selectionDeleteTask?.cancel()
        Task { await loadInteractionPermissions() }
    }

    private var bubbleActions: TimelineBubbleActions {
        var actions = TimelineBubbleActions()
        actions.interactionContext = interactionContext
        actions.openMention = { openUserProfile($0) }
        actions.openSystemMessage = openSystemMessage
        actions.savedMessageIDs = savedMessages.savedIDs(chatID: chat.id)
        actions.pendingSavedMessageIDs = savedMessages.pendingIDs(chatID: chat.id)
        if savedMessages.hasLoaded(chatID: chat.id) {
            actions.toggleSavedMessage = { message in
                guard !message.isDeleted,
                    !savedMessages.isMutating(chatID: message.chatId, messageID: message.id)
                else { return }
                savedMessageToRetry = message
                Task { await savedMessages.toggle(message) }
            }
        }
        actions.openAttachment = { attachment in
            presentedFile = attachment
        }
        actions.isSelectionBusy = isDeletingSelection
        actions.forwardMessage = { message in
            forwardRequest = ForwardSelection(sources: [message])
        }
        actions.openForwardedMessages = { message in
            keepsTimelineForPushedDetail = true
            recordRequest = RecordSelection(id: message.id, chatID: message.chatId)
        }
        if let imageDetailPresenter {
            actions.openMedia = { gallery in
                var gallery = gallery
                gallery.conversationTitle = navigationTitle ?? chat.chatDisplayName
                imageDetailPresenter.present(gallery)
            }
        }
        actions.openSticker = { stickerToView = StickerSelection(id: $0) }
        actions.openReactionDetails = {
            reactionDetailsMessage = ReactionDetailsSelection(chatID: $0.chatId, id: $0.id)
        }
        actions.pendingReactionMessageIDs = reactions.pendingMessageIDs
        actions.pinnedMessageIDs = Set(chatPins.map { $0.message.id })
        actions.pendingPinMessageIDs = pins.pendingMessageIDs
        if canManagePins,
            pins.pinsByChatID[chat.id] != nil, !pins.failedChatIDs.contains(chat.id)
        {
            actions.togglePin = requestPinChange
        }
        if let tail = outgoingQueue.snapshots[conversationKey]?.outgoing.last,
            outgoingQueue.snapshots[conversationKey]?.composingItem == nil, !tail.dispatchClaimed
        {
            actions.modifiablePendingMessageIDs = [tail.clientGeneratedID]
        }
        actions.blockPendingMessage = { pending in changePending(pending, revoke: false) }
        actions.revokePendingMessage = { pending in changePending(pending, revoke: true) }
        actions.openLink = { url in
            if let code = GroupInviteLink.code(from: url.absoluteString) {
                openGroupInvite(code)
            } else {
                openURL(url)
            }
        }
        if threadID == nil, onOpenThread != nil {
            actions.openThread = { id in
                for case .message(let row) in model.rows {
                    guard let message = row.entry.remoteMessage,
                        message.id == id, !message.isDeleted
                    else { continue }
                    guard message.threadInfo != nil || interactionContext.canCreateThread else {
                        return
                    }
                    onOpenThread?(message)
                    return
                }
            }
        }
        if interactionContext.canSend {
            actions.replyToMessage = { message in
                guard !drafts.committingDrafts.contains(conversationKey) else { return }
                drafts.setDraftReply(message.replyPreview, chatID: chat.id, threadID: threadID)
                replyFocusRequest &+= 1
            }
        }
        actions.editMessage = startEditing
        if interactionContext.canWrite {
            actions.deleteMessage = { message in
                guard !store.deletingMessageIDs.contains(message.id),
                    MessageActionPolicy(
                        messageType: message.messageType, isDeleted: message.isDeleted,
                        isOwn: message.sender.uid == model.currentUserID,
                        context: interactionContext
                    ).availability(of: .delete) == .enabled
                else { return }
                messageToDelete = message
            }
            actions.toggleReaction = { row, emoji in
                guard let message = row.entry.remoteMessage, !message.isDeleted else { return }
                Task {
                    await reactions.toggle(
                        message: message, emoji: emoji, currentUserID: model.currentUserID)
                }
            }
        }
        actions.openReply = { id in Task { await model.jumpToMessage(id) } }
        actions.openFailedMessage = { id in
            failedMessageID = id
            showsRetryOptions = true
        }
        return actions
    }

    private var chatPins: [PinResponse] { pins.pinsByChatID[chat.id] ?? [] }

    private var canManagePins: Bool {
        threadID == nil && interactionContext.canWrite
            && (interactionContext.isDM || interactionContext.isAdmin)
    }

    private var activePin: PinResponse? {
        ChatPinSelection.activePin(
            in: chatPins, bottomVisibleMessageDate: model.bottomVisibleMessageDate)
    }

    private var showsPinBar: Bool {
        threadID == nil && (activePin != nil || pins.failedChatIDs.contains(chat.id))
    }

    @ViewBuilder private var pinnedMessageBar: some View {
        if let pin = activePin {
            ChatPinnedMessageBar(
                pin: pin, count: chatPins.count,
                onJump: { jumpToPinnedMessage(pin.message) },
                onShowAll: { showsPinnedMessages = true },
                onOpenThread: pin.message.threadInfo != nil && onOpenThread != nil
                    ? { onOpenThread?(pin.message) } : nil,
                onUnpin: canManagePins && !pins.pendingMessageIDs.contains(pin.message.id)
                    ? { requestPinChange(pin.message) } : nil
            )
            .popover(
                isPresented: $showsPinnedMessages, attachmentAnchor: .rect(.bounds), arrowEdge: .top
            ) {
                ChatPinnedMessagesSheet(
                    chatID: chat.id, controller: pins,
                    canManage: canManagePins,
                    onSelect: jumpToPinnedMessage, onOpenThread: onOpenThread
                )
                .frame(width: 420, height: 420)
            }
        } else if pins.failedChatIDs.contains(chat.id) {
            Button {
                Task { await pins.load(chatID: chat.id, force: true) }
            } label: {
                Label("Couldn’t load pinned messages. Retry", systemImage: "arrow.clockwise")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
            .modifier(ChatGlassSurface(cornerRadius: 24))
        }
    }

    private func jumpToPinnedMessage(_ message: MessageResponse) {
        Task { await model.jumpToMessage(message.id) }
    }

    private func requestPinChange(_ message: MessageResponse) {
        guard canManagePins,
            !message.isDeleted,
            !pins.pendingMessageIDs.contains(message.id)
        else { return }
        if let pin = chatPins.first(where: { $0.message.id == message.id }) {
            pinToUnpin = pin
        } else {
            Task { await pins.pin(message) }
        }
    }

    private var composerText: Binding<String> {
        Binding(
            get: {
                editingMessage == nil
                    ? drafts.draftText(chatID: chat.id, threadID: threadID) : editText
            },
            set: {
                if editingMessage == nil {
                    drafts.setDraftText($0, chatID: chat.id, threadID: threadID)
                } else {
                    editText = $0
                }
            }
        )
    }

    private var canSubmitComposer: Bool {
        let text =
            (editingMessage == nil
            ? drafts.draftText(chatID: chat.id, threadID: threadID) : editText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard editingMessage.map(isEditable) ?? interactionContext.canSend else { return false }
        if let editingMessage {
            return !isUpdatingMessage
                && (isComposerComposing
                    || (!text.isEmpty
                        && text
                            != editingMessage.message?.trimmingCharacters(
                                in: .whitespacesAndNewlines)))
        }
        return outgoingQueue.storageState == .ready
            && !drafts.committingDrafts.contains(conversationKey)
    }

    private func sendSticker(_ sticker: MessageStickerResponse) async -> Bool {
        guard interactionContext.canSend, editingMessage == nil,
            outgoingQueue.storageState == .ready, !drafts.committingDrafts.contains(conversationKey)
        else { return false }
        do {
            let sent = try await drafts.submitSticker(sticker, chatID: chat.id, threadID: threadID)
            if sent { model.revealLatestAfterSend() }
            return sent
        } catch {
            outboxError = error.localizedDescription
            return false
        }
    }

    private func sendVoice(_ fileURL: URL) async -> Bool {
        guard interactionContext.canSend, editingMessage == nil,
            outgoingQueue.storageState == .ready, !drafts.committingDrafts.contains(conversationKey)
        else { return false }
        do {
            let sent = try await drafts.submitVoice(
                fileURL: fileURL, chatID: chat.id, threadID: threadID)
            if sent { model.revealLatestAfterSend() }
            return sent
        } catch {
            outboxError = error.localizedDescription
            return false
        }
    }

    private func submitComposer(_ text: String) async -> Bool {
        guard editingMessage.map(isEditable) ?? interactionContext.canSend else { return false }
        guard let message = editingMessage else {
            let sent = await drafts.submitDraft(chatID: chat.id, threadID: threadID, text: text)
            if sent { model.revealLatestAfterSend() }
            if !sent, let error = drafts.submissionError { outboxError = error }
            return sent
        }
        guard !isUpdatingMessage else { return false }
        isUpdatingMessage = true
        let submittedText = text
        let didUpdate = await store.updateMessage(message, text: submittedText)
        isUpdatingMessage = false
        if didUpdate {
            if editText == submittedText {
                cancelEditing()
            } else {
                editingMessage = message.replacingMessageText(
                    submittedText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } else {
            editError =
                store.messageUpdateError
                ?? AppLanguage.localized("Couldn’t edit this message. Please try again.")
        }
        return didUpdate
    }

    private func isEditable(_ message: MessageResponse) -> Bool {
        MessageActionPolicy(
            messageType: message.messageType, text: message.message, isDeleted: message.isDeleted,
            isOwn: message.sender.uid == model.currentUserID,
            isForwarded: message.forwardedFrom != nil,
            isThreadReply: message.replyRootId != nil, context: interactionContext
        ).availability(of: .edit) == .enabled
    }

    private func startEditing(_ message: MessageResponse) {
        guard !isUpdatingMessage, isEditable(message) else { return }
        drafts.setDraftReply(nil, chatID: chat.id, threadID: threadID)
        editingMessage = message
        editText = message.message ?? ""
        replyFocusRequest &+= 1
    }

    private func cancelEditing() {
        editingMessage = nil
        editText = ""
        isUpdatingMessage = false
    }

    private func requestEditLastOwnMessage() -> Bool {
        for row in model.rows.reversed() {
            guard case .message(let timelineRow) = row,
                let message = timelineRow.entry.remoteMessage,
                message.sender.uid == model.currentUserID, isEditable(message)
            else { continue }
            startEditing(message)
            return true
        }
        return false
    }

    private func changePending(_ pending: PendingOutgoingMessage, revoke: Bool) {
        guard !pending.dispatchClaimed,
            revoke
                || ([.text, .file].contains(pending.messageType) && pending.forwardRequest == nil),
            !drafts.committingDrafts.contains(conversationKey), editingMessage == nil
        else { return }
        Task {
            do {
                try await drafts.flushForAttachmentChange(chatID: chat.id, threadID: threadID)
                if revoke {
                    try await outgoingQueue.revokeTail(
                        chatID: chat.id, threadID: threadID, itemID: pending.clientGeneratedID,
                        expectedRevision: pending.editRevision)
                } else {
                    try await outgoingQueue.blockTail(
                        chatID: chat.id, threadID: threadID, itemID: pending.clientGeneratedID,
                        expectedRevision: pending.editRevision)
                    replyFocusRequest &+= 1
                }
            } catch { outboxError = error.localizedDescription }
        }
    }

    private func retry(_ scope: OutgoingRetryScope) {
        guard let id = failedMessageID else { return }
        failedMessageID = nil
        Task {
            do {
                try await outgoingQueue.retry(
                    chatID: chat.id, threadID: threadID, clientGeneratedID: id, scope: scope)
            } catch { outboxError = error.localizedDescription }
        }
    }

    private func openSystemMessage(_ messageID: MessageID) {
        systemTargetTask?.cancel()
        let accountID = store.currentUserProfile?.uid
        systemTargetTask = Task {
            do {
                let (message, _) = try await store.resolveMessageLink(
                    chatID: chat.id, messageID: messageID)
                try Task.checkCancellation()
                guard store.currentUserProfile?.uid == accountID, !message.isDeleted else {
                    throw APIError.unexpectedResponse
                }
                keepsTimelineForPushedDetail = true
                systemMessageTarget = message
            } catch {
                guard !Task.isCancelled, store.currentUserProfile?.uid == accountID else { return }
                systemTargetError = AppLanguage.localized(
                    "This message is unavailable or you do not have access.")
            }
        }
    }

    private func changeForwardDestination(_ selection: PendingForwardDraft) {
        forwardRequest = ForwardSelection(
            sources: selection.sources, moveFrom: conversationKey,
            expectedForwardID: selection.id)
    }

    private func pendingForwardPreview(_ selection: PendingForwardDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    changeForwardDestination(selection)
                } label: {
                    Label("Forward", systemImage: "arrowshape.turn.up.right")
                        .font(.headline)
                }
                .accessibilityLabel("Change Destination")
                Spacer()
                Button("Cancel", systemImage: "xmark") {
                    drafts.cancelForward(at: conversationKey, expectedID: selection.id)
                }
                .labelStyle(.iconOnly)
            }
            let countTitle: LocalizedStringKey =
                selection.sources.count == 1
                ? "1 message" : "\(selection.sources.count) messages"
            Text(countTitle)
                .font(.caption).foregroundStyle(.secondary)
            if let first = selection.sources.first {
                MessageSummaryText(first.replyPreview, fontSize: 14, color: .secondary)
                    .lineLimit(2)
            }
            HStack {
                Button("Change Destination") {
                    changeForwardDestination(selection)
                }
                Spacer()
                Button("Send Forward") {
                    Task {
                        do {
                            guard interactionContext.canSend else { return }
                            let sent = try await drafts.submitForward(
                                at: conversationKey, expectedID: selection.id)
                            if sent {
                                model.revealLatestAfterSend()
                                showsForwardStarted = true
                            }
                        } catch {
                            outboxError =
                                (error as? APIError)?.speakingRestriction?
                                .restrictionExplanation ?? error.localizedDescription
                        }
                    }
                }
                .disabled(
                    !interactionContext.canSend || outgoingQueue.storageState != .ready
                        || drafts.committingDrafts.contains(conversationKey))
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}
