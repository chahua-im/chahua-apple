import ChahuaAPI
import SwiftUI

// Concrete modifier bodies keep independent presentation trees out of the screen's
// generic body type. Inputs are the routing state each boundary actually needs, not
// a copy of ChatDetailView (which would carry every observed object and composer state).
struct ChatDetailAttachmentPresentation: ViewModifier {
    let chat: ChatListItem
    let threadID: String?
    let store: ChatStore
    let model: ConversationTimelineModel
    @Binding var showsThreadInfo: Bool
    @Binding var infoMessageTarget: MessageResponse?
    @Binding var infoProfileUID: Int32?
    @Binding var infoChatTarget: ChatListItem?
    @Binding var presentedFile: AttachmentResponse?

    func body(content: Content) -> some View {
        content
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
                        .voicePlaybackHeader()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showsThreadInfo = false }
                            }
                        }
                        .navigationDestination(item: $infoMessageTarget) { message in
                            ChatDetailPresentation(
                                chat: chat, currentUserID: model.currentUserID, store: store,
                                threadID: message.replyRootId,
                                initialPosition: .message(message.id))
                        }
                        .modifier(
                            UserProfilePresentation(
                                uid: $infoProfileUID, currentUserID: model.currentUserID,
                                store: store,
                                onOpenChat: { chat in
                                    infoProfileUID = nil
                                    infoChatTarget = chat
                                })
                        )
                        .navigationDestination(item: $infoChatTarget) { target in
                            ChatDetailPresentation(
                                chat: target, currentUserID: model.currentUserID, store: store)
                        }
                    }
                    .voicePlaybackCover { showsThreadInfo = false }
                    .environment(\.chatHeaderInset, 0)
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
                        .voicePlaybackHeader()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { presentedFile = nil }
                            }
                        }
                    }
                    .voicePlaybackCover { presentedFile = nil }
                }
            }
    }
}

extension ChatDetailView {
    struct PinPresentation: ViewModifier {
        let store: ChatStore
        let currentUserID: Int32
        @ObservedObject var pins: ChatPinController
        // Confirmation may outlive a permissions render; authorize on invocation.
        let canManagePins: () -> Bool
        @Binding var showsPinnedMessages: Bool
        @Binding var stickerToView: StickerSelection?
        @Binding var reactionDetailsMessage: ReactionDetailsSelection?
        @Binding var pinToUnpin: PinResponse?
        @Binding var messageToPin: MessageResponse?
        @Binding var feedback: String?
        let chatID: String
        let onJumpToPin: (MessageResponse) -> Void
        let onOpenThread: ((MessageResponse) -> Void)?
        let onPin: (MessageResponse) -> Void
        #if os(iOS)
            @Environment(\.horizontalSizeClass) private var horizontalSizeClass
        #endif

        func body(content: Content) -> some View {
            content
                #if os(iOS)
                    .sheet(
                        isPresented: Binding(
                            get: { horizontalSizeClass == .compact && showsPinnedMessages },
                            set: { if horizontalSizeClass == .compact { showsPinnedMessages = $0 } }
                        )
                    ) {
                        ChatPinnedMessagesSheet(
                            chatID: chatID, controller: pins, canManage: canManagePins(),
                            onSelect: onJumpToPin, onOpenThread: onOpenThread,
                            showsVoiceHeader: true
                        )
                        .voicePlaybackCover { showsPinnedMessages = false }
                    }
                #endif
                .sheet(item: $stickerToView) { selection in
                    StickerPackSheet(
                        stickerID: selection.id, library: store.stickers,
                        currentUserID: currentUserID
                    )
                    .voicePlaybackCover { stickerToView = nil }
                }
                .sheet(item: $reactionDetailsMessage) { message in
                    ReactionDetailsView(chatID: message.chatID, messageID: message.id) {
                        try await store.reactionDetails(
                            chatID: message.chatID, messageID: message.id)
                    }
                }
                .alert(
                    "Pin Message",
                    isPresented: Binding(
                        get: { messageToPin != nil }, set: { if !$0 { messageToPin = nil } }),
                    presenting: messageToPin
                ) { message in
                    Button("Pin") { onPin(message) }
                    Button("Cancel", role: .cancel) { messageToPin = nil }
                } message: { _ in
                    Text("Would you like to pin this message?")
                }
                .alert(
                    "Unpin Message",
                    isPresented: Binding(
                        get: { pinToUnpin != nil }, set: { if !$0 { pinToUnpin = nil } })
                ) {
                    if let pin = pinToUnpin {
                        Button("Unpin", role: .destructive) {
                            Task {
                                guard canManagePins() else { return }
                                await pins.unpin(pin)
                                guard canManagePins(), !Task.isCancelled,
                                    pins.pinsByChatID[chatID]?.contains(where: { $0.id == pin.id })
                                        == false
                                else { return }
                                feedback = AppLanguage.localized("Unpinned")
                            }
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
                        set: { if !$0 { pins.error = nil } })
                ) {
                    Button("OK") { pins.error = nil }
                } message: {
                    Text(pins.error ?? "")
                }
        }
    }
}

/// Independent error routes share a small concrete boundary, not the timeline's
/// layout type. Their bindings remain owned by ChatDetailView for existing actions.
struct ChatDetailMutationErrors: ViewModifier {
    @Binding var systemTargetError: String?
    @Binding var editError: String?
    @Binding var outboxError: String?

    func body(content: Content) -> some View {
        content
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
}

extension ChatDetailView {
    struct ForwardingPresentation: ViewModifier {
        let chat: ChatListItem
        let currentUserID: Int32
        let store: ChatStore
        let onOpenThread: ((MessageResponse) -> Void)?
        let loadWholeThread: @MainActor () async throws -> [MessageResponse]
        @Binding var forwardRequest: ForwardSelection?
        @Binding var systemMessageTarget: MessageResponse?
        @Binding var recordRequest: RecordSelection?

        let onForwardCompleted: () -> Void
        func body(content: Content) -> some View {
            content
                // Forwarding does not take playback-header ownership from the source chat.
                .sheet(item: $forwardRequest) { request in
                    forwardingPicker(request)
                }
                .navigationDestination(item: $systemMessageTarget) { message in
                    ChatDetailPresentation(
                        chat: chat, currentUserID: currentUserID, store: store,
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
                loader = { try await loadWholeThread() }
            } else {
                loader = nil
            }
            return ForwardDestinationPicker(
                store: store, sources: request.sources, sourceTitle: chat.chatDisplayName,
                loadSources: loader
            ) {
                request.onPrepared()
                onForwardCompleted()
            }
        }
    }
}

struct ChatDetailDeletionPresentation: ViewModifier {
    let store: ChatStore
    let currentUserID: Int32
    @Binding var messageToDelete: MessageResponse?
    @Binding var editingMessage: MessageResponse?
    @Binding var deleteError: Bool
    @Binding var feedback: String?
    let isCurrentSession: () -> Bool
    let canDelete: (MessageResponse) -> Bool
    let groupChatWriteRestricted: () -> Bool
    let cancelEditing: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                AppLanguage.localized("Recall Message"),
                isPresented: Binding(
                    get: { messageToDelete != nil }, set: { if !$0 { messageToDelete = nil } }),
                titleVisibility: .visible,
                presenting: messageToDelete
            ) { message in
                Button("Recall", role: .destructive) {
                    Task {
                        guard canDelete(message) else { return }
                        let deleted = await store.deleteMessage(message)
                        guard isCurrentSession(), !Task.isCancelled else { return }
                        if deleted {
                            if editingMessage?.id == message.id { cancelEditing() }
                            feedback = AppLanguage.localized("Recalled")
                        } else {
                            deleteError = true
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { message in
                if message.sender.uid == currentUserID {
                    Text("Are you sure you want to recall this message?")
                } else {
                    Text(
                        "Are you sure you want to recall this message from \(message.sender.name ?? AppLanguage.localized("this user"))?"
                    )
                }
            }
            .alert("Failed to delete message", isPresented: $deleteError) {
                Button("OK") {}
            } message: {
                if groupChatWriteRestricted() {
                    Text("Your user group cannot post in group chats.")
                }
            }
    }
}

struct ChatDetailStickerPresentation: ViewModifier {
    @ObservedObject var library: StickerLibrary
    @Binding var messageToMakeSticker: ChatDetailView.MessageStickerSelection?
    @Binding var errorMessage: String?
    let canUseNetworkActions: Bool
    let onAdded: () -> Void
    let sourceIsAvailable: (MessageResponse) -> Bool

    func body(content: Content) -> some View {
        content
            .sheet(item: $messageToMakeSticker) { selection in
                MessageStickerSheet(
                    library: library, message: selection.message,
                    sourceIsAvailable: { sourceIsAvailable(selection.message) },
                    onAdded: onAdded
                )
                .voicePlaybackCover { messageToMakeSticker = nil }
            }
            .alert(
                "Stickers",
                isPresented: Binding(
                    get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                if !library.hasLoadedLibrary, canUseNetworkActions {
                    Button("Retry") { Task { await loadFavorites() } }
                }
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task(id: canUseNetworkActions) {
                guard canUseNetworkActions, !library.hasLoadedLibrary else { return }
                await loadFavorites()
            }
    }

    private func loadFavorites() async {
        await library.refresh()
        guard !Task.isCancelled else { return }
        if let error = library.error {
            errorMessage = error
            library.error = nil
        }
    }
}

struct MessageActionFeedbackPresentation: ViewModifier {
    @Binding var feedback: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let feedback {
                    Text(feedback)
                        .font(.callout)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 72)
                        .allowsHitTesting(false)
                }
            }
            .task(id: feedback) {
                guard feedback != nil else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                feedback = nil
            }
    }
}
