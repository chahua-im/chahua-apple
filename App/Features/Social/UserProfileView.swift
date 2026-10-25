import ChahuaAPI
import SwiftUI

/// Standalone profile hydration follows the PWA route: UID search, then exact-UID selection.
/// Safety mutations reuse ChatStore so presence, receipts and chat-list authorization invalidate together.
struct UserProfileView: View {
    let uid: Int32
    let currentUserID: Int32
    @ObservedObject var store: ChatStore
    let onOpenChat: (ChatListItem) -> Void

    @State private var user: MemberSummary?
    @State private var relationship: FriendRelationshipResponse?
    @State private var policy: FriendVerificationSettings?
    @State private var verificationMessage = ""
    @State private var loading = false
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var confirmation: SafetyAction?
    @State private var loadRevision = 0
    @State private var reloadPending = false
    @Environment(\.scenePhase) private var scenePhase

    private enum SafetyAction: String, Identifiable {
        case remove = "Remove friend"
        case block = "Block"
        case unblock = "Unblock"
        var id: Self { self }
    }

    var body: some View {
        Form {
            if let user {
                Section {
                    VStack(spacing: 12) {
                        AvatarView(
                            url: user.avatarUrl.flatMap(URL.init(string:)),
                            displayName: user.username ?? String(uid), diameter: 96)
                        Text(user.username ?? String(uid)).font(.title2.bold()).textSelection(
                            .enabled)
                        Text("ID: \(uid)").foregroundStyle(.secondary)
                        if let tag = user.userGroup { Text(tag.name ?? "").font(.caption) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                    Link(
                        "Forum / Personal Space",
                        destination: URL(
                            string:
                                "https://www.shireyishunjian.com/main/home.php?mod=space&uid=\(uid)"
                        )!)
                }
                if uid != currentUserID {
                    relationshipSection
                    if let policy { requestSection(policy) }
                }
            }
            if loading { ProgressView("Loading profile…") }
            if let notice { Text(notice).foregroundStyle(.secondary) }
            if let error {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("Reload profile") { Task { await load() } }.disabled(busy || loading)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Profile")
        .task(id: uid) { await load() }
        .onReceive(store.socialInvalidations) { _ in invalidateProfile() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { invalidateProfile() }
        }
        .confirmationDialog(
            confirmation?.rawValue ?? "",
            isPresented: Binding(
                get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
            ), titleVisibility: .visible
        ) {
            if let confirmation {
                Button(confirmation.rawValue, role: .destructive) {
                    Task { await performSafety(confirmation) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Change your relationship with this user?")
        }
    }

    @ViewBuilder
    private var relationshipSection: some View {
        if let relationship {
            Section("Relationship") {
                if let chatID = relationship.dmChatId {
                    Button("Message", systemImage: "message") { Task { await openChat(chatID) } }
                        .disabled(busy || loading)
                }
                if relationship.isFriend == true {
                    NavigationLink("Friend Privacy") {
                        FriendPrivacySettingsView(store: store, peerUID: uid)
                    }
                    Button("Remove friend", role: .destructive) { confirmation = .remove }
                        .disabled(busy || loading)
                } else if relationship.hasPendingOutgoingRequest == true {
                    Text("Friend request sent — awaiting response").foregroundStyle(.secondary)
                } else if relationship.blocking == true {
                    Text("Unblock this user before sending a friend request.").foregroundStyle(
                        .secondary)
                } else if relationship.blockedBy == true {
                    Text("This user is not accepting requests.").foregroundStyle(.secondary)
                } else {
                    Button("Add Friend", systemImage: "person.badge.plus") {
                        Task { await loadPolicy() }
                    }
                    .disabled(
                        busy || loading || relationship.isFriend == nil
                            || relationship.hasPendingOutgoingRequest == nil)
                }
                if let blocking = relationship.blocking {
                    Button(blocking ? "Unblock" : "Block", role: blocking ? nil : .destructive) {
                        confirmation = blocking ? .unblock : .block
                    }
                    .disabled(busy || loading)
                }
            }
        }
    }

    private func requestSection(_ policy: FriendVerificationSettings) -> some View {
        Section("Friend Request") {
            if policy.mode == .forbid {
                Text("This user is not accepting requests.").foregroundStyle(.secondary)
            } else {
                if policy.mode == .question {
                    Text(policy.question ?? "").font(.headline)
                }
                if policy.mode != .direct {
                    TextField(
                        policy.mode == .question ? "Your answer" : "Verification message",
                        text: $verificationMessage, axis: .vertical)
                    Text("Up to 200 characters").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Send a direct friend request?")
                }
                Button("Send Request") { Task { await sendRequest() } }
                    .disabled(
                        busy || loading || !validMessage
                            || relationship?.hasPendingOutgoingRequest == true)
            }
            Button("Cancel") { self.policy = nil }
                .disabled(busy)
        }
    }

    private var validMessage: Bool {
        policy?.mode == .direct
            || (!verificationMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && verificationMessage.count <= 200)
    }

    private func load() async {
        guard store.currentUserProfile?.uid == currentUserID else { return }
        reloadPending = true
        guard !loading, !busy else { return }
        loading = true
        defer { loading = false }
        repeat {
            reloadPending = false
            let requestRevision = loadRevision
            error = nil
            do {
                let result = try await store.searchUsers(query: String(uid))
                guard let match = result.members.first(where: { $0.uid == uid }) else {
                    throw APIError.unexpectedResponse
                }
                try Task.checkCancellation()
                guard store.currentUserProfile?.uid == currentUserID else { return }
                guard requestRevision == loadRevision else { continue }
                user = match
                let relation: FriendRelationshipResponse?
                if uid == currentUserID {
                    relation = nil
                } else {
                    relation = try await store.friendRelationship(peerUID: uid)
                }
                try Task.checkCancellation()
                guard store.currentUserProfile?.uid == currentUserID else { return }
                guard requestRevision == loadRevision else { continue }
                relationship = relation
                if relation?.isFriend == true || relation?.hasPendingOutgoingRequest == true {
                    policy = nil
                }
            } catch is CancellationError {} catch {
                guard store.currentUserProfile?.uid == currentUserID else { return }
                if requestRevision == loadRevision { self.error = error.localizedDescription }
            }
        } while reloadPending && !Task.isCancelled
    }

    private func invalidateProfile() {
        // Fence the current read synchronously before a queued task can publish a stale
        // friendship. A coalesced trailing read also covers invalidation during mutations.
        loadRevision &+= 1
        relationship = nil
        policy = nil
        reloadPending = true
        Task { await load() }
    }

    private func finishRelationshipAction() {
        busy = false
        if reloadPending { Task { await load() } }
    }

    private func loadPolicy() async {
        guard !busy, store.currentUserProfile?.uid == currentUserID else { return }
        busy = true
        error = nil
        let requestRevision = loadRevision
        defer { finishRelationshipAction() }
        do {
            // Re-read authorization at entry; a historical DM is never evidence of friendship.
            let relation = try await store.friendRelationship(peerUID: uid)
            let policy = try await store.friendAddInfo(uid: uid)
            guard store.currentUserProfile?.uid == currentUserID,
                requestRevision == loadRevision
            else { return }
            relationship = relation
            guard relation.isFriend == false, relation.hasPendingOutgoingRequest == false,
                relation.blocking == false, relation.blockedBy == false
            else {
                notice =
                    "A request is already pending or this relationship cannot accept a new request."
                return
            }
            self.policy = policy
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func sendRequest() async {
        guard !busy, validMessage, let policy, policy.mode != .forbid,
            store.currentUserProfile?.uid == currentUserID
        else { return }
        busy = true
        error = nil
        let requestRevision = loadRevision
        defer { finishRelationshipAction() }
        do {
            let current = try await store.friendRelationship(peerUID: uid)
            guard store.currentUserProfile?.uid == currentUserID,
                requestRevision == loadRevision
            else { return }
            relationship = current
            guard current.isFriend == false, current.hasPendingOutgoingRequest == false,
                current.blocking == false, current.blockedBy == false
            else {
                self.policy = nil
                notice =
                    "A request is already pending or this relationship cannot accept a new request."
                return
            }
            _ = try await store.createFriendRequest(
                toUID: uid,
                message: policy.mode == .direct
                    ? nil : verificationMessage.trimmingCharacters(in: .whitespacesAndNewlines))
            guard store.currentUserProfile?.uid == currentUserID else { return }
            // The committed request must not be repeated if the following refresh fails.
            self.policy = nil
            notice = "Friend request sent"
            relationship = nil
            reloadPending = true
            await store.refreshActiveChats()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func performSafety(_ action: SafetyAction) async {
        guard !busy, store.currentUserProfile?.uid == currentUserID else { return }
        busy = true
        error = nil
        defer { finishRelationshipAction() }
        do {
            switch action {
            case .remove: try await store.removeFriend(peerUID: uid)
            case .block: try await store.setUserBlocked(peerUID: uid, blocked: true)
            case .unblock: try await store.setUserBlocked(peerUID: uid, blocked: false)
            }
            guard store.currentUserProfile?.uid == currentUserID else { return }
            policy = nil
            relationship = nil
            notice = "Relationship updated"
            reloadPending = true
            await store.refreshActiveChats()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func openChat(_ id: String) async {
        guard !busy else { return }
        busy = true
        defer { finishRelationshipAction() }
        do {
            let chat = try await store.socialChat(id: id)
            guard store.currentUserProfile?.uid == currentUserID else { return }
            onOpenChat(chat)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
