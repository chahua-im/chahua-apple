import ChahuaAPI
import SwiftUI

struct BlockedUsersView: View {
    let currentUserID: Int32
    @ObservedObject var store: ChatStore
    let onOpenProfile: (Int32) -> Void
    @State private var users: [BlockedUser] = []
    @State private var loading = false
    @State private var error: String?
    @State private var loaded = false
    @State private var revision = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            if loading { ProgressView("Loading blocked users…") }
            if let error {
                Text(error).foregroundStyle(.red)
                Button("Retry") { Task { await load() } }
            }
            ForEach(users) { block in
                Button {
                    onOpenProfile(block.user.uid)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        SocialUserRow(user: block.user)
                        Text(block.since, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            if loaded && users.isEmpty && error == nil && !loading {
                Text("No blocked users").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Blocked Users")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .refreshable { await load() }
        .onReceive(store.socialInvalidations) { _ in
            revision &+= 1
            loading = true
            Task { await load() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } }
        }
    }

    private func load() async {
        guard store.currentUserProfile?.uid == currentUserID else { return }
        revision &+= 1
        let requestRevision = revision
        loading = true
        error = nil
        defer { if revision == requestRevision { loading = false } }
        do {
            let response = try await store.blockedUsers()
            try Task.checkCancellation()
            guard revision == requestRevision, store.currentUserProfile?.uid == currentUserID else {
                return
            }
            users = response.blocks
            loaded = true
        } catch is CancellationError {} catch {
            guard revision == requestRevision, store.currentUserProfile?.uid == currentUserID else {
                return
            }
            self.error = error.localizedDescription
        }
    }
}

/// Direct Settings row uses the same authoritative block resource as the index.
/// A failed count is explicitly unavailable rather than a fabricated zero.
struct BlockedUsersSettingsLink: View {
    let currentUserID: Int32
    @ObservedObject var store: ChatStore
    @State private var count: Int?
    @State private var loading = false
    @State private var failed = false
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: SettingsPage.blockedUsers) {
                HStack {
                    SettingsPageLabel(page: .blockedUsers)
                    Spacer()
                    if loading {
                        ProgressView().controlSize(.small)
                    } else if failed {
                        Text("Unavailable").foregroundStyle(.secondary)
                    } else if let count {
                        Text(count.formatted()).foregroundStyle(.secondary)
                    }
                }
            }
            if failed {
                Button("Retry blocked-user count") { Task { await loadCount() } }
                    .font(.caption)
            }
        }
        .task(id: store.currentUserProfile?.uid) { await loadCount() }
        .onReceive(store.socialInvalidations) { _ in
            revision &+= 1
            count = nil
            loading = true
            Task { await loadCount() }
        }
    }

    private func loadCount() async {
        guard store.currentUserProfile?.uid == currentUserID else {
            count = nil
            return
        }
        revision &+= 1
        let requestRevision = revision
        loading = true
        failed = false
        defer { if revision == requestRevision { loading = false } }
        do {
            let response = try await store.blockedUsers()
            try Task.checkCancellation()
            guard revision == requestRevision, store.currentUserProfile?.uid == currentUserID else {
                return
            }
            count = response.blocks.count
        } catch is CancellationError {} catch {
            guard revision == requestRevision, store.currentUserProfile?.uid == currentUserID else {
                return
            }
            count = nil
            failed = true
        }
    }
}
