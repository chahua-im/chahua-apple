import ChahuaAPI
import SwiftUI

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

/// Standalone profile hydration follows the PWA route: UID search, then exact-UID selection.
/// Safety mutations reuse ChatStore so presence, receipts and chat-list authorization invalidate together.
struct UserProfileView: View {
    let uid: Int32
    let currentUserID: Int32
    @ObservedObject var store: ChatStore
    var isPresentedAsRoot = false
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
    @State private var showsFriendPrivacy = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    private enum SafetyAction: String, Identifiable {
        case remove = "Remove friend"
        case block = "Block"
        case unblock = "Unblock"
        var id: Self { self }
    }

    var body: some View {
        profileSurface
            .navigationTitle("")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(isPresentedAsRoot ? .hidden : .visible, for: .navigationBar)
                .background(ConversationSwipeBack())
            #endif
            .navigationDestination(isPresented: $showsFriendPrivacy) {
                FriendPrivacySettingsView(store: store, peerUID: uid)
                    #if os(iOS)
                        .toolbar(.visible, for: .navigationBar)
                    #endif
            }
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

    private var profileSurface: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let user {
                    profileHero(user)
                    actionCards
                    if uid != currentUserID {
                        relationshipStatus
                        if let policy { requestSection(policy) }
                    }
                }
                if loading {
                    ProgressView("Loading profile…")
                        .frame(maxWidth: .infinity)
                }
                if busy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
                if let notice {
                    Text(notice)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                if let error {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(error).foregroundStyle(.red)
                        Button("Reload profile") { Task { await load() } }
                            .disabled(busy || loading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(cardBackground, in: RoundedRectangle(cornerRadius: 20))
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .padding(.top, isPresentedAsRoot ? 12 : 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(groupedBackground.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            if isPresentedAsRoot {
                HStack {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
            }
        }
    }

    private func profileHero(_ user: MemberSummary) -> some View {
        VStack(spacing: 14) {
            AvatarView(
                url: user.avatarUrl.flatMap(URL.init(string:)),
                displayName: user.username ?? String(uid), diameter: 112
            )
            .overlay {
                Circle().strokeBorder(.white, lineWidth: 4)
            }
            .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
            Text(user.username ?? String(uid))
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if let username = user.username, !username.isEmpty {
                    Text(verbatim: "@\(username)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let name = user.userGroup?.name, !name.isEmpty {
                    Text(name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(profileTint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            profileTint.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    private var actionCards: some View {
        HStack(alignment: .top, spacing: 10) {
            if uid == currentUserID {
                spaceCard
            } else if relationship?.isFriend == true {
                messageCard(primary: true)
                spaceCard
            } else {
                Button {
                    Task { await loadPolicy() }
                } label: {
                    actionCard("Add Friend", symbol: "person.badge.plus", primary: true)
                }
                .buttonStyle(.plain)
                .disabled(!canRequestFriendship)
                messageCard(primary: false)
            }
            Menu {
                Button("Copy ID", systemImage: "doc.on.doc") { copyID() }
                if uid != currentUserID, relationship?.isFriend != true {
                    Link(destination: spaceURL) {
                        Label("Space", systemImage: "globe")
                    }
                }
                if uid != currentUserID {
                    if relationship?.isFriend == true {
                        Button("Friend Privacy", systemImage: "hand.raised") {
                            showsFriendPrivacy = true
                        }
                        .disabled(busy || loading)
                        Button(
                            "Remove friend", systemImage: "person.badge.minus", role: .destructive
                        ) {
                            confirmation = .remove
                        }
                        .disabled(busy || loading)
                    }
                    if let blocking = relationship?.blocking {
                        if blocking {
                            Button("Unblock", systemImage: "hand.raised.slash") {
                                confirmation = .unblock
                            }
                            .disabled(busy || loading)
                        } else {
                            Button("Block", systemImage: "hand.raised", role: .destructive) {
                                confirmation = .block
                            }
                            .disabled(busy || loading)
                        }
                    }
                }
            } label: {
                actionCard("More", symbol: "ellipsis")
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
        }
    }

    private func actionCard(
        _ title: LocalizedStringKey, symbol: String, primary: Bool = false
    ) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(height: 21)
            Text(title)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(primary ? Color.white : Color.accentColor)
        .frame(maxWidth: .infinity, minHeight: 62)
        .padding(.horizontal, 4)
        .background(
            primary ? Color.accentColor : cardBackground,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func messageCard(primary: Bool) -> some View {
        Button {
            if let id = relationship?.dmChatId {
                Task { await openChat(id) }
            }
        } label: {
            actionCard("Message", symbol: "message.fill", primary: primary)
        }
        .buttonStyle(.plain)
        .disabled(busy || loading || relationship?.dmChatId == nil)
    }

    private var spaceCard: some View {
        Link(destination: spaceURL) {
            actionCard("Space", symbol: "globe")
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var relationshipStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let relationship {
                if relationship.blocking == true {
                    Text("Unblock this user before sending a friend request.")
                } else if relationship.blockedBy == true {
                    Text("This user is not accepting requests.")
                } else if relationship.hasPendingOutgoingRequest == true {
                    Text("Friend request sent — awaiting response")
                }
                if relationship.dmChatId == nil {
                    Text("Messaging is unavailable for this user.")
                }
            } else if !loading {
                Text("Relationship unavailable")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canRequestFriendship: Bool {
        !busy && !loading
            && relationship?.isFriend == false
            && relationship?.hasPendingOutgoingRequest == false
            && relationship?.blocking == false
            && relationship?.blockedBy == false
    }

    private var spaceURL: URL {
        URL(string: "https://www.shireyishunjian.com/main/home.php?mod=space&uid=\(uid)")!
    }

    private var profileTint: Color {
        let group = user?.userGroup
        let darkHex = group?.chatGroupColorDark.flatMap { $0.isEmpty ? nil : $0 }
        let hex = colorScheme == .dark ? darkHex ?? group?.chatGroupColor : group?.chatGroupColor
        return hex.flatMap { bubbleColor(hex: $0) }
            ?? bubbleColorForUser(uid: uid, dark: colorScheme == .dark)
    }

    private var groupedBackground: Color {
        #if os(iOS)
            Color(uiColor: .systemGroupedBackground)
        #else
            Color(nsColor: .windowBackgroundColor)
        #endif
    }

    private var cardBackground: Color {
        #if os(iOS)
            Color(uiColor: .secondarySystemGroupedBackground)
        #else
            Color(nsColor: .controlBackgroundColor)
        #endif
    }

    private func copyID() {
        #if os(iOS)
            UIPasteboard.general.string = String(uid)
        #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(uid), forType: .string)
        #endif
        notice = AppLanguage.localized("ID copied")
    }

    private func requestSection(_ policy: FriendVerificationSettings) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Friend Request").font(.headline)
            if policy.mode == .forbid {
                Text("This user is not accepting requests.").foregroundStyle(.secondary)
            } else {
                if policy.mode == .question {
                    Text(policy.question ?? "").font(.headline)
                }
                if policy.mode != .direct {
                    TextField(
                        policy.mode == .question ? "Your answer" : "Verification message",
                        text: $verificationMessage, axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(groupedBackground, in: RoundedRectangle(cornerRadius: 12))
                    Text("Up to 200 characters").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Send a direct friend request?")
                }
                Button("Send Request") { Task { await sendRequest() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        busy || loading || !validMessage
                            || relationship?.hasPendingOutgoingRequest == true)
            }
            Button("Cancel") { self.policy = nil }
                .disabled(busy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 20))
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
        guard !busy, store.currentUserProfile?.uid == currentUserID else { return }
        busy = true
        error = nil
        let requestRevision = loadRevision
        defer { finishRelationshipAction() }
        do {
            let chat = try await store.socialChat(id: id)
            try Task.checkCancellation()
            guard store.currentUserProfile?.uid == currentUserID,
                requestRevision == loadRevision
            else { return }
            onOpenChat(chat)
        } catch is CancellationError {} catch {
            guard store.currentUserProfile?.uid == currentUserID,
                requestRevision == loadRevision
            else { return }
            self.error = error.localizedDescription
        }
    }
}
