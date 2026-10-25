import ChahuaAPI
import SwiftUI

struct SavedMessagesView: View {
    private let store: ChatStore
    private let onOpenSource: (MessageResponse, ChatListItem) -> Void
    @ObservedObject private var saved: SavedMessageController
    @State private var sourceError: String?
    @State private var locatingID: String?

    init(
        store: ChatStore,
        onOpenSource: @escaping (MessageResponse, ChatListItem) -> Void
    ) {
        self.store = store
        self.onOpenSource = onOpenSource
        _saved = ObservedObject(wrappedValue: store.savedMessages)
    }

    var body: some View {
        List {
            if saved.items.isEmpty, saved.isLoadingList {
                ProgressView("Loading saved messages…")
            }
            if saved.items.isEmpty, saved.hasLoadedList, saved.listError == nil {
                ContentUnavailableView(
                    "No Saved Messages", systemImage: "bookmark",
                    description: Text("Save a message from its menu to keep a snapshot here."))
            }
            ForEach(saved.items) { item in
                NavigationLink {
                    SavedMessageDetailView(
                        store: store, item: item,
                        onOpenSource: { await locate(item) })
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.sender.name ?? "User \(item.sender.uid)").font(.headline)
                            Spacer()
                            Text(item.originalCreatedAt, style: .date)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(summary(item)).lineLimit(3)
                        Text(item.chat.name).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .contextMenu {
                    Button("Open Source", systemImage: "arrow.up.forward") {
                        Task { await locate(item) }
                    }
                    .disabled(!item.canLocateContext || locatingID != nil)
                    Button(
                        "Remove Saved Message", systemImage: "bookmark.slash", role: .destructive
                    ) {
                        Task { _ = await saved.remove(item) }
                    }
                    .disabled(
                        saved.isMutating(
                            chatID: item.originalChatId, messageID: item.originalMessageId))
                }
            }
            if let error = saved.listError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") { Task { await saved.retryList() } }
                }
            } else if saved.nextCursor != nil {
                Button {
                    Task { await saved.loadList(more: true) }
                } label: {
                    HStack {
                        Spacer()
                        if saved.isLoadingList { ProgressView() } else { Text("Load More") }
                        Spacer()
                    }
                }
                .disabled(saved.isLoadingList)
            }
        }
        .navigationTitle("Saved Messages")
        .refreshable { await saved.loadList() }
        .task(id: saved.revision) {
            if !saved.hasLoadedList { await saved.loadList() }
        }
        .alert(
            "Saved Messages",
            isPresented: Binding(
                get: { sourceError != nil || saved.errorMessage != nil },
                set: {
                    if !$0 {
                        sourceError = nil
                        saved.clearError()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                sourceError = nil
                saved.clearError()
            }
        } message: {
            Text(sourceError ?? saved.errorMessage ?? "")
        }
    }

    private func summary(_ item: SavedMessageResponse) -> String {
        if item.messageType == .forwarded { return String(localized: "Forwarded Messages") }
        if let text = item.message, !text.isEmpty { return text }
        if let sticker = item.sticker {
            return "\(sticker.emoji) \(sticker.name ?? String(localized: "Sticker"))"
        }
        if !item.attachments.isEmpty {
            return item.attachments.map(\.fileName).joined(separator: ", ")
        }
        return String(localized: "Saved Message")
    }

    private func locate(_ item: SavedMessageResponse) async {
        guard locatingID == nil else { return }
        guard item.canLocateContext else {
            sourceError = String(
                localized:
                    "The source is no longer accessible. Your saved snapshot is still available.")
            return
        }
        let revision = saved.revision
        locatingID = item.id
        defer { locatingID = nil }
        do {
            let (message, chat) = try await store.resolveMessageLink(
                chatID: item.originalChatId, messageID: item.originalMessageId)
            guard !Task.isCancelled, revision == saved.revision else { return }
            guard !message.isDeleted else {
                sourceError = String(
                    localized:
                        "The source message was removed. Your saved snapshot is still available.")
                return
            }
            onOpenSource(message, chat)
        } catch {
            guard !(error is CancellationError), revision == saved.revision else { return }
            sourceError = String(
                localized:
                    "Couldn’t open the source. It may be unavailable or you may no longer have access. Your saved snapshot is unchanged; try again later."
            )
        }
    }
}

/// A single captured message uses the existing read-only record timeline, with a
/// dedicated cache that never receives edits, recalls or membership events.
private struct SavedMessageDetailView: View {
    let store: ChatStore
    let item: SavedMessageResponse
    let onOpenSource: () async -> Void
    @ObservedObject private var saved: SavedMessageController
    @State private var snapshot: ForwardedRecordSnapshot?
    @State private var openingSource = false
    @State private var presentedGalleryID: UUID?
    @State private var presentedFile: AttachmentResponse?
    @State private var profileUID: Int32?
    @State private var profileChat: ChatListItem?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.imageDetailPresenter) private var imageDetailPresenter

    init(store: ChatStore, item: SavedMessageResponse, onOpenSource: @escaping () async -> Void) {
        self.store = store
        self.item = item
        self.onOpenSource = onOpenSource
        _saved = ObservedObject(wrappedValue: store.savedMessages)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.chat.name).font(.headline)
                Text("Saved \(item.savedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                if !item.canLocateContext {
                    Text("Source unavailable. This is your saved snapshot.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            Divider()
            if item.messageType == .forwarded {
                // Authorization is the saved row, including nested bundles. Never
                // substitute originalChatId/originalMessageId as record authority.
                ForwardedRecordsView(store: store, savedMessageID: item.id)
            } else if let snapshot {
                capturedTimeline(snapshot)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Saved Message")
        .environment(\.chatHeaderInset, 0)
        .environment(\.chatComposerInset, 0)
        .navigationDestination(item: $profileUID) { uid in
            if let currentUserID = store.currentUserProfile?.uid {
                UserProfileView(
                    uid: uid, currentUserID: currentUserID, store: store,
                    onOpenChat: { profileChat = $0 })
            }
        }
        .navigationDestination(item: $profileChat) { chat in
            if let currentUserID = store.currentUserProfile?.uid {
                ChatDetailView(chat: chat, currentUserID: currentUserID, store: store)
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
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { presentedFile = nil }
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open Source", systemImage: "arrow.up.forward") {
                    Task {
                        openingSource = true
                        await onOpenSource()
                        openingSource = false
                    }
                }
                .disabled(!item.canLocateContext || openingSource)
                Button("Remove Saved Message", systemImage: "bookmark.slash", role: .destructive) {
                    Task { _ = await saved.remove(item) }
                }
                .disabled(
                    saved.isMutating(chatID: item.originalChatId, messageID: item.originalMessageId)
                )
            }
        }
        .task(id: saved.revision) {
            guard let uid = store.currentUserProfile?.uid, item.messageType != .forwarded else {
                return
            }
            let revision = saved.revision
            let captured = ForwardedRecordSnapshot(
                response: ForwardedMessagesResponse(total: 1, messages: [item.capturedRecord]),
                currentUserID: uid)
            await captured.timeline.open()
            guard !Task.isCancelled, revision == saved.revision else {
                captured.invalidate()
                return
            }
            snapshot = captured
        }
        .onChange(of: saved.revision) { _, _ in
            snapshot?.invalidate()
            snapshot = nil
            if imageDetailPresenter?.gallery?.id == presentedGalleryID {
                imageDetailPresenter?.dismiss()
            }
            dismiss()
        }
        .onReceive(saved.removedSnapshots) { savedMessageID in
            guard savedMessageID == item.id else { return }
            snapshot?.invalidate()
            snapshot = nil
            if imageDetailPresenter?.gallery?.id == presentedGalleryID {
                imageDetailPresenter?.dismiss()
            }
            dismiss()
        }
        .onDisappear {
            snapshot?.invalidate()
            snapshot = nil
        }
    }

    @ViewBuilder
    private func capturedTimeline(_ snapshot: ForwardedRecordSnapshot) -> some View {
        #if os(macOS)
            ConversationTimelineView(
                model: snapshot.timeline, loadsInitialAutomatically: false,
                actions: actions, interactionContext: readOnlyContext)
        #else
            ConversationTimelineView(
                model: snapshot.timeline, loadsInitialAutomatically: false, actions: actions)
        #endif
    }

    private var readOnlyContext: MessageInteractionContext {
        var context = MessageInteractionContext()
        context.isReadOnly = true
        return context
    }

    private var actions: TimelineBubbleActions {
        var actions = TimelineBubbleActions()
        actions.interactionContext = readOnlyContext
        actions.openMention = { profileUID = $0 }
        actions.openAttachment = { presentedFile = $0 }
        actions.openMedia = { gallery in
            var gallery = gallery
            gallery.conversationTitle = String(localized: "Saved Messages")
            imageDetailPresenter?.present(gallery)
            if imageDetailPresenter?.gallery?.id == gallery.id { presentedGalleryID = gallery.id }
        }
        return actions
    }
}
