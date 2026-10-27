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
                        .navigationDestination(item: $infoProfileUID) { uid in
                            UserProfileView(
                                uid: uid, currentUserID: model.currentUserID, store: store,
                                onOpenChat: { infoChatTarget = $0 })
                        }
                        .navigationDestination(item: $infoChatTarget) { target in
                            ChatDetailPresentation(
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

        func body(content: Content) -> some View {
            content
                .sheet(item: $stickerToView) { selection in
                    StickerPackSheet(
                        stickerID: selection.id, library: store.stickers,
                        currentUserID: currentUserID)
                }
                .sheet(item: $reactionDetailsMessage) { message in
                    ReactionDetailsView(chatID: message.chatID, messageID: message.id) {
                        try await store.reactionDetails(
                            chatID: message.chatID, messageID: message.id)
                    }
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

        func body(content: Content) -> some View {
            content
                .sheet(item: $forwardRequest) { request in forwardingPicker(request) }
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
                store: store, sources: request.sources, loadSources: loader,
                moveFrom: request.moveFrom, expectedForwardID: request.expectedForwardID
            ) {
                request.onPrepared()
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
    let canDelete: (MessageResponse) -> Bool
    let cancelEditing: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                AppLanguage.localized("Delete Message"),
                isPresented: Binding(
                    get: { messageToDelete != nil }, set: { if !$0 { messageToDelete = nil } }),
                titleVisibility: .visible,
                presenting: messageToDelete
            ) { message in
                Button("Delete", role: .destructive) {
                    Task {
                        guard canDelete(message) else { return }
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
                if message.sender.uid == currentUserID {
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
}
