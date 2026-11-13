import ChahuaAPI
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ChatDetailView: View {
    let chat: ChatListItem
    let navigationTitle: String?
    let threadID: String?
    private let requestedInitialPosition: TimelineInitialPosition?
    private let onOpenThread: ((MessageResponse) -> Void)?
    private var conversationKey: ConversationKey { .init(chatID: chat.id, threadID: threadID) }
    // Retain the command handle without subscribing to list/presence/read traffic.
    private let store: ChatStore
    @StateObject private var observation: ChatDetailObservation
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
    @State private var serverEditIdentity = UUID()
    @StateObject private var pendingEditor = PendingEditPresentation()
    @StateObject private var pendingEditExitGuard = FormExitGuard()
    @State private var isEnteringEdit = false
    @State private var editEntryTask: Task<Void, Never>?
    private var pendingEditSession: PendingEditSession? {
        get { pendingEditor.session }
        nonmutating set { pendingEditor.session = newValue }
    }
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
    @State private var forwardingRootRevision = 0

    struct ForwardSelection: Identifiable {
        let id = UUID()
        let sources: [MessageResponse]
        var wholeThread = false
        var onPrepared: () -> Void = {}
    }

    struct RecordSelection: Identifiable, Hashable {
        let id: MessageID
        let chatID: String
    }

    struct StickerSelection: Identifiable {
        let id: String
    }

    struct ReactionDetailsSelection: Identifiable {
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
        requestedInitialPosition = initialPosition
        self.store = store
        _observation = StateObject(
            wrappedValue: ChatDetailObservation(
                store: store, chatID: chat.id, threadID: threadID))
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
                fetchUnreadReactions: { scope, after in
                    try await store.unreadReactions(chatID: chat.id, threadID: scope, after: after)
                },
                acknowledgeReactions: { scope, readThrough in
                    try await store.acknowledgeReactions(
                        chatID: chat.id, threadID: scope, readThrough: readThrough)
                }
            ))
    }

    private var latestChat: ChatListItem {
        store.state.chats.first { $0.id == chat.id }
            ?? store.state.archivedChats.first { $0.id == chat.id } ?? chat
    }

    private var latestThread: ThreadListItem? {
        guard let threadID else { return nil }
        let matches: (ThreadListItem) -> Bool = {
            $0.chatId == chat.id && $0.threadRootMessage.id.description == threadID
        }
        return store.state.threads.first(where: matches)
            ?? store.state.archivedThreads.first(where: matches)
    }

    private var openingPosition: TimelineInitialPosition {
        if let requestedInitialPosition { return requestedInitialPosition }
        // Row read fields are deliberately outside the route equality boundary.
        // Resolve automatic positioning at open time, not from a captured list row.
        if threadID != nil {
            guard let thread = latestThread else { return .liveEdge }
            return thread.unreadCount > 0
                ? .unread(after: thread.lastReadMessageId) : .liveEdge
        }
        let current = latestChat
        return current.unreadCount > 0 ? .unread(after: current.lastReadMessageId) : .liveEdge
    }

    private var initialTimelineSurface: some View {
        forwardingSurface
            .navigationTitle(navigationTitle ?? chat.chatDisplayName)
            .onAppear {
                guard observation.isCurrentSession else { return }
                isTimelineVisible = true
                if threadID == nil {
                    let current = latestChat
                    model.updateReadState(
                        unreadCount: current.unreadCount,
                        lastReadMessageID: current.lastReadMessageId)
                }
                store.registerTimeline(model)
                model.setReadTrackingActive(scenePhase == .active)
            }
            .task {
                guard observation.isCurrentSession else { return }
                if keepsTimelineForPushedDetail, model.state.content == .ready {
                    keepsTimelineForPushedDetail = false
                } else {
                    await model.open(position: openingPosition)
                }
            }
            .task(id: threadID) {
                guard observation.isCurrentSession,
                    let threadID, let rootID = MessageID(threadID)
                else { return }
                let revision = forwardingRootRevision
                let root = try? await store.forwardSourceMessage(
                    chatID: chat.id, messageID: rootID)
                guard observation.isCurrentSession, !Task.isCancelled,
                    revision == forwardingRootRevision
                else { return }
                forwardingThreadRoot = root
                synchronizeSpeakingPermissions()
            }
            .task { await loadInteractionPermissions() }
            .onChange(of: observation.permissions) { _, _ in
                synchronizeSpeakingPermissions()
            }
            .onChange(of: observation.threadReplyCount) { _, count in
                forwardingThreadReplyCount = count
                synchronizeSpeakingPermissions()
            }
            .onChange(of: observation.session) { _, _ in
                invalidateForSessionChange()
            }
            .task { await savedMessages.ensure(chatID: chat.id) }
    }

    private var savedAndPermissionSurface: some View {
        initialTimelineSurface
            .modifier(
                ChatDetailAttachmentPresentation(
                    chat: chat, threadID: threadID, store: store, model: model,
                    showsThreadInfo: $showsThreadInfo, infoMessageTarget: $infoMessageTarget,
                    infoProfileUID: $infoProfileUID, infoChatTarget: $infoChatTarget,
                    presentedFile: $presentedFile)
            )
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

    private var mutationFeedbackSurface: some View {
        savedAndPermissionSurface
            .modifier(
                PinPresentation(
                    store: store, currentUserID: model.currentUserID, pins: pins,
                    canManagePins: { canManagePins }, showsPinnedMessages: $showsPinnedMessages,
                    stickerToView: $stickerToView, reactionDetailsMessage: $reactionDetailsMessage,
                    pinToUnpin: $pinToUnpin)
            )
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
            .modifier(
                ChatDetailMutationErrors(
                    systemTargetError: $systemTargetError, editError: $editError,
                    outboxError: $outboxError)
            )
            .formDiscardConfirmation(pendingEditExitGuard)
            .task(id: pendingEditSession?.isValid) {
                if pendingEditSession?.isValid == false, !isUpdatingMessage { cancelEditing() }
            }
    }

    var body: some View {
        ScrollPerformanceTrace.event("Detail.Body")
        return
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
            .onReceive(store.conversationMessages.changes, perform: receiveThreadMetadata)
            .onDisappear {
                editEntryTask?.cancel()
                cancelEditing()
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
                if isCurrentSession {
                    Task { await drafts.flushDraft(chatID: chat.id, threadID: threadID) }
                }
            }
    }

    private func receiveThreadMetadata(_ change: ConversationChange) {
        guard isCurrentSession, let threadID, case .realtime(let event) = change else { return }
        switch event {
        case .threadUpdate(let update)
        where update.chatId == chat.id && update.threadRootId == threadID:
            if forwardingThreadReplyCount != update.replyCount {
                forwardingThreadReplyCount = update.replyCount
            }
            if !interactionContext.hasExistingThread {
                interactionContext.hasExistingThread = true
            }
        case .messageUpdated(let message), .messageDeleted(let message):
            guard message.chatId == chat.id, message.id.description == threadID else { return }
            // The root can live outside the thread's loaded rows. Keep forwarding
            // content/deletion current without observing every thread-list field.
            let root: MessageResponse
            if case .messageDeleted = event {
                root = message.redactedForDeletion()
            } else {
                root = message
            }
            guard forwardingThreadRoot != root else { return }
            forwardingRootRevision &+= 1
            forwardingThreadRoot = root
            synchronizeSpeakingPermissions()
        default:
            break
        }
    }

    private var forwardingSurface: some View {
        conversationDropSurface
            .modifier(
                ChatDetailDeletionPresentation(
                    store: store, currentUserID: model.currentUserID,
                    messageToDelete: $messageToDelete, editingMessage: $editingMessage,
                    deleteError: $deleteError, canDelete: canDeleteMessage,
                    cancelEditing: cancelEditing)
            )
            .modifier(
                ForwardingPresentation(
                    chat: chat, currentUserID: model.currentUserID, store: store,
                    onOpenThread: onOpenThread, loadWholeThread: loadWholeThreadForForwarding,
                    forwardRequest: $forwardRequest, systemMessageTarget: $systemMessageTarget,
                    recordRequest: $recordRequest,
                    onForwardCompleted: { showsForwardStarted = true })
            )
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

    private func selectionToolbar(actions: TimelineBubbleActions) -> some View {
        let canForward = !actions.selectedMessageIDs.isEmpty && !isDeletingSelection
        let canDelete =
            !actions.selectedMessageIDs.isEmpty
            && canDeleteSelection(actions.selectionMessages) && !isDeletingSelection
        return HStack(spacing: 16) {
            Button(role: .destructive) {
                selectionToDelete = actions
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Delete selected messages")
            .foregroundStyle(canDelete ? ChahuaTheme.destructive : Color.secondary)
            .disabled(!canDelete)
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
            .foregroundStyle(ChahuaTheme.accent)
            #if os(macOS)
                .keyboardShortcut(.cancelAction)
            #endif
            Button {
                forwardRequest = ForwardSelection(
                    sources: actions.selectionMessages,
                    onPrepared: { actions.endMessageSelection?() })
            } label: {
                Image(systemName: "arrowshape.turn.up.right")
            }
            .accessibilityLabel("Forward")
            .foregroundStyle(canForward ? ChahuaTheme.accent : Color.secondary)
            .disabled(!canForward)
        }
        .buttonStyle(.plain)
        .padding()
        .modifier(ChatGlassSurface(cornerRadius: 32, isInteractive: true))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private func canDeleteSelection(_ messages: [MessageResponse]) -> Bool {
        let context = currentInteractionContext
        return context.canWrite && !messages.isEmpty && messages.count <= 100
            && messages.allSatisfy { $0.chatId == chat.id }
            && messages.allSatisfy {
                !$0.isDeleted
                    && ($0.sender.uid == model.currentUserID || context.isAdmin)
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
        let loadedRoot =
            model.rows.compactMap { row -> MessageResponse? in
                guard case .message(let row) = row,
                    row.entry.remoteMessage?.id.description == threadID
                else { return nil }
                return row.entry.remoteMessage
            }.first ?? forwardingThreadRoot
        guard
            let count = forwardingThreadReplyCount.map({ $0 + 1 })
                ?? observation.threadReplyCount.map({ $0 + 1 })
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
            guard canUseComposer, editingMessage == nil, !isEnteringEdit,
                outgoingQueue.storageState == .ready,
                !drafts.committingDrafts.contains(conversationKey)
            else { return false }
            return composerAttachments.acceptDrop(providers)
        }
        .overlay {
            if isMediaDropTargeted, canUseComposer, editingMessage == nil,
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
                        ChatDetailPinnedMessageBar(
                            chatID: chat.id, controller: pins, viewport: model.viewport,
                            canManage: canManagePins, showsPinnedMessages: $showsPinnedMessages,
                            onJump: jumpToPinnedMessage, onOpenThread: onOpenThread,
                            onRequestPinChange: requestPinChange)
                    }
                )
                .modifier(
                    ChatComposerOverlay {
                        VStack(spacing: 0) {
                            if interactiveActions.isSelectingMessages {
                                selectionToolbar(actions: interactiveActions)
                            } else {
                                savedStatusFeedback
                                failedCancellationFeedback
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
                                if interactionContext.canWrite,
                                    !canUseComposer,
                                    let mode = interactionContext.speakingMode
                                {
                                    Text(mode.restrictionExplanation)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .padding(.horizontal, 16).padding(.vertical, 8)
                                        .background(
                                            .regularMaterial, in: RoundedRectangle(cornerRadius: 20)
                                        )
                                        .padding(.horizontal, 12)
                                } else {
                                    messageComposer(maxHeight: max(36, geometry.size.height / 3))
                                }
                            }
                        }
                    })
        }
    }

    private func messageComposer(maxHeight: CGFloat) -> MessageComposerView {
        let hasChanges: ((String) -> Bool)?
        let importFiles: (([URL]) async throws -> Void)?
        if let session = pendingEditSession {
            hasChanges = { session.hasChanges(text: $0) }
            importFiles = nil
        } else {
            hasChanges = nil
            importFiles = importComposerFiles
        }
        return MessageComposerView(
            text: composerText,
            attachmentState: composerAttachments,
            maxHeight: maxHeight,
            isEnabled: canUseComposer,
            canSend: canSubmitComposer,
            onSubmit: {
                [
                    sessionID = pendingEditSession?.id,
                    messageID = editingMessage?.id,
                    serverID = serverEditIdentity
                ] text in
                guard pendingEditSession?.id == sessionID,
                    editingMessage?.id == messageID,
                    editingMessage == nil || serverEditIdentity == serverID
                else { return false }
                return await submitComposer(text)
            },
            onCompositionChanged: { composing in
                isComposerComposing = composing
                guard !isEditing else { return }
                drafts.setDraftComposing(composing, chatID: chat.id, threadID: threadID)
            },
            replyToMessage: isEditing
                ? nil : drafts.draftReply(chatID: chat.id, threadID: threadID),
            replyFocusRequest: replyFocusRequest,
            onCancelReply: {
                drafts.setDraftReply(nil, chatID: chat.id, threadID: threadID)
            },
            onOpenReply: { id in Task { await model.jumpToMessage(id) } },
            isEditing: isEditing,
            initialEditText: pendingEditSession?.initialText ?? editingMessage?.message ?? "",
            hasEditChanges: hasChanges,
            editIdentity: pendingEditSession?.id.uuidString
                ?? editingMessage.map { _ in serverEditIdentity.uuidString },
            editMentionNames: MessageMentions.names(in: editingMessage?.mentions ?? []),
            allowsEditingMedia: pendingEditSession != nil,
            editExitGuard: pendingEditSession == nil ? nil : pendingEditExitGuard,
            onCancelEdit: cancelEditing,
            onEscapeEdit: requestEditingExit,
            onRequestEditLastMessage: requestEditLastOwnMessage,
            attachments: composerMedia,
            attachmentProgress: outgoingQueue.attachmentProgress,
            compressionEnabled: outgoingQueue.compressionEnabled(
                chatID: chat.id, threadID: threadID),
            onImportImages: { [session = pendingEditSession] urls in
                try await importComposerImages(urls, session: session)
            },
            onImportFiles: importFiles,
            onRemoveAttachment: { [session = pendingEditSession] id in
                try await removeComposerAttachment(id, session: session)
            },
            onRetryAttachment: { [session = pendingEditSession] id in
                try await retryComposerAttachment(id, session: session)
            },
            onCompressionChanged: { enabled in
                guard canUseComposer, !isEditing else { throw APIError.unavailable }
                try await drafts.flushForAttachmentChange(chatID: chat.id, threadID: threadID)
                guard canUseComposer, !isEditing else { throw CancellationError() }
                try await outgoingQueue.setCompressionEnabled(
                    enabled, chatID: chat.id, threadID: threadID)
            },
            onReorderAttachments: { [session = pendingEditSession] ids in
                try await reorderComposerAttachments(ids, session: session)
            },
            onDiscardAttachments: { [session = pendingEditSession] in
                if session == nil {
                    guard canUseComposer, !isEditing else { throw APIError.unavailable }
                    try await drafts.discardAttachments(chatID: chat.id, threadID: threadID)
                }
            },
            stickerLibrary: store.stickers,
            onSendSticker: sendSticker,
            onSendVoice: sendVoice,
            onSearchMembers: { query in
                try await store.searchMembers(chatID: chat.id, query: query)
            }
        )
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
        guard isCurrentSession else { return }
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
            guard let permissions, revision == permissionRequestRevision,
                isCurrentSession, !Task.isCancelled
            else { return }
            interactionContext = permissions
            interactionContext.isThreadView = threadID != nil
            hasLoadedInteractionPermissions = true
            synchronizeSpeakingPermissions()
        } catch {
            guard revision == permissionRequestRevision, isCurrentSession, !Task.isCancelled else {
                return
            }
            reactions.error = AppLanguage.localized(
                "Couldn’t load message permissions. Please try again.")
        }
    }

    private func synchronizeSpeakingPermissions() {
        interactionContext.hasExistingThread =
            interactionContext.hasExistingThread
            || forwardingThreadRoot?.threadInfo != nil
            || observation.threadReplyCount != nil
            || forwardingThreadReplyCount != nil
        guard chat.kind != .dm else { return }
        interactionContext.canWrite =
            observation.isCurrentSession && observation.permissions.role != nil
        interactionContext.isAdmin = observation.permissions.role == .admin
        interactionContext.speakingMode = observation.permissions.speakingMode
    }

    private func invalidateInteractionPermissions() {
        // Fence stale responses and open action snapshots before the async reload.
        permissionRequestRevision &+= 1
        interactionContext.canWrite = false
        hasLoadedInteractionPermissions = false
        selectionDeleteTask?.cancel()
        Task { await loadInteractionPermissions() }
    }

    private var isCurrentSession: Bool {
        observation.isCurrentSession
            && observation.session.accountID == store.currentUserProfile?.uid
            && observation.session.revision == store.sessionRevision
    }

    private var currentInteractionContext: MessageInteractionContext {
        // Action closures can outlive a rendered menu/composer. Recheck the live
        // store at invocation, rather than authorizing against that UI snapshot.
        var context = interactionContext
        guard isCurrentSession else {
            context.canWrite = false
            return context
        }
        if chat.kind != .dm {
            let info = store.groupInfoByChatID[chat.id]
            context.canWrite = hasLoadedInteractionPermissions && info?.myRole != nil
            context.isAdmin = info?.myRole == .admin
            context.speakingMode = info?.effectiveSpeakingMode
        }
        return context
    }

    private func invalidateForSessionChange() {
        editEntryTask?.cancel()
        permissionRequestRevision &+= 1
        interactionContext.canWrite = false
        hasLoadedInteractionPermissions = false
        selectionDeleteTask?.cancel()
        systemTargetTask?.cancel()
        forwardingThreadRoot = nil
        forwardingThreadReplyCount = nil
        cancelEditing()
        forwardRequest = nil
        messageToDelete = nil
        pinToUnpin = nil
        recordRequest = nil
        systemMessageTarget = nil
        showsThreadInfo = false
        showsPinnedMessages = false
        infoMessageTarget = nil
        infoProfileUID = nil
        infoChatTarget = nil
        presentedFile = nil
        stickerToView = nil
        reactionDetailsMessage = nil
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
        // Split the lookup operands to avoid a Swift 6.4 constraint-solver crash.
        let pinChatID: String = chat.id
        let pinsByChatID: [String: [PinResponse]] = pins.pinsByChatID
        let loadedPins: [PinResponse]? = pinsByChatID[pinChatID]
        if canManagePins,
            loadedPins != nil, !pins.failedChatIDs.contains(chat.id)
        {
            actions.togglePin = requestPinChange
        }
        // Eligibility follows identity and write access, never FIFO position or claim state.
        if currentInteractionContext.canWrite {
            let pending = outgoingQueue.pendingMessages(chatID: chat.id, threadID: threadID)
            actions.cancellablePendingMessageIDs = Set(pending.map(\.clientGeneratedID))
            if currentInteractionContext.canSend {
                actions.editablePendingMessageIDs = Set(
                    pending.filter { $0.messageType == .text && $0.forwardRequest == nil }
                        .map(\.clientGeneratedID))
            }
        }
        actions.editPendingMessage = startPendingEditing
        actions.cancelPendingMessage = cancelPendingMessage
        actions.openLink = { url in
            if let code = GroupInviteLink.code(from: url.absoluteString) {
                openGroupInvite(code)
            } else {
                openURL(url)
            }
        }
        if threadID == nil, onOpenThread != nil {
            actions.openThread = { id in
                guard isCurrentSession else { return }
                for case .message(let row) in model.rows {
                    guard let message = row.entry.remoteMessage,
                        message.id == id, !message.isDeleted
                    else { continue }
                    guard message.threadInfo != nil || currentInteractionContext.canCreateThread
                    else {
                        return
                    }
                    onOpenThread?(message)
                    return
                }
            }
        }
        if interactionContext.canSend {
            actions.replyToMessage = { message in
                guard currentInteractionContext.canSend,
                    !drafts.committingDrafts.contains(conversationKey)
                else { return }
                drafts.setDraftReply(message.replyPreview, chatID: chat.id, threadID: threadID)
                replyFocusRequest &+= 1
            }
        }
        actions.editMessage = startEditing
        if interactionContext.canWrite {
            actions.deleteMessage = { message in
                guard canDeleteMessage(message) else { return }
                messageToDelete = message
            }
            actions.toggleReaction = { row, emoji in
                guard let message = row.entry.remoteMessage, !message.isDeleted else { return }
                Task {
                    guard currentInteractionContext.canWrite else { return }
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

    private func canDeleteMessage(_ message: MessageResponse) -> Bool {
        let context = currentInteractionContext
        return context.canWrite && !store.deletingMessageIDs.contains(message.id)
            && MessageActionPolicy(
                messageType: message.messageType, isDeleted: message.isDeleted,
                isOwn: message.sender.uid == model.currentUserID, context: context
            ).availability(of: .delete) == .enabled
    }

    private var chatPins: [PinResponse] {
        let chatID = chat.id
        let pinsByChatID = pins.pinsByChatID
        return pinsByChatID[chatID] ?? []
    }

    private var canManagePins: Bool {
        let context = currentInteractionContext
        return threadID == nil && context.canWrite && (context.isDM || context.isAdmin)
    }

    private var showsPinBar: Bool {
        threadID == nil && (!chatPins.isEmpty || pins.failedChatIDs.contains(chat.id))
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

    private var isEditing: Bool { editingMessage != nil || pendingEditSession != nil }

    private var canUseComposer: Bool {
        guard isCurrentSession else { return false }
        if let session = pendingEditSession {
            return session.isValid && currentInteractionContext.canSend
        }
        return editingMessage.map(isEditable) ?? currentInteractionContext.canSend
    }

    private var composerMedia: [ComposerMediaItem] {
        if let session = pendingEditSession {
            return session.attachments.map(ComposerMediaItem.init)
        }
        guard editingMessage == nil else { return [] }
        return outgoingQueue.draftAttachments(chatID: chat.id, threadID: threadID)
            .map(ComposerMediaItem.local)
    }

    @ViewBuilder private var failedCancellationFeedback: some View {
        let ids = outgoingQueue.failedCancellationIDs(chatID: chat.id, threadID: threadID)
        ForEach(ids, id: \.self) { id in
            HStack {
                Text("Couldn’t recall message").font(.caption)
                Spacer(minLength: 8)
                Button("Retry") {
                    guard isCurrentSession, currentInteractionContext.canWrite else { return }
                    Task {
                        do {
                            guard isCurrentSession, currentInteractionContext.canWrite else {
                                return
                            }
                            try await outgoingQueue.retry(
                                chatID: chat.id, threadID: threadID, clientGeneratedID: id,
                                scope: .message)
                        } catch {
                            if isCurrentSession { outboxError = error.localizedDescription }
                        }
                    }
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 12)
        }
        if let session = pendingEditSession {
            if let error = session.error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }
            if session.isUploading {
                ProgressView("Updating attachments…").controlSize(.small).padding(8)
            }
        }
    }

    private func prepareComposerForEditing(discardAttachments: Bool) async throws {
        guard isCurrentSession, let prepare = composerAttachments.prepareForEditing else {
            throw APIError.unavailable
        }
        try await prepare()
        try Task.checkCancellation()
        guard isCurrentSession else { throw CancellationError() }
        composerAttachments.isAcquiring = true
        defer { composerAttachments.isAcquiring = false }
        if !isEditing {
            try await drafts.flushForAttachmentChange(chatID: chat.id, threadID: threadID)
            try Task.checkCancellation()
            guard isCurrentSession else { throw CancellationError() }
        }
        if discardAttachments {
            try await outgoingQueue.discardDraftAttachments(chatID: chat.id, threadID: threadID)
        }
    }

    private func requestEditingExit(_ text: String) {
        let sessionID = pendingEditSession?.id
        let serverID = serverEditIdentity
        // Key handling can run inside SwiftUI's view update. Publish editor/lease
        // changes on the next main-actor turn, fenced to the original editor.
        Task { @MainActor in
            guard isCurrentSession, pendingEditSession?.id == sessionID,
                serverEditIdentity == serverID
            else { return }
            performEditingExit(text)
        }
    }

    private func performEditingExit(_ text: String) {
        guard !isUpdatingMessage else { return }
        guard let session = pendingEditSession else {
            if text == editingMessage?.message { cancelEditing() }
            return
        }
        pendingEditExitGuard.update(
            owner: session.id, isDirty: session.hasChanges(text: text),
            isSubmitting: isUpdatingMessage || composerAttachments.isAcquiring,
            accountID: observation.session.accountID, sessionRevision: observation.session.revision)
        pendingEditExitGuard.requestExit {
            guard isCurrentSession, pendingEditSession?.id == session.id,
                !isUpdatingMessage, !composerAttachments.isAcquiring
            else { return }
            cancelEditing()
        }
    }

    private func importComposerImages(_ urls: [URL], session: PendingEditSession?) async throws {
        guard canUseComposer, pendingEditSession?.id == session?.id else {
            throw APIError.unavailable
        }
        if let session {
            try await outgoingQueue.importEditImages(urls: urls, session: session)
        } else {
            guard !isEditing else { throw APIError.unavailable }
            try await drafts.flushForAttachmentChange(chatID: chat.id, threadID: threadID)
            guard canUseComposer, !isEditing else { throw CancellationError() }
            try await outgoingQueue.importImages(urls: urls, chatID: chat.id, threadID: threadID)
        }
    }

    private func importComposerFiles(_ urls: [URL]) async throws {
        guard canUseComposer, !isEditing else { throw APIError.unavailable }
        try await drafts.flushForAttachmentChange(chatID: chat.id, threadID: threadID)
        guard canUseComposer, !isEditing else { throw CancellationError() }
        try await outgoingQueue.importFiles(urls: urls, chatID: chat.id, threadID: threadID)
    }

    private func removeComposerAttachment(_ id: String, session: PendingEditSession?) async throws {
        guard canUseComposer, pendingEditSession?.id == session?.id else {
            throw APIError.unavailable
        }
        if let session {
            outgoingQueue.removeEditAttachment(id: id, session: session)
        } else {
            guard !isEditing else { throw APIError.unavailable }
            try await drafts.flushForAttachmentChange(chatID: chat.id, threadID: threadID)
            guard canUseComposer, !isEditing else { throw CancellationError() }
            try await outgoingQueue.removeAttachment(id: id, chatID: chat.id, threadID: threadID)
        }
    }

    private func retryComposerAttachment(_ id: String, session: PendingEditSession?) async throws {
        guard canUseComposer, pendingEditSession?.id == session?.id else {
            throw APIError.unavailable
        }
        if let session {
            outgoingQueue.retryEditAttachment(id: id, session: session)
        } else {
            guard !isEditing else { throw APIError.unavailable }
            try await drafts.flushForAttachmentChange(chatID: chat.id, threadID: threadID)
            guard canUseComposer, !isEditing else { throw CancellationError() }
            try await outgoingQueue.retryAttachment(id: id, chatID: chat.id, threadID: threadID)
        }
    }

    private func reorderComposerAttachments(_ ids: [String], session: PendingEditSession?)
        async throws
    {
        guard canUseComposer, pendingEditSession?.id == session?.id else {
            throw APIError.unavailable
        }
        if let session {
            try outgoingQueue.reorderEditAttachments(ids: ids, session: session)
        } else {
            guard !isEditing else { throw APIError.unavailable }
            try await drafts.flushForAttachmentChange(chatID: chat.id, threadID: threadID)
            guard canUseComposer, !isEditing else { throw CancellationError() }
            try await outgoingQueue.reorderAttachments(
                ids: ids, chatID: chat.id, threadID: threadID)
        }
    }

    private var composerText: Binding<String> {
        Binding(
            get: {
                !isEditing
                    ? drafts.draftText(chatID: chat.id, threadID: threadID) : editText
            },
            set: {
                if !isEditing {
                    drafts.setDraftText($0, chatID: chat.id, threadID: threadID)
                } else {
                    editText = $0
                }
            }
        )
    }

    private var canSubmitComposer: Bool {
        let text =
            (!isEditing
            ? drafts.draftText(chatID: chat.id, threadID: threadID) : editText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard canUseComposer, !isEnteringEdit else { return false }
        if let session = pendingEditSession {
            return !isUpdatingMessage && session.isValid
        }
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
        guard currentInteractionContext.canSend, !isEditing, !isEnteringEdit,
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
        guard currentInteractionContext.canSend, !isEditing, !isEnteringEdit,
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
        guard canUseComposer, !isEnteringEdit else { return false }
        if let session = pendingEditSession {
            guard session.isValid, !isUpdatingMessage,
                session.hasChanges(text: text),
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !session.attachments.isEmpty
            else { return false }
            isUpdatingMessage = true
            defer { isUpdatingMessage = false }
            do {
                try await outgoingQueue.submitPendingEdit(session, text: text)
                guard isCurrentSession, pendingEditSession?.id == session.id else { return false }
                cancelEditing()
                return true
            } catch {
                guard isCurrentSession, pendingEditSession?.id == session.id else { return false }
                if !session.isValid {
                    cancelEditing()
                } else {
                    editError = error.localizedDescription
                }
                return false
            }
        }
        guard let message = editingMessage else {
            let sent = await drafts.submitDraft(chatID: chat.id, threadID: threadID, text: text)
            if sent { model.revealLatestAfterSend() }
            if !sent, let error = drafts.submissionError { outboxError = error }
            return sent
        }
        guard !isUpdatingMessage else { return false }
        isUpdatingMessage = true
        let submittedText = text
        let submittedEditIdentity = serverEditIdentity
        let didUpdate = await store.updateMessage(message, text: submittedText)
        guard isCurrentSession, !Task.isCancelled else { return false }
        guard editingMessage?.id == message.id, pendingEditSession == nil,
            submittedEditIdentity == serverEditIdentity
        else { return didUpdate }
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
            isThreadReply: message.replyRootId != nil, context: currentInteractionContext
        ).availability(of: .edit) == .enabled
    }

    private func startEditing(_ message: MessageResponse) {
        guard !isUpdatingMessage, !isEnteringEdit, isEditable(message) else { return }
        isEnteringEdit = true
        editEntryTask = Task {
            defer { isEnteringEdit = false }
            do {
                try await prepareComposerForEditing(discardAttachments: false)
                guard isCurrentSession, isTimelineVisible, isEditable(message), !Task.isCancelled
                else { return }
                cancelEditing()
                editingMessage = message
                editText = message.message ?? ""
                replyFocusRequest &+= 1
            } catch { editError = error.localizedDescription }
        }
    }

    private func cancelEditing() {
        serverEditIdentity = UUID()
        composerAttachments.cancelEditingWork?()
        if let session = pendingEditSession { outgoingQueue.endPendingEdit(session) }
        pendingEditSession = nil
        pendingEditExitGuard.invalidate()
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

    private func startPendingEditing(_ pending: PendingOutgoingMessage) {
        guard isCurrentSession, currentInteractionContext.canSend,
            pending.chatID == chat.id, pending.threadID == threadID,
            pending.messageType == .text, pending.forwardRequest == nil,
            pending.senderID == model.currentUserID,
            !isUpdatingMessage, !isEnteringEdit
        else { return }
        isEnteringEdit = true
        editEntryTask = Task {
            var acquiredSession: PendingEditSession?
            defer {
                isEnteringEdit = false
                if let acquiredSession, pendingEditSession?.id != acquiredSession.id {
                    outgoingQueue.endPendingEdit(acquiredSession)
                }
            }
            do {
                let session = try await outgoingQueue.beginPendingEdit(pending)
                acquiredSession = session
                guard isCurrentSession, session.isValid, currentInteractionContext.canSend,
                    !Task.isCancelled
                else { return }
                try await prepareComposerForEditing(discardAttachments: true)
                guard isCurrentSession, isTimelineVisible, currentInteractionContext.canSend,
                    session.isValid, !Task.isCancelled
                else { return }
                cancelEditing()
                pendingEditSession = session
                editText = session.initialText
                replyFocusRequest &+= 1
            } catch {
                if isCurrentSession { editError = error.localizedDescription }
            }
        }
    }

    private func cancelPendingMessage(_ pending: PendingOutgoingMessage) {
        guard isCurrentSession, currentInteractionContext.canWrite,
            pending.chatID == chat.id, pending.threadID == threadID,
            pending.senderID == model.currentUserID
        else { return }
        Task {
            do {
                guard isCurrentSession, currentInteractionContext.canWrite else { return }
                try await outgoingQueue.cancelOutgoing(
                    chatID: chat.id, threadID: threadID, itemID: pending.clientGeneratedID,
                    expectedRevision: pending.editRevision)
                if pendingEditSession?.clientGeneratedID == pending.clientGeneratedID {
                    cancelEditing()
                }
            } catch {
                if isCurrentSession { outboxError = error.localizedDescription }
            }
        }
    }

    private func retry(_ scope: OutgoingRetryScope) {
        guard isCurrentSession, let id = failedMessageID else { return }
        failedMessageID = nil
        Task {
            do {
                try await outgoingQueue.retry(
                    chatID: chat.id, threadID: threadID, clientGeneratedID: id, scope: scope)
            } catch { outboxError = error.localizedDescription }
        }
    }

    private func openSystemMessage(_ messageID: MessageID) {
        guard isCurrentSession else { return }
        systemTargetTask?.cancel()
        let accountID = store.currentUserProfile?.uid
        systemTargetTask = Task {
            do {
                let (message, _) = try await store.resolveMessageLink(
                    chatID: chat.id, messageID: messageID)
                try Task.checkCancellation()
                guard isCurrentSession, store.currentUserProfile?.uid == accountID,
                    !message.isDeleted
                else {
                    throw APIError.unexpectedResponse
                }
                keepsTimelineForPushedDetail = true
                systemMessageTarget = message
            } catch {
                guard isCurrentSession, !Task.isCancelled,
                    store.currentUserProfile?.uid == accountID
                else { return }
                systemTargetError = AppLanguage.localized(
                    "This message is unavailable or you do not have access.")
            }
        }
    }

}

/// SwiftUI must observe in-memory media checkpoints as well as durable queue snapshots.
@MainActor
private final class PendingEditPresentation: ObservableObject {
    @Published var session: PendingEditSession? {
        didSet {
            changes = session?.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }
    private var changes: AnyCancellable?
}
