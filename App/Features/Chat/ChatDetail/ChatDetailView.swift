import ChahuaAPI
import SwiftUI

struct ChatDetailView: View {
    let chat: ChatListItem
    @ObservedObject private var store: ChatStore
    @StateObject private var model: ConversationTimelineModel
    @ObservedObject private var reactions: MessageReactionController
    @State private var interactionContext: MessageInteractionContext
    @State private var hasLoadedInteractionPermissions = false
    @State private var failedMessageID: String?
    @State private var showsRetryOptions = false

    init(chat: ChatListItem, currentUserID: Int32, store: ChatStore) {
        self.chat = chat
        self.store = store
        self.reactions = store.reactions
        _interactionContext = State(initialValue: .init(isDM: chat.kind == .dm))
        _model = StateObject(
            wrappedValue: ConversationTimelineModel(
                chatID: chat.id,
                currentUserID: currentUserID,
                isGroupChat: chat.kind == .group,
                source: store,
                messageStore: store.conversationMessages
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
                                if store.outgoingQueue.storageState == .failed || store.draftSaveFailed {
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
                                    text: Binding(
                                        get: { store.draftText(chatID: chat.id) },
                                        set: { store.setDraftText($0, chatID: chat.id) }),
                                    maxHeight: max(36, geometry.size.height / 3),
                                    isEnabled: !store.committingDrafts.contains(chat.id),
                                    canSend: store.outgoingQueue.storageState == .ready
                                        && !store.committingDrafts.contains(chat.id)
                                        && !store.draftText(chatID: chat.id).trimmingCharacters(
                                            in: .whitespacesAndNewlines
                                        ).isEmpty,
                                    onSubmit: {
                                        Task {
                                            if await store.submitDraft(chatID: chat.id) {
                                                await model.revealLatestAfterSend()
                                            }
                                        }
                                    },
                                    onCompositionChanged: { store.setDraftComposing($0, chatID: chat.id) }
                                )
                            }
                        })
            }
        }
        .navigationTitle(chat.chatDisplayName)
        .onAppear { store.registerTimeline(model) }
        .task { await model.open() }
        .task { await loadInteractionPermissions() }
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
        .onReceive(store.outgoingQueue.events) { _ in
            guard let failedMessageID else { return }
            if !store.outgoingQueue.pendingMessages(chatID: chat.id).contains(where: {
                $0.clientGeneratedID == failedMessageID && $0.state == .failed
            }) {
                showsRetryOptions = false
                self.failedMessageID = nil
            }
        }
        .onDisappear {
            store.unregisterTimeline(model)
            model.close()
            Task { await store.flushDraft(chatID: chat.id) }
        }
    }

    private func loadInteractionPermissions() async {
        if let permissions = await reactions.loadPermissions(chatID: chat.id) {
            interactionContext = permissions
            hasLoadedInteractionPermissions = true
        }
    }

    private var bubbleActions: TimelineBubbleActions {
        var actions = TimelineBubbleActions()
        actions.pendingReactionMessageIDs = reactions.pendingMessageIDs
        if interactionContext.canWrite {
            actions.toggleReaction = { row, emoji in
                guard let message = row.entry.remoteMessage, !message.isDeleted else { return }
                Task { await reactions.toggle(message: message, emoji: emoji, currentUserID: model.currentUserID) }
            }
        }
        actions.openFailedMessage = { id in
            failedMessageID = id
            showsRetryOptions = true
        }
        return actions
    }

    private func retry(_ scope: OutgoingRetryScope) {
        guard let id = failedMessageID else { return }
        failedMessageID = nil
        Task {
            // The queue surfaces local-storage errors and treats a late acknowledgement as a no-op.
            try? await store.outgoingQueue.retry(chatID: chat.id, clientGeneratedID: id, scope: scope)
        }
    }
}
