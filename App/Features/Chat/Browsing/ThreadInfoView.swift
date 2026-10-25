import ChahuaAPI
import SwiftUI

struct ThreadInfoView: View {
    @ObservedObject var store: ChatStore
    let chat: ChatListItem
    let threadID: String
    @ObservedObject var timeline: ConversationTimelineModel
    let onOpenMessage: (MessageResponse) -> Void

    var body: some View {
        let scope = ThreadInfoScope(
            storeID: ObjectIdentifier(store), accountUID: store.currentUserProfile?.uid,
            chatID: chat.id, threadID: threadID)
        ThreadInfoContent(
            store: store, chat: chat, threadID: threadID, timeline: timeline,
            onOpenMessage: onOpenMessage, scope: scope
        )
        .id(scope)
    }
}

private struct ThreadInfoScope: Hashable {
    let storeID: ObjectIdentifier
    let accountUID: Int32?
    let chatID: String
    let threadID: String
}

/// Participant pages are authoritative; cached messages are used only for the root preview.
private struct ThreadInfoContent: View {
    @ObservedObject var store: ChatStore
    let chat: ChatListItem
    let threadID: String
    @ObservedObject var timeline: ConversationTimelineModel
    let onOpenMessage: (MessageResponse) -> Void
    let scope: ThreadInfoScope
    @Environment(\.openUserProfile) private var openUserProfile
    @State private var fetchedRoot: MessageResponse?
    @State private var rootFailed = false
    @State private var rootRequest = 0
    @State private var participants: [User] = []
    @State private var participantCursor: Int32?
    @State private var participantsLoaded = false
    @State private var participantLoadID: UUID?
    @State private var participantFailure: String?
    @State private var participantRequest = 0

    private var isCurrentAccount: Bool {
        ObjectIdentifier(store) == scope.storeID
            && store.currentUserProfile?.uid == scope.accountUID
    }

    private var cached: ThreadListItem? {
        let matches: (ThreadListItem) -> Bool = {
            $0.chatId == chat.id && $0.threadRootMessage.id.description == threadID
        }
        return store.state.threads.first(where: matches)
            ?? store.state.archivedThreads.first(where: matches)
    }

    private var root: MessageResponse? {
        timeline.rows.lazy.compactMap { row -> MessageResponse? in
            guard case .message(let messageRow) = row else { return nil }
            guard let message = messageRow.entry.presentationMessage else { return nil }
            return message.chatId == chat.id && message.id.description == threadID
                ? message : nil
        }.first ?? fetchedRoot
    }

    var body: some View {
        List {
            Section("Thread") {
                if let root {
                    MessageSummaryText(root.replyPreview, color: .primary, lineLimit: 4)
                } else if let preview = cached?.threadRootMessage {
                    MessageSummaryText(preview, color: .primary, lineLimit: 4)
                } else if rootFailed {
                    Button("Couldn’t load thread root. Retry") { rootRequest += 1 }
                } else {
                    ProgressView("Loading thread…")
                }
            }
            Section {
                ForEach(participants, id: \.uid) { user in
                    Button {
                        openUserProfile(user.uid)
                    } label: {
                        HStack(spacing: 12) {
                            AvatarView(
                                url: user.avatarUrl.flatMap(URL.init(string:)),
                                displayName: user.name ?? "User \(user.uid)", diameter: 40)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(user.name ?? "User \(user.uid)")
                                Text("UID: \(user.uid)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(
                                .secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if participantLoadID != nil || (!participantsLoaded && participantFailure == nil) {
                    ProgressView("Loading participants…")
                } else if let participantFailure {
                    Text(participantFailure).foregroundStyle(.secondary)
                    Button("Retry") { participantRequest += 1 }
                } else if participantsLoaded && participants.isEmpty {
                    Text("No participants").foregroundStyle(.secondary)
                } else if participantCursor != nil {
                    Button("Load More Participants") { participantRequest += 1 }
                } else if participantsLoaded {
                    Text("All participants loaded").font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Participants")
            }
            Section("Parent Chat Attachments") {
                Text("These sections include the whole parent chat, not only this thread.")
                    .font(.footnote).foregroundStyle(.secondary)
                attachmentLink("Images", kind: .image)
                attachmentLink("Videos", kind: .video)
                attachmentLink("Files", kind: .other)
            }
        }
        .navigationTitle("Thread Info")
        .task(id: rootRequest) { await loadRoot() }
        .task(id: participantRequest) { await loadParticipants() }
    }

    private func attachmentLink(_ title: LocalizedStringKey, kind: ChatAttachmentKind) -> some View
    {
        NavigationLink {
            ChatAttachmentsView(
                store: store, chatID: chat.id, kind: kind, onOpenMessage: onOpenMessage)
        } label: {
            Text(title)
        }
    }

    private func loadRoot() async {
        guard root == nil, isCurrentAccount, !Task.isCancelled else { return }
        rootFailed = false
        do {
            let response = try await store.threadRoot(
                for: .init(chatID: chat.id, threadID: threadID))
            try Task.checkCancellation()
            guard isCurrentAccount else { return }
            fetchedRoot = response
        } catch is CancellationError {
        } catch {
            guard isCurrentAccount, !Task.isCancelled else { return }
            rootFailed = true
        }
    }

    private func loadParticipants() async {
        guard isCurrentAccount, !Task.isCancelled,
            !participantsLoaded || participantCursor != nil
        else { return }
        let loadID = UUID()
        participantLoadID = loadID
        participantFailure = nil
        defer {
            if participantLoadID == loadID { participantLoadID = nil }
        }
        do {
            let page = try await store.threadParticipants(
                chatID: chat.id, threadID: threadID, cursor: participantCursor)
            try Task.checkCancellation()
            guard isCurrentAccount, participantLoadID == loadID else { return }
            var knownUIDs = Set(participants.lazy.map(\.uid))
            for user in page.participants where knownUIDs.insert(user.uid).inserted {
                participants.append(user)
            }
            participantCursor = page.nextCursor
            participantsLoaded = true
        } catch is CancellationError {
        } catch {
            guard isCurrentAccount, !Task.isCancelled, participantLoadID == loadID else { return }
            switch error {
            case APIError.http(status: 404, body: _):
                participantFailure = AppLanguage.localized("This thread is no longer available.")
            case APIError.http(status: 403, body: _):
                participantFailure = AppLanguage.localized("You don’t have access to this thread.")
            default:
                participantFailure = AppLanguage.localized("Couldn’t load participants.")
            }
        }
    }
}
