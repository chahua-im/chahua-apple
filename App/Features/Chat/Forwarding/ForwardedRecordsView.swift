import ChahuaAPI
import SwiftUI

/// Read-only captured records rendered by the same timeline as a conversation.
/// Child navigation shares root authority and leaves the underlying chat intact.
struct ForwardedRecordsView: View {
    @StateObject private var session: ForwardedRecordsSession
    private let key: ForwardedRecordsSession.Key
    @State private var childBundleID: String?
    @State private var presentedGalleryID: UUID?
    @State private var profileUID: Int32?
    @State private var profileChat: ChatListItem?
    @State private var presentedFile: AttachmentResponse?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.imageDetailPresenter) private var imageDetailPresenter
    @Environment(\.openURL) private var openURL

    init(
        store: ChatStore, chatID: String, messageID: MessageID, bundleID: String? = nil
    ) {
        _session = StateObject(
            wrappedValue: ForwardedRecordsSession(
                store: store, root: .chat(chatID: chatID, messageID: messageID)))
        key = .init(bundleID: bundleID)
    }

    init(store: ChatStore, savedMessageID: String, bundleID: String? = nil) {
        _session = StateObject(
            wrappedValue: ForwardedRecordsSession(
                store: store, root: .saved(messageID: savedMessageID)))
        key = .init(bundleID: bundleID)
    }

    private init(session: ForwardedRecordsSession, bundleID: String) {
        _session = StateObject(wrappedValue: session)
        key = .bundle(bundleID)
    }

    var body: some View {
        content
            .environment(\.chatHeaderInset, 0)
            .environment(\.chatComposerInset, 0)
            .navigationTitle("Forwarded Messages")
            #if os(iOS)
                .toolbar(.visible, for: .navigationBar)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(item: $childBundleID) { bundleID in
                ForwardedRecordsView(session: session, bundleID: bundleID)
            }
            .navigationDestination(item: $profileUID) { uid in
                if let currentUserID = session.store.currentUserProfile?.uid {
                    UserProfileView(
                        uid: uid, currentUserID: currentUserID,
                        store: session.store, onOpenChat: { profileChat = $0 })
                }
            }
            .navigationDestination(item: $profileChat) { chat in
                if let uid = session.store.currentUserProfile?.uid {
                    ChatDetailView(chat: chat, currentUserID: uid, store: session.store)
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
            .task(id: session.revision) {
                session.load(key)
            }
            .onAppear {
                session.setSceneActive(scenePhase == .active)
            }
            .onChange(of: scenePhase) { _, phase in
                session.setSceneActive(phase == .active)
            }
            .onChange(of: session.revision) { _, _ in
                if imageDetailPresenter?.gallery?.id == presentedGalleryID {
                    imageDetailPresenter?.dismiss()
                }
                presentedGalleryID = nil
            }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase(for: key) {
        case .loading:
            ProgressView("Loading forwarded messages…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            VStack(spacing: ChahuaTheme.Spacing.small) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text("Couldn’t load forwarded messages").font(.headline)
                Text("Check your connection and try again.")
                    .foregroundStyle(ChahuaTheme.secondaryText)
                Button("Retry") { session.load(key, retry: true) }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            VStack(spacing: ChahuaTheme.Spacing.small) {
                Image(systemName: "lock.doc").font(.largeTitle)
                Text("Forwarded messages unavailable").font(.headline)
                Text("These forwarded messages are no longer available or you don’t have access.")
                    .foregroundStyle(ChahuaTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let snapshot):
            timeline(snapshot)
        }
    }

    @ViewBuilder
    private func timeline(_ snapshot: ForwardedRecordSnapshot) -> some View {
        #if os(macOS)
            ConversationTimelineView(
                model: snapshot.timeline, loadsInitialAutomatically: false,
                actions: actions(for: snapshot), interactionContext: readOnlyContext)
        #else
            ConversationTimelineView(
                model: snapshot.timeline, loadsInitialAutomatically: false,
                actions: actions(for: snapshot))
        #endif
    }

    private var readOnlyContext: MessageInteractionContext {
        var context = MessageInteractionContext()
        context.isReadOnly = true
        return context
    }

    private func actions(for snapshot: ForwardedRecordSnapshot) -> TimelineBubbleActions {
        var actions = TimelineBubbleActions()
        actions.interactionContext = readOnlyContext
        actions.openMention = { profileUID = $0 }
        actions.openAttachment = { attachment in
            guard case .ready(let current) = session.phase(for: key), current === snapshot
            else { return }
            presentedFile = attachment
        }
        if let imageDetailPresenter {
            actions.openMedia = { gallery in
                guard case .ready(let current) = session.phase(for: key), current === snapshot
                else {
                    return
                }
                var gallery = gallery
                gallery.conversationTitle = String(localized: "Forwarded Messages")
                imageDetailPresenter.present(gallery)
                if imageDetailPresenter.gallery?.id == gallery.id {
                    presentedGalleryID = gallery.id
                }
            }
        }
        actions.openReply = { messageID in
            guard case .ready(let current) = session.phase(for: key), current === snapshot,
                snapshot.messageIDs.contains(messageID)
            else { return }
            Task { await snapshot.timeline.jumpToMessage(messageID) }
        }
        actions.openForwardedMessages = { message in
            guard case .ready(let current) = session.phase(for: key), current === snapshot,
                message.messageType == .forwarded,
                let bundleID = message.forwardedBundleId,
                snapshot.childBundleIDs.contains(bundleID)
            else { return }
            childBundleID = bundleID
        }
        return actions
    }
}
