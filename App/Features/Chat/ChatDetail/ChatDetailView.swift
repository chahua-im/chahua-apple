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
    @State private var outboxAction: OutboxAction?
    @State private var isTimelineVisible = false
    @ObservedObject private var voiceSession = VoicePlaybackSession.shared
    @StateObject private var voiceVisibility = VoiceTimelineVisibility()
    @State private var hasDescendantVoiceCover = false
    @Environment(\.voicePlaybackHeaderRoute) private var voiceHeaderRoute
    @Environment(\.isVoicePlaybackHeaderCovered) private var isVoiceHeaderCovered
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.openUserProfile) private var openUserProfile
    @Environment(\.openGroupInvite) private var openGroupInvite
    @Environment(\.imageDetailPresenter) private var imageDetailPresenter
    @State private var replyFocusRequest = 0
    @State private var editingMessage: MessageResponse?
    @State private var serverEditIdentity = UUID()
    @StateObject private var pendingEditor = PendingEditPresentation()
    @StateObject private var localEditExitGuard = FormExitGuard()
    @Environment(\.messageEditExitCoordinator) private var editExitCoordinator
    @Environment(\.dismiss) private var dismiss
    private var editExitGuard: FormExitGuard {
        editExitCoordinator?.exitGuard ?? localEditExitGuard
    }
    @State private var isEnteringEdit = false
    @State private var editEntryTask: Task<Void, Never>?
    @State private var enteringPendingEdit: PendingEditSession?
    private var pendingEditSession: PendingEditSession? {
        get { pendingEditor.session }
        nonmutating set { pendingEditor.session = newValue }
    }
    @State private var editText = ""
    @State private var editLinkPreviews: [LinkPreviewInput] = []
    @State private var initialEditLinkPreviews: [LinkPreviewInput] = []
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
    @State private var hasVerifiedThreadRoot = false
    @State private var forwardingThreadReplyCount: Int64?
    @State private var forwardingRootRevision = 0
    @State private var threadRootRequestRevision = 0

    private struct ThreadRootRequest: Equatable {
        let threadID: String?
        let canFetchHistory: Bool
        let revision: Int
    }

    private enum OutboxAction {
        case failure(String)
        case remove(String)

        var id: String {
            switch self {
            case .failure(let id), .remove(let id): id
            }
        }
    }

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
                historyCache: store.historyCache,
                canFetchHistory: { [weak store] in store?.canFetchHistory == true },
                canRetryHistory: { [weak store] in store?.canRetryHistory() == true },
                markRead: { messageID in
                    try await store.recordAutomaticRead(
                        .init(chatID: chat.id, threadID: threadID), target: messageID)
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
            .task(id: ThreadRootRequest(
                threadID: threadID, canFetchHistory: observation.canFetchHistory,
                revision: threadRootRequestRevision
            )) {
                hasVerifiedThreadRoot = false
                guard isCurrentSession, store.canFetchHistory,
                    let threadID, let rootID = MessageID(threadID)
                else { return }
                let revision = forwardingRootRevision
                let root = try? await store.forwardSourceMessage(
                    chatID: chat.id, messageID: rootID)
                guard isCurrentSession, store.canFetchHistory, !Task.isCancelled,
                    revision == forwardingRootRevision, let root,
                    root.id == rootID, root.chatId == chat.id, root.replyRootId == nil
                else { return }
                forwardingThreadRoot = root
                hasVerifiedThreadRoot = true
                persistResolvedSendDecision()
            }
            .task(id: observation.canFetchHistory) { await loadInteractionPermissions() }
            .task(id: outgoingQueue.storageState) {
                guard isCurrentSession else { return }
                _ = await store.savedSendDecision(for: conversationKey)
            }
            .onChange(of: observation.permissions) { _, _ in
                persistResolvedSendDecision()
            }
            .onChange(of: observation.threadReplyCount) { _, count in
                forwardingThreadReplyCount = count
            }
            .onChange(of: observation.session) { _, _ in
                invalidateForSessionChange()
            }
            .task(id: observation.canFetchHistory) {
                guard store.canFetchHistory else { return }
                await savedMessages.ensure(chatID: chat.id)
            }
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
                        guard store.canFetchHistory else { return }
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
            .task(id: observation.canFetchHistory) {
                if threadID == nil, store.canFetchHistory {
                    await pins.load(chatID: chat.id, force: true)
                }
            }
    }

    private var mutationFeedbackSurface: some View {
        savedAndPermissionSurface
            .modifier(
                PinPresentation(
                    store: store, currentUserID: model.currentUserID, pins: pins,
                    canManagePins: { canManagePins }, showsPinnedMessages: $showsPinnedMessages,
                    stickerToView: $stickerToView, reactionDetailsMessage: $reactionDetailsMessage,
                    pinToUnpin: $pinToUnpin, chatID: chat.id, onJumpToPin: jumpToPinnedMessage,
                    onOpenThread: onOpenThread)
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
                outboxActionTitle,
                isPresented: Binding(
                    get: { outboxAction != nil },
                    set: { if !$0 { outboxAction = nil } }),
                titleVisibility: .visible, presenting: outboxActionTarget
            ) { target in
                if target.phase.isFailed {
                    Button("Retry") { retryOutgoing(target.id) }
                }
                Button("Remove from Outbox", role: .destructive) { removeOutgoing(target) }
                Button("Cancel", role: .cancel) {}
            } message: { target in
                Text(target.detail)
            }
            .modifier(
                ChatDetailMutationErrors(
                    systemTargetError: $systemTargetError, editError: $editError,
                    outboxError: $outboxError)
            )
            .formDiscardConfirmation(editExitGuard)
            #if os(iOS)
                // iOS has native Back/swipe to intercept; macOS uses the shell's
                // guarded floating header and must not gain a second Back toolbar.
                .formBackProtection(editExitGuard) {
                    cancelEditing()
                    dismiss()
                }
            #endif
            .onChange(
                of: hasEditChanges(editText) || (isEditing && isComposerComposing), initial: true
            ) { _, _ in
                refreshEditExitGuard()
            }
            .onChange(of: isUpdatingMessage) { _, _ in refreshEditExitGuard() }
            .onChange(of: composerAttachments.isAcquiring) { _, _ in refreshEditExitGuard() }
            .task(id: pendingEditSession?.isValid) {
                if pendingEditSession?.isValid == false, !isUpdatingMessage { cancelEditing() }
            }
    }

    var body: some View {
        ScrollPerformanceTrace.event("Detail.Body")
        return
            mutationFeedbackSurface
            .onReceive(store.outgoingQueue.events) { _ in
                if outboxActionTarget == nil { outboxAction = nil }
            }
            .onReceive(store.conversationMessages.changes, perform: receiveThreadMetadata)
            .onDisappear {
                cancelEditEntry()
                if pendingEditSession != nil || editExitCoordinator == nil { cancelEditing() }
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
            if store.canFetchHistory, forwardingThreadRoot?.threadInfo == nil {
                // The count signals a change, but only the root's threadInfo is
                // proof for a replies-only destination.
                hasVerifiedThreadRoot = false
                threadRootRequestRevision &+= 1
            }
        case .messageUpdated(let message), .messageDeleted(let message):
            guard message.chatId == chat.id, message.id.description == threadID,
                message.replyRootId == nil
            else { return }
            // The root can live outside the thread's loaded rows. Keep forwarding
            // content/deletion current without observing every thread-list field.
            let root: MessageResponse
            if case .messageDeleted = event {
                root = message.redactedForDeletion()
            } else {
                root = message
            }
            guard forwardingThreadRoot != root || !hasVerifiedThreadRoot else { return }
            forwardingRootRevision &+= 1
            forwardingThreadRoot = root
            hasVerifiedThreadRoot = true
            persistResolvedSendDecision()
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
                guard isCurrentSession, store.historyCache?.accessRevoked(chat.id) != true else {
                    return
                }
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
        .modifier(ChatGlassSurface(shape: Capsule(style: .circular), isInteractive: true))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private func canDeleteSelection(_ messages: [MessageResponse]) -> Bool {
        let context = currentInteractionContext
        return context.canUseNetworkActions && context.canWrite && !messages.isEmpty
            && messages.count <= 100
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
                        guard store.canFetchHistory else { return }
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

    private var wholeThreadForwardSeed: MessageResponse? {
        guard isCurrentSession, store.historyCache?.accessRevoked(chat.id) != true,
            let threadID, let rootID = MessageID(threadID),
            !model.knownDeletedMessageIDs.contains(rootID), forwardingThreadRoot?.isDeleted != true
        else { return nil }
        var reply: MessageResponse?
        for case .message(let row) in model.rows {
            guard let message = row.entry.remoteMessage, !message.isDeleted,
                message.messageType != .system, message.messageType != .invite
            else { continue }
            if message.id == rootID { return message }
            if reply == nil, message.replyRootId == threadID { reply = message }
        }
        if let root = forwardingThreadRoot, root.messageType != .system, root.messageType != .invite {
            return root
        }
        // A reply can seed the picker when the root isn't in this saved window.
        // The actual selection is loaded from verified, complete coverage.
        return store.canFetchHistory ? nil : reply
    }

    private var wholeThreadForwardAction: ForwardThreadAction? {
        guard let seed = wholeThreadForwardSeed else { return nil }
        let replies = forwardingThreadReplyCount ?? observation.threadReplyCount
            ?? seed.threadInfo?.replyCount ?? 0
        guard replies < 100 else { return nil }
        let count = replies + 1
        return ForwardThreadAction(conversation: conversationKey, count: count) {
            guard let seed = wholeThreadForwardSeed else { return }
            forwardRequest = ForwardSelection(sources: [seed], wholeThread: true)
        }
    }

    private func loadWholeThreadForForwarding() async throws -> [MessageResponse] {
        guard isCurrentSession, let threadID, let rootID = MessageID(threadID) else {
            throw ForwardDestinationPicker.SourceError.unavailable
        }
        if !store.canFetchHistory {
            return try await store.savedCompleteThread(chatID: chat.id, rootID: rootID, limit: 100)
                .filter { !$0.isDeleted && $0.messageType != .system }
        }
        let page = try await store.fetchMessages(
            chatID: chat.id, query: .init(max: 100, threadID: threadID)
        ).response
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
                        model: model, context: currentInteractionContext, actions: selectedActions
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

    private var voiceTimelineTarget: VoiceTimelineTarget? {
        guard isTimelineVisible, scenePhase == .active, !isVoiceHeaderCovered, !hasVoiceCover,
            let controller = voiceSession.controller, let identity = controller.identity,
            identity.chatID == chat.id
        else { return nil }
        return VoiceTimelineTarget(
            identity: identity, controllerID: ObjectIdentifier(controller),
            visibility: voiceVisibility)
    }

    private var hasVoiceCover: Bool {
        #if os(iOS)
            if horizontalSizeClass == .compact && showsPinnedMessages { return true }
        #endif
        return hasDescendantVoiceCover || showsThreadInfo || presentedFile != nil
            || forwardRequest != nil || stickerToView != nil
    }

    private func conversationBody(actions interactiveActions: TimelineBubbleActions) -> some View {
        let playback =
            voiceHeaderRoute != nil && !isVoiceHeaderCovered && !hasVoiceCover
                && isTimelineVisible ? voiceSession.controller : nil
        let needsPlayback = playback != nil && voiceVisibility.visible != playback?.identity
        let slot = ChatSecondaryHeaderKind.select(
            needsPlayback: needsPlayback, hasPins: showsPinBar)
        return GeometryReader { geometry in
            timelineSurface(actions: interactiveActions)
                .environment(\.voiceTimelineTarget, voiceTimelineTarget)
                .modifier(
                    ChatSecondaryHeaderOverlay(
                        kind: slot, pinsEligible: showsPinBar, playbackEligible: playback != nil
                    ) {
                        ChatDetailPinnedMessageBar(
                            chatID: chat.id, controller: pins, viewport: model.viewport,
                            canManage: canManagePins, showsPinnedMessages: $showsPinnedMessages,
                            onJump: jumpToPinnedMessage, onOpenThread: onOpenThread,
                            onRequestPinChange: requestPinChange)
                    } playback: {
                        if let playback { VoicePlaybackBar(controller: playback) }
                    }
                )
                .modifier(
                    ChatComposerOverlay {
                        VStack(spacing: 0) {
                            if interactiveActions.isSelectingMessages {
                                selectionToolbar(actions: interactiveActions)
                            } else {
                                savedStatusFeedback
                                pendingEditorFeedback
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
                                let context = currentInteractionContext
                                if context.canUseNetworkActions, context.canWrite, !canUseComposer,
                                    let mode = context.speakingMode
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
                                    if !context.canUseNetworkActions, !context.canSend, !isEditing,
                                        outgoingQueue.storageState == .ready
                                    {
                                        Text(context.savedSendDecision == false
                                            ? AppLanguage.localized("Sending is not allowed in this conversation.")
                                            : AppLanguage.localized("Connect to check whether you can send."))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 12)
                                    }
                                    messageComposer(maxHeight: max(36, geometry.size.height / 3))
                                }
                            }
                        }
                    })
        }
        .onPreferenceChange(VoicePlaybackCoverPreference.self) { hasDescendantVoiceCover = $0 }
    }

    private func messageComposer(maxHeight: CGFloat) -> MessageComposerView {
        let session = pendingEditSession
        let owner = composerEditOwner
        let allowsCaption = session?.attachments.contains(where: \.isFile) != true
        var composer = MessageComposerView(
            text: composerText, attachmentState: composerAttachments, maxHeight: maxHeight,
            isEnabled: canUseComposer && !(session != nil && isUpdatingMessage),
            canSend: canSubmitComposer,
            onSubmit: { text in
                guard isCurrentSession, composerEditOwner == owner else { return false }
                return await submitComposer(text)
            })

        composer.onCompositionChanged = { composing in
            guard isCurrentSession, composerEditOwner == owner else { return }
            isComposerComposing = composing
            guard !isEditing else { return }
            drafts.setDraftComposing(composing, chatID: chat.id, threadID: threadID)
        }
        let reply =
            isEditing
            ? session?.replyToMessage
            : drafts.draftReply(chatID: chat.id, threadID: threadID)
        composer.replyToMessage = reply
        composer.replyFocusRequest = replyFocusRequest
        composer.onCancelReply = {
            // Native and SwiftUI callbacks can arrive during a view update.
            DispatchQueue.main.async {
                guard isCurrentSession, composerEditOwner == owner, let reply else { return }
                if let session {
                    guard canUseComposer, !isUpdatingMessage, session.replyToMessage?.id == reply.id
                    else { return }
                    session.setReplyToMessage(nil)
                } else if !isEditing,
                    drafts.draftReply(chatID: chat.id, threadID: threadID)?.id == reply.id
                {
                    drafts.setDraftReply(nil, chatID: chat.id, threadID: threadID)
                }
            }
        }
        composer.onOpenReply = { id in Task { await model.jumpToMessage(id) } }
        composer.isEditing = isEditing
        composer.initialEditText = session?.initialText ?? editingMessage?.message ?? ""
        if isEditing {
            composer.hasEditChanges = { text in self.hasEditChanges(text) }
        }
        composer.editIdentity = owner?.uuidString
        composer.editMentionNames = MessageMentions.names(in: editingMessage?.mentions ?? [])
        composer.allowsEditingMedia = session != nil
        composer.allowsCaption = allowsCaption
        composer.editExitGuard = isEditing ? editExitGuard : nil
        composer.onCancelEdit = cancelEditing
        composer.onEscapeEdit = requestEditingExit
        composer.onRequestEditLastMessage = requestEditLastOwnMessage

        composer.attachments = composerMedia
        composer.attachmentProgress = session == nil ? outgoingQueue.attachmentProgress : [:]
        composer.compressionEnabled = session?.compressionEnabled
            ?? outgoingQueue.compressionEnabled(chatID: chat.id, threadID: threadID)
        if session != nil || !isEditing {
            if allowsCaption {
                composer.onImportImages = { urls in
                    try await importComposerAttachments(urls, session: session, asFiles: false)
                }
            }
            composer.onImportFiles = { urls in
                try await importComposerAttachments(urls, session: session, asFiles: true)
            }
        }
        composer.onRemoveAttachment = { id in
            try await removeComposerAttachment(id, session: session)
        }
        composer.onRetryAttachment = { id in
            try await retryComposerAttachment(id, session: session)
        }
        composer.onCompressionChanged = { enabled in
            guard canUseComposer, pendingEditSession?.id == session?.id else {
                throw APIError.unavailable
            }
            if let session {
                try outgoingQueue.setEditCompression(enabled, session: session)
            } else {
                guard !isEditing else { throw APIError.unavailable }
                try await drafts.flushForAttachmentChange(chatID: chat.id, threadID: threadID)
                guard canUseComposer, !isEditing else { throw CancellationError() }
                try await outgoingQueue.setCompressionEnabled(
                    enabled, chatID: chat.id, threadID: threadID)
            }
        }
        composer.onReorderAttachments = { ids in
            try await reorderComposerAttachments(ids, session: session)
        }
        if !isEditing {
            composer.onDiscardAttachments = {
                guard canUseComposer, !isEditing else { throw APIError.unavailable }
                try await drafts.discardAttachments(chatID: chat.id, threadID: threadID)
            }
        }

        composer.stickerLibrary = store.stickers
        composer.onSendSticker = sendSticker
        composer.onSendVoice = sendVoice
        composer.onSearchMembers = { query in
            guard store.canFetchHistory else { return [] }
            return try await store.searchMembers(chatID: chat.id, query: query)
        }
        composer.linkPreviewScope =
            "\(observation.session.accountID.map(String.init) ?? ""):\(observation.session.revision):\(chat.id):\(threadID ?? ""):\(owner?.uuidString ?? "draft")"
        composer.linkPreviewChoices = composerLinkPreviews
        composer.initialLinkPreviews = editingMessage?.metadata?.linkPreviews ?? []
        if store.canFetchHistory {
            composer.onPreviewLinks = { urls in
                guard isCurrentSession, store.canFetchHistory, composerEditOwner == owner else {
                    throw CancellationError()
                }
                return try await store.previewLinks(chatID: chat.id, urls: urls)
            }
        }
        composer.onEditDraftChanged = {
            guard isCurrentSession, let owner, composerEditOwner == owner else { return }
            editText = $0
        }
        return composer
    }

    @ViewBuilder
    private var savedStatusFeedback: some View {
        if store.canFetchHistory, let error = savedMessages.scopeError(chatID: chat.id) {
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
                interactionContext: currentInteractionContext)
        #else
            ConversationTimelineView(
                model: model, loadsInitialAutomatically: false, actions: actions)
        #endif
    }

    private func loadInteractionPermissions() async {
        guard isCurrentSession, store.canFetchHistory else { return }
        permissionRequestRevision &+= 1
        let revision = permissionRequestRevision
        hasLoadedInteractionPermissions = false
        let network = store.sendPermissionStamp(for: conversationKey).network
        do {
            let info = try await store.groupInfo(chatID: chat.id)
            guard isCurrentSession, store.canFetchHistory, revision == permissionRequestRevision,
                !Task.isCancelled
            else { return }
            let stamp = store.sendPermissionStamp(for: conversationKey)
            guard network == stamp.network else { return }
            var permissions = MessageInteractionContext(
                isDM: info.kind == .dm, canWrite: info.myRole != nil,
                isAdmin: info.myRole == .admin, isThreadView: threadID != nil)
            if permissions.isDM, permissions.canWrite {
                guard let peer = info.peer else { throw APIError.unexpectedResponse }
                let relationship = try await store.friendRelationship(peerUID: peer.uid)
                permissions.canWrite = relationship.canDm && relationship.blocking != true
                    && relationship.blockedBy != true
                    && (relationship.dmChatId == nil || relationship.dmChatId == chat.id)
            }
            guard revision == permissionRequestRevision,
                isCurrentSession, store.canFetchHistory, !Task.isCancelled,
                stamp == store.sendPermissionStamp(for: conversationKey)
            else { return }
            interactionContext = permissions
            hasLoadedInteractionPermissions = true
            persistResolvedSendDecision()
            // A replies-only thread still needs a fresh root check at dispatch.
            let context = currentInteractionContext
            if context.resolvedSendDecision == true,
                context.isDM || context.isAdmin || !context.isThreadView || context.speakingMode != .repliesOnly
            {
                store.rememberVerifiedSendPermission(for: conversationKey, stamp: stamp)
            }
        } catch {
            guard revision == permissionRequestRevision, isCurrentSession, store.canFetchHistory,
                !Task.isCancelled, !(error is CancellationError)
            else {
                return
            }
            guard await store.savedSendDecision(for: conversationKey) == nil,
                revision == permissionRequestRevision, isCurrentSession, store.canFetchHistory,
                !Task.isCancelled
            else { return }
            reactions.error = AppLanguage.localized(
                "Couldn’t load message permissions. Please try again.")
        }
    }

    private func persistResolvedSendDecision() {
        guard let decision = currentInteractionContext.resolvedSendDecision else { return }
        store.rememberSendDecision(decision, for: conversationKey)
    }

    private func invalidateInteractionPermissions() {
        // Fence stale responses and open action snapshots before the async reload.
        permissionRequestRevision &+= 1
        interactionContext.canWrite = false
        hasLoadedInteractionPermissions = false
        selectionDeleteTask?.cancel()
        if store.canFetchHistory { Task { await loadInteractionPermissions() } }
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
        context.canUseNetworkActions = store.canFetchHistory
        guard isCurrentSession else {
            context.canWrite = false
            context.isReadOnly = true
            return context
        }
        context.savedSendDecision = store.currentSavedSendDecision(for: conversationKey)
        if !context.canUseNetworkActions || store.historyCache?.accessRevoked(chat.id) == true {
            context.canUseNetworkActions = false
            context.canWrite = false
            return context
        }
        let hasCurrentInfo = hasLoadedInteractionPermissions
            && store.hasCurrentGroupWriteInfo(chatID: chat.id)
        let info = store.groupInfoByChatID[chat.id]
        if !context.isDM {
            context.canWrite = hasCurrentInfo && info?.myRole != nil
            context.isAdmin = info?.myRole == .admin
            context.speakingMode = info?.effectiveSpeakingMode
            context.hasExistingThread = hasVerifiedThreadRoot && forwardingThreadRoot?.threadInfo != nil
            let requiresRoot = context.isThreadView && context.speakingMode == .repliesOnly
            context.isSendPermissionResolved = hasCurrentInfo
                && (!context.canWrite || context.isAdmin
                    || (context.speakingMode != nil && (!requiresRoot || hasVerifiedThreadRoot)))
        } else {
            context.canWrite = hasCurrentInfo && info?.myRole != nil && context.canWrite
            context.isSendPermissionResolved = hasCurrentInfo
        }
        return context
    }

    private func invalidateForSessionChange() {
        cancelEditEntry()
        permissionRequestRevision &+= 1
        interactionContext.canWrite = false
        hasLoadedInteractionPermissions = false
        selectionDeleteTask?.cancel()
        systemTargetTask?.cancel()
        forwardingThreadRoot = nil
        hasVerifiedThreadRoot = false
        forwardingThreadReplyCount = nil
        cancelEditing()
        outboxAction = nil
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
        let context = currentInteractionContext
        actions.interactionContext = context
        actions.openMention = { openUserProfile($0) }
        actions.openSystemMessage = openSystemMessage
        actions.savedMessageIDs = savedMessages.savedIDs(chatID: chat.id)
        actions.pendingSavedMessageIDs = savedMessages.pendingIDs(chatID: chat.id)
        if context.canUseNetworkActions, savedMessages.hasLoaded(chatID: chat.id) {
            actions.toggleSavedMessage = { message in
                guard !message.isDeleted,
                    !savedMessages.isMutating(chatID: message.chatId, messageID: message.id)
                else { return }
                savedMessageToRetry = message
                Task {
                    guard isCurrentSession, store.canFetchHistory else { return }
                    await savedMessages.toggle(message)
                }
            }
        }
        actions.openAttachment = { attachment in
            presentedFile = attachment
        }
        actions.isSelectionBusy = isDeletingSelection
        actions.forwardMessage = { message in
            guard isCurrentSession, !message.isDeleted,
                store.historyCache?.accessRevoked(chat.id) != true,
                !model.knownDeletedMessageIDs.contains(message.id)
            else { return }
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
        if context.canUseNetworkActions {
            actions.openReactionDetails = {
                guard isCurrentSession, store.canFetchHistory else { return }
                reactionDetailsMessage = ReactionDetailsSelection(chatID: $0.chatId, id: $0.id)
            }
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
        if isCurrentSession {
            let heldID = pendingEditSession?.clientGeneratedID ?? enteringPendingEdit?.clientGeneratedID
            let pending = outgoingQueue.pendingMessages(chatID: chat.id, threadID: threadID)
                .filter { $0.clientGeneratedID != heldID }
            actions.removablePendingMessageIDs = Set(
                pending.filter { $0.state != .sending }.map(\.clientGeneratedID))
            actions.editablePendingMessageIDs = Set(
                pending.filter(\.isEditable).map(\.clientGeneratedID))
        }
        actions.editPendingMessage = startPendingEditing
        actions.removePendingMessage = { pending in
            guard pending.canRemove, pending.senderID == model.currentUserID else { return }
            presentOutboxActions(.remove(pending.clientGeneratedID))
        }
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
        if context.canStageDraft {
            actions.replyToMessage = { message in
                let owner = composerEditOwner
                // Leave the view update before publishing the draft and requesting focus.
                DispatchQueue.main.async {
                    guard composerEditOwner == owner, currentInteractionContext.canStageDraft,
                        editingMessage == nil, !isUpdatingMessage, !isEnteringEdit
                    else { return }
                    if let session = pendingEditSession {
                        guard session.isValid else { return }
                        session.setReplyToMessage(message.replyPreview)
                    } else {
                        guard !drafts.committingDrafts.contains(conversationKey) else { return }
                        drafts.setDraftReply(
                            message.replyPreview, chatID: chat.id, threadID: threadID)
                    }
                    replyFocusRequest &+= 1
                }
            }
        }
        actions.editMessage = startEditing
        if context.canUseNetworkActions, context.canWrite {
            actions.deleteMessage = { message in
                guard canDeleteMessage(message) else { return }
                messageToDelete = message
            }
            actions.toggleReaction = { row, emoji in
                guard let message = row.entry.remoteMessage, !message.isDeleted else { return }
                Task {
                    guard MessageActionPolicy(row: row, context: currentInteractionContext).canReact,
                        !model.knownDeletedMessageIDs.contains(message.id)
                    else { return }
                    await reactions.toggle(
                        message: message, emoji: emoji, currentUserID: model.currentUserID)
                }
            }
        }
        actions.openReply = { id in Task { await model.jumpToMessage(id) } }
        actions.openFailedMessage = { presentOutboxActions(.failure($0)) }
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
        return threadID == nil && context.canUseNetworkActions && context.canWrite
            && (context.isDM || context.isAdmin)
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
            Task {
                guard canManagePins else { return }
                await pins.pin(message)
            }
        }
    }

    private var isEditing: Bool { editingMessage != nil || pendingEditSession != nil }

    private var composerEditOwner: UUID? {
        pendingEditSession?.id ?? editingMessage.map { _ in serverEditIdentity }
    }

    private var canUseComposer: Bool {
        guard isCurrentSession else { return false }
        if let session = pendingEditSession {
            return session.isValid
        }
        return editingMessage.map(isEditable) ?? currentInteractionContext.canStageDraft
    }

    private var composerMedia: [LocalOutgoingAttachment] {
        if let session = pendingEditSession { return session.attachments }
        guard editingMessage == nil else { return [] }
        return outgoingQueue.draftAttachments(chatID: chat.id, threadID: threadID)
    }

    @ViewBuilder private var pendingEditorFeedback: some View {
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

    private func prepareComposerForEditing() async throws {
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
        guard isEditing else { return }
        let owner = pendingEditSession?.id ?? serverEditIdentity
        refreshEditExitGuard(text: text)
        editExitGuard.requestExit {
            guard isCurrentSession, (pendingEditSession?.id ?? serverEditIdentity) == owner,
                !isUpdatingMessage, !composerAttachments.isAcquiring
            else { return }
            cancelEditing()
        }
    }

    private func refreshEditExitGuard(text: String? = nil) {
        let owner = pendingEditSession?.id ?? serverEditIdentity
        guard isEditing, isCurrentSession else {
            editExitGuard.unregister(owner: owner)
            return
        }
        editExitCoordinator?.register(owner: owner, onLeave: cancelEditing)
        editExitGuard.update(
            owner: owner, isDirty: hasEditChanges(text ?? editText) || isComposerComposing,
            isSubmitting: isUpdatingMessage || composerAttachments.isAcquiring,
            accountID: observation.session.accountID, sessionRevision: observation.session.revision)
    }

    private func hasEditChanges(_ text: String) -> Bool {
        guard isEditing else { return false }
        if let session = pendingEditSession {
            return session.hasChanges(text: text, metadata: composerMetadata(for: text))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            != (editingMessage?.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            || DraftLinkURLs.disabledURLs(DraftLinkURLs.choices(editLinkPreviews, in: text))
                != DraftLinkURLs.disabledURLs(initialEditLinkPreviews)
    }

    private var composerLinkPreviews: Binding<[LinkPreviewInput]> {
        let owner = composerEditOwner
        return Binding(
            get: {
                isEditing
                    ? editLinkPreviews
                    : drafts.draftLinkPreviews(chatID: chat.id, threadID: threadID)
            },
            set: {
                guard isCurrentSession, composerEditOwner == owner else { return }
                if isEditing {
                    editLinkPreviews = $0
                    refreshEditExitGuard()
                } else {
                    drafts.setDraftLinkPreviews($0, chatID: chat.id, threadID: threadID)
                }
            })
    }

    private func composerMetadata(for text: String) -> MessageMetadataInput {
        MessageMetadataInput(
            linkPreviews: DraftLinkURLs.choices(composerLinkPreviews.wrappedValue, in: text))
    }

    private func importComposerAttachments(
        _ urls: [URL], session: PendingEditSession?, asFiles: Bool
    ) async throws {
        guard canUseComposer, pendingEditSession?.id == session?.id else {
            throw APIError.unavailable
        }
        if let session {
            if asFiles {
                guard session.attachments.allSatisfy(\.isFile) else {
                    throw PendingEditorFileError.mixedAttachments
                }
                guard editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PendingEditorFileError.caption
                }
            } else if session.attachments.contains(where: \.isFile) {
                throw PendingEditorFileError.mixedAttachments
            }
            try await outgoingQueue.importEditAttachments(
                urls: urls, session: session, asFiles: asFiles)
        } else {
            guard !isEditing else { throw APIError.unavailable }
            try await drafts.flushForAttachmentChange(chatID: chat.id, threadID: threadID)
            guard canUseComposer, !isEditing else { throw CancellationError() }
            if asFiles {
                try await outgoingQueue.importFiles(urls: urls, chatID: chat.id, threadID: threadID)
            } else {
                try await outgoingQueue.importImages(urls: urls, chatID: chat.id, threadID: threadID)
            }
        }
    }

    private enum PendingEditorFileError: LocalizedError {
        case mixedAttachments
        case caption

        var errorDescription: String? {
            switch self {
            case .mixedAttachments:
                AppLanguage.localized("Files must be sent separately from photos and videos.")
            case .caption:
                AppLanguage.localized("Remove the caption before adding files to this queued message.")
            }
        }
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
        let owner = composerEditOwner
        return Binding(
            get: {
                !isEditing
                    ? drafts.draftText(chatID: chat.id, threadID: threadID) : editText
            },
            set: {
                guard isCurrentSession, composerEditOwner == owner else { return }
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
            return !isUpdatingMessage && session.isValid && !session.isUploading
                && (isComposerComposing || !text.isEmpty || !session.attachments.isEmpty)
        }
        if editingMessage != nil {
            return !isUpdatingMessage
                && (isComposerComposing || (!text.isEmpty && hasEditChanges(text)))
        }
        return canQueueNewMessage
    }

    private var canQueueNewMessage: Bool {
        currentInteractionContext.canSend && !isEditing && !isEnteringEdit
            && outgoingQueue.storageState == .ready
            && !drafts.committingDrafts.contains(conversationKey)
    }

    private func sendSticker(_ sticker: MessageStickerResponse) async -> Bool {
        guard canQueueNewMessage else { return false }
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
        guard canQueueNewMessage else { return false }
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
            let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let metadata = composerMetadata(for: text)
            guard session.isValid, !isUpdatingMessage, !session.isUploading,
                session.hasChanges(text: text, metadata: metadata),
                hasText || !session.attachments.isEmpty,
                !hasText || !session.attachments.contains(where: \.isFile)
            else { return false }
            isUpdatingMessage = true
            defer { isUpdatingMessage = false }
            do {
                try await outgoingQueue.submitPendingEdit(session, text: text, metadata: metadata)
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
            guard canQueueNewMessage else { return false }
            let sent = await drafts.submitDraft(
                chatID: chat.id, threadID: threadID, text: text,
                metadata: composerMetadata(for: text))
            if sent { model.revealLatestAfterSend() }
            if !sent, let error = drafts.submissionError { outboxError = error }
            return sent
        }
        guard isEditable(message), !isUpdatingMessage else { return false }
        isUpdatingMessage = true
        let submittedText = text
        let submittedEditIdentity = serverEditIdentity
        let submittedMetadata = composerMetadata(for: submittedText)
        let didUpdate = await store.updateMessage(
            message, text: submittedText, metadata: submittedMetadata)
        guard isCurrentSession, !Task.isCancelled else { return false }
        guard editingMessage?.id == message.id, pendingEditSession == nil,
            submittedEditIdentity == serverEditIdentity
        else { return didUpdate }
        isUpdatingMessage = false
        if didUpdate {
            if editText == submittedText && composerMetadata(for: editText) == submittedMetadata {
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
        guard editingMessage?.id != message.id || pendingEditSession != nil else { return }
        refreshEditExitGuard()
        editExitGuard.requestExit {
            beginEditing(message)
        }
    }

    private func beginEditing(_ message: MessageResponse) {
        isEnteringEdit = true
        editEntryTask = Task {
            defer { isEnteringEdit = false }
            do {
                try await prepareComposerForEditing()
                guard isCurrentSession, isTimelineVisible, isEditable(message), !Task.isCancelled
                else { return }
                cancelEditing()
                editingMessage = message
                editText = message.message ?? ""
                editLinkPreviews = (message.metadata?.linkPreviews ?? [])
                    .filter { $0.status == .disabled }
                    .map { LinkPreviewInput(url: $0.url, status: .disabled) }
                initialEditLinkPreviews = editLinkPreviews
                refreshEditExitGuard()
                replyFocusRequest &+= 1
            } catch { editError = error.localizedDescription }
        }
    }

    private func cancelEditing() {
        editExitGuard.unregister(owner: pendingEditSession?.id ?? serverEditIdentity)
        editExitCoordinator?.unregister(owner: pendingEditSession?.id ?? serverEditIdentity)
        serverEditIdentity = UUID()
        composerAttachments.cancelEditingWork?()
        if let session = pendingEditSession { outgoingQueue.endPendingEdit(session) }
        pendingEditSession = nil
        editLinkPreviews = []
        initialEditLinkPreviews = []
        editingMessage = nil
        editText = ""
        isComposerComposing = false
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
        guard isCurrentSession,
            pending.chatID == chat.id, pending.threadID == threadID,
            pending.canEdit,
            pending.senderID == model.currentUserID,
            !isUpdatingMessage, !isEnteringEdit
        else { return }
        guard pendingEditSession?.clientGeneratedID != pending.clientGeneratedID else { return }
        refreshEditExitGuard()
        editExitGuard.requestExit {
            beginPendingEditing(pending)
        }
    }

    private func beginPendingEditing(_ pending: PendingOutgoingMessage) {
        guard isCurrentSession, isTimelineVisible else { return }
        let session: PendingEditSession
        do {
            // Install the hold before yielding for native input or a draft flush.
            session = try outgoingQueue.beginPendingEdit(pending)
        } catch {
            editError = error.localizedDescription
            return
        }
        enteringPendingEdit = session
        isEnteringEdit = true
        editEntryTask = Task {
            defer {
                isEnteringEdit = false
                if enteringPendingEdit?.id == session.id { enteringPendingEdit = nil }
                if pendingEditSession?.id != session.id { outgoingQueue.endPendingEdit(session) }
            }
            do {
                try await prepareComposerForEditing()
                guard isCurrentSession, isTimelineVisible, session.isValid, !Task.isCancelled
                else { return }
                cancelEditing()
                pendingEditSession = session
                editText = session.initialText
                editLinkPreviews = session.initialMetadata?.linkPreviews ?? []
                initialEditLinkPreviews = editLinkPreviews
                refreshEditExitGuard()
                replyFocusRequest &+= 1
            } catch {
                if isCurrentSession { editError = error.localizedDescription }
            }
        }
    }

    private func cancelEditEntry() {
        editEntryTask?.cancel()
        if let session = enteringPendingEdit {
            outgoingQueue.endPendingEdit(session)
            enteringPendingEdit = nil
        }
    }

    private struct OutboxActionTarget {
        let id: String
        let phase: OutboxPhase

        var hasPossibleDelivery: Bool {
            guard case .failed(let failure, _) = phase else { return false }
            return OutgoingMessageQueue.requiresRemovalConfirmation(for: failure)
        }

        var detail: String {
            guard case .failed(let failure, let nextRetry) = phase else {
                return AppLanguage.localized("This message will be removed from the local outbox.")
            }
            var detail = failure.reason.displayDetail
            if let nextRetry {
                let time = nextRetry.formatted(date: .omitted, time: .standard)
                detail += "\n" + AppLanguage.localized("Next retry at \(time).")
            }
            if hasPossibleDelivery {
                detail += "\n" + AppLanguage.localized("The message may already have been delivered.")
            }
            return detail
        }
    }

    private var outboxActionTarget: OutboxActionTarget? {
        guard let action = outboxAction, let target = removableOutgoing(action.id) else { return nil }
        if case .failure = action, !target.phase.isFailed { return nil }
        return target
    }

    private func removableOutgoing(_ id: String) -> OutboxActionTarget? {
        guard isCurrentSession,
            let item = outgoingQueue.pendingMessages(chatID: chat.id, threadID: threadID)
                .first(where: { $0.clientGeneratedID == id }),
            item.senderID == model.currentUserID,
            pendingEditSession?.clientGeneratedID != id,
            enteringPendingEdit?.clientGeneratedID != id
        else { return nil }
        let phase = outgoingQueue.phase(of: item)
        guard phase != .sending else { return nil }
        return OutboxActionTarget(id: id, phase: phase)
    }

    private var outboxActionTitle: String {
        if case .failure? = outboxAction, outboxActionTarget?.hasPossibleDelivery != true {
            return AppLanguage.localized("Message needs attention")
        }
        return AppLanguage.localized("Remove from Outbox?")
    }

    private func presentOutboxActions(_ action: OutboxAction) {
        guard isCurrentSession else { return }
        outboxAction = action
        if outboxActionTarget == nil { outboxAction = nil }
    }

    private func removeOutgoing(_ confirmed: OutboxActionTarget) {
        Task {
            do {
                guard let target = removableOutgoing(confirmed.id) else { return }
                if target.hasPossibleDelivery && !confirmed.hasPossibleDelivery {
                    presentOutboxActions(.remove(target.id))
                    return
                }
                try await outgoingQueue.removeOutgoing(
                    chatID: chat.id, threadID: threadID, itemID: target.id,
                    allowPossibleDelivery: confirmed.hasPossibleDelivery)
            } catch OutgoingMessageQueue.QueueError.possibleDelivery {
                presentOutboxActions(.remove(confirmed.id))
            } catch {
                if isCurrentSession { outboxError = error.localizedDescription }
            }
        }
    }

    private func retryOutgoing(_ id: String) {
        Task {
            do {
                guard removableOutgoing(id)?.phase.isFailed == true else { return }
                try await outgoingQueue.retry(
                    chatID: chat.id, threadID: threadID, clientGeneratedID: id)
            } catch {
                if isCurrentSession { outboxError = error.localizedDescription }
            }
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
