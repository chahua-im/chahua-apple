import ChahuaAPI
import SwiftUI
import UniformTypeIdentifiers

struct ChatDetailView: View {
    let chat: ChatListItem
    let navigationTitle: String?
    let threadID: String?
    let initialPosition: TimelineInitialPosition
    private var conversationKey: ConversationKey { .init(chatID: chat.id, threadID: threadID) }
    @ObservedObject private var store: ChatStore
    @StateObject private var model: ConversationTimelineModel
    @ObservedObject private var reactions: MessageReactionController
    @ObservedObject private var drafts: ChatDraftStore
    @ObservedObject private var outgoingQueue: OutgoingMessageQueue
    @State private var interactionContext: MessageInteractionContext
    @State private var hasLoadedInteractionPermissions = false
    @State private var failedMessageID: String?
    @State private var showsRetryOptions = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var replyFocusRequest = 0
    @State private var editingMessage: MessageResponse?
    @State private var editText = ""
    @State private var isUpdatingMessage = false
    @State private var editError: String?
    @State private var outboxError: String?
    @StateObject private var composerAttachments = ComposerAttachmentState()
    @State private var isMediaDropTargeted = false

    init(
        chat: ChatListItem,
        currentUserID: Int32,
        store: ChatStore,
        navigationTitle: String? = nil,
        threadID: String? = nil,
        initialPosition: TimelineInitialPosition? = nil
    ) {
        self.chat = chat
        self.navigationTitle = navigationTitle
        self.threadID = threadID
        self.initialPosition = initialPosition ?? (chat.unreadCount > 0 ? .unread(after: chat.lastReadMessageId) : .liveEdge)
        self.store = store
        self.reactions = store.reactions
        self.drafts = store.drafts
        self.outgoingQueue = store.outgoingQueue
        _interactionContext = State(initialValue: .init(isDM: chat.kind == .dm, isThreadView: threadID != nil))
        _model = StateObject(
            wrappedValue: ConversationTimelineModel(
                chatID: chat.id,
                currentUserID: currentUserID,
                isGroupChat: chat.kind == .group,
                source: store,
                messageStore: store.conversationMessages,
                threadID: threadID,
                markRead: { messageID in
                    try await store.markRead(chatID: chat.id, threadID: threadID, messageID: messageID)
                }
            ))
    }

    var body: some View {
        MessageInteractionHost(model: model, context: interactionContext, actions: bubbleActions) {
            interactiveActions in
            GeometryReader { geometry in
                ConversationTimelineView(model: model, loadsInitialAutomatically: false, actions: interactiveActions)
                    .modifier(
                        ChatComposerOverlay {
                            VStack(spacing: 0) {
                                if store.outgoingQueue.storageState == .failed || drafts.draftSaveFailed {
                                    HStack {
                                        Text("Couldn’t save messages on this device.")
                                            .font(.caption)
                                        Spacer(minLength: 8)
                                        Button("Retry") { Task { await store.retryLocalStorage() } }
                                    }
                                    .padding(12)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                                    .padding(.horizontal, 12)
                                } else if store.outgoingQueue.storageState == .loading {
                                    ProgressView("Loading saved messages…")
                                        .controlSize(.small)
                                        .padding(12)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                                }
                                MessageComposerView(
                                    text: composerText,
                                    attachmentState: composerAttachments,
                                    maxHeight: max(36, geometry.size.height / 3),
                                    isEnabled: interactionContext.canWrite && (editingMessage != nil
                                        ? !isUpdatingMessage
                                        : !drafts.committingDrafts.contains(conversationKey)),
                                    canSend: canSubmitComposer,
                                    onSubmit: submitComposer,
                                    onCompositionChanged: { composing in
                                        guard editingMessage == nil else { return }
                                        drafts.setDraftComposing(composing, chatID: chat.id, threadID: threadID)
                                    },
                                    replyToMessage: drafts.draftReply(chatID: chat.id, threadID: threadID),
                                    replyFocusRequest: replyFocusRequest,
                                    onCancelReply: { drafts.setDraftReply(nil, chatID: chat.id, threadID: threadID) },
                                    onOpenReply: { id in Task { await model.jumpToMessage(id) } },
                                    editingMessage: editingMessage,
                                    onCancelEdit: cancelEditing,
                                    onRequestEditLastMessage: requestEditLastOwnMessage,
                                    attachments: outgoingQueue.draftAttachments(chatID: chat.id, threadID: threadID),
                                    attachmentProgress: outgoingQueue.attachmentProgress,
                                    compressionEnabled: outgoingQueue.compressionEnabled(chatID: chat.id, threadID: threadID),
                                    onImportImages: { urls in
                                        try await drafts.flushForAttachmentChange(chatID: chat.id, threadID: threadID)
                                        try await outgoingQueue.importImages(urls: urls, chatID: chat.id, threadID: threadID)
                                    },
                                    onRemoveAttachment: { id in
                                        try await drafts.flushForAttachmentChange(chatID: chat.id, threadID: threadID)
                                        try await outgoingQueue.removeAttachment(id: id, chatID: chat.id, threadID: threadID)
                                    },
                                    onRetryAttachment: { id in
                                        try await drafts.flushForAttachmentChange(chatID: chat.id, threadID: threadID)
                                        try await outgoingQueue.retryAttachment(id: id, chatID: chat.id, threadID: threadID)
                                    },
                                    onCompressionChanged: { enabled in
                                        try await drafts.flushForAttachmentChange(chatID: chat.id, threadID: threadID)
                                        try await outgoingQueue.setCompressionEnabled(enabled, chatID: chat.id, threadID: threadID)
                                    },
                                    onReorderAttachments: { ids in
                                        try await drafts.flushForAttachmentChange(chatID: chat.id, threadID: threadID)
                                        try await outgoingQueue.reorderAttachments(ids: ids, chatID: chat.id, threadID: threadID)
                                    }
                                )
                            }
                        })
            }
        }
        .contentShape(Rectangle())
        .onDrop(of: [.image, .movie, .fileURL], isTargeted: $isMediaDropTargeted) { providers in
            guard interactionContext.canWrite, editingMessage == nil,
                outgoingQueue.storageState == .ready,
                !drafts.committingDrafts.contains(conversationKey)
            else { return false }
            return composerAttachments.acceptDrop(providers)
        }
        .overlay {
            if isMediaDropTargeted, interactionContext.canWrite, editingMessage == nil,
                !composerAttachments.isAcquiring {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle(navigationTitle ?? chat.chatDisplayName)
        .onAppear {
            store.registerTimeline(model)
            model.setReadTrackingActive(scenePhase == .active)
        }
        .task { await model.open(position: initialPosition) }
        .task { await loadInteractionPermissions() }
        .onChange(of: scenePhase) { _, phase in
            model.setReadTrackingActive(phase == .active)
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
        .confirmationDialog("Message not sent", isPresented: $showsRetryOptions, titleVisibility: .visible) {
            Button("Resend this message") { retry(.message) }
            Button("Retry this and subsequent messages") { retry(.messageAndSubsequent) }
            Button("Cancel", role: .cancel) { failedMessageID = nil }
        }
        .alert(
            "Couldn’t edit message",
            isPresented: Binding(get: { editError != nil }, set: { if !$0 { editError = nil } })
        ) {
            Button("OK") { editError = nil }
        } message: {
            Text(editError ?? "")
        }
        .alert("Couldn’t update outbox", isPresented: Binding(get: { outboxError != nil }, set: { if !$0 { outboxError = nil } })) {
            Button("OK") { outboxError = nil }
        } message: {
            Text(outboxError ?? "")
        }
        .onReceive(store.outgoingQueue.events) { _ in
            guard let failedMessageID else { return }
            if !store.outgoingQueue.pendingMessages(chatID: chat.id, threadID: threadID).contains(where: {
                $0.clientGeneratedID == failedMessageID && $0.state == .failed
            }) {
                showsRetryOptions = false
                self.failedMessageID = nil
            }
        }
        .onDisappear {
            model.setReadTrackingActive(false)
            store.unregisterTimeline(model)
            model.close()
            Task { await drafts.flushDraft(chatID: chat.id, threadID: threadID) }
        }
    }

    private func loadInteractionPermissions() async {
        if let permissions = await reactions.loadPermissions(chatID: chat.id) {
            interactionContext = permissions
            interactionContext.isThreadView = threadID != nil
            hasLoadedInteractionPermissions = true
        }
    }

    private var bubbleActions: TimelineBubbleActions {
        var actions = TimelineBubbleActions()
        actions.currentUserProfile = store.currentUserProfile
        actions.pendingReactionMessageIDs = reactions.pendingMessageIDs
        if let tail = outgoingQueue.snapshots[conversationKey]?.outgoing.last,
           outgoingQueue.snapshots[conversationKey]?.composingItem == nil, !tail.dispatchClaimed {
            actions.modifiablePendingMessageIDs = [tail.clientGeneratedID]
        }
        actions.blockPendingMessage = { pending in changePending(pending, revoke: false) }
        actions.revokePendingMessage = { pending in changePending(pending, revoke: true) }
        actions.openLink = { url in
            _ = openURL(url)
        }
        if interactionContext.canWrite {
            actions.replyToMessage = { message in
                guard !drafts.committingDrafts.contains(conversationKey) else { return }
                drafts.setDraftReply(message.replyPreview, chatID: chat.id, threadID: threadID)
                replyFocusRequest &+= 1
            }
            actions.editMessage = startEditing
            actions.toggleReaction = { row, emoji in
                guard let message = row.entry.remoteMessage, !message.isDeleted else { return }
                Task { await reactions.toggle(message: message, emoji: emoji, currentUserID: model.currentUserID) }
            }
        }
        actions.openReply = { id in Task { await model.jumpToMessage(id) } }
        actions.openFailedMessage = { id in
            failedMessageID = id
            showsRetryOptions = true
        }
        return actions
    }

    private var composerText: Binding<String> {
        Binding(
            get: { editingMessage == nil ? drafts.draftText(chatID: chat.id, threadID: threadID) : editText },
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
        let text = (editingMessage == nil ? drafts.draftText(chatID: chat.id, threadID: threadID) : editText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard interactionContext.canWrite else { return false }
        if let editingMessage {
            return !text.isEmpty && !isUpdatingMessage
                && text != editingMessage.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return outgoingQueue.storageState == .ready && !drafts.committingDrafts.contains(conversationKey)
    }

    private func submitComposer() async -> Bool {
        guard let message = editingMessage else {
            let sent = await drafts.submitDraft(chatID: chat.id, threadID: threadID)
            if sent { await model.revealLatestAfterSend() }
            return sent
        }
        guard !isUpdatingMessage else { return false }
        isUpdatingMessage = true
        let didUpdate = await store.updateMessage(message, text: editText)
        isUpdatingMessage = false
        if didUpdate {
            cancelEditing()
        } else {
            editError = String(localized: "Couldn’t edit this message. Please try again.")
        }
        return didUpdate
    }

    private func isEditable(_ message: MessageResponse) -> Bool {
        MessageActionPolicy(
            messageType: message.messageType, text: message.message, isDeleted: message.isDeleted,
            isOwn: message.sender.uid == model.currentUserID, context: interactionContext
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
        guard !pending.dispatchClaimed, !drafts.committingDrafts.contains(conversationKey), editingMessage == nil else { return }
        Task {
            do {
                try await drafts.flushForAttachmentChange(chatID: chat.id, threadID: threadID)
                if revoke {
                    try await outgoingQueue.revokeTail(chatID: chat.id, threadID: threadID, itemID: pending.clientGeneratedID, expectedRevision: pending.editRevision)
                } else {
                    try await outgoingQueue.blockTail(chatID: chat.id, threadID: threadID, itemID: pending.clientGeneratedID, expectedRevision: pending.editRevision)
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
                try await outgoingQueue.retry(chatID: chat.id, threadID: threadID, clientGeneratedID: id, scope: scope)
            } catch { outboxError = error.localizedDescription }
        }
    }
}
