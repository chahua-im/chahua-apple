import ChahuaAPI
import SwiftUI

/// Searches users and joined groups, not message history. User results are a bounded server search;
/// only the group contract provides a continuation cursor.
struct SocialDirectoryView: View {
    let currentUserID: Int32
    @ObservedObject var store: ChatStore
    var usersOnly = false
    let onOpenChat: (ChatListItem) -> Void
    let onOpenProfile: (Int32) -> Void

    @State private var query = ""
    @State private var users: [MemberSummary] = []
    @State private var groups: [SocialGroupSummary] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var opening = false
    @State private var error: String?
    @State private var revision = 0

    var body: some View {
        List {
            Section {
                TextField("Name or user ID", text: $query)
                    .accessibilityLabel("Directory search")
            } footer: {
                Text(
                    usersOnly
                        ? "Find a user to inspect their profile and add as a friend."
                        : "Search people and groups you have joined. This does not search message history."
                )
            }
            if loading && users.isEmpty && groups.isEmpty { ProgressView("Searching…") }
            if let error {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") { Task { await search() } }
                }
            }
            if !users.isEmpty {
                Section("People") {
                    ForEach(users, id: \.uid) { user in
                        Button {
                            onOpenProfile(user.uid)
                        } label: {
                            SocialUserRow(user: user)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !usersOnly && !groups.isEmpty {
                Section("Joined Groups") {
                    ForEach(groups) { group in
                        Button {
                            Task { await open(group.id) }
                        } label: {
                            HStack {
                                AvatarView(
                                    url: group.avatar.flatMap(URL.init(string:)),
                                    displayName: group.name, diameter: 40)
                                Text(group.name).foregroundStyle(.primary)
                            }
                        }
                        .disabled(opening)
                    }
                    if cursor != nil {
                        Button("Load more groups") { Task { await search(more: true) } }
                            .disabled(loading)
                    }
                }
            }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !loading, error == nil, users.isEmpty, groups.isEmpty
            {
                Text("No results").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(usersOnly ? "Add Friend" : "Directory")
        .task(id: query) {
            do {
                try await Task.sleep(for: .milliseconds(250))
                await search()
            } catch {}
        }
    }

    private func search(more: Bool = false) async {
        guard store.currentUserProfile?.uid == currentUserID else { return }
        revision &+= 1
        let requestRevision = revision
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !more {
            users = []
            groups = []
            cursor = nil
        }
        error = nil
        guard !term.isEmpty else {
            loading = false
            return
        }
        loading = true
        defer { if revision == requestRevision { loading = false } }
        do {
            async let people: SearchUsersResponse? = more ? nil : store.searchUsers(query: term)
            async let joined: SocialGroupsResponse? =
                usersOnly ? nil : store.searchJoinedGroups(query: term, after: more ? cursor : nil)
            let (userPage, groupPage) = try await (people, joined)
            try Task.checkCancellation()
            guard revision == requestRevision, store.currentUserProfile?.uid == currentUserID,
                query.trimmingCharacters(in: .whitespacesAndNewlines) == term
            else { return }
            if let userPage { users = userPage.members }
            if let groupPage {
                let existing = Set(groups.map(\.id))
                groups += groupPage.groups.filter { !existing.contains($0.id) }
                cursor = groupPage.nextCursor
            }
        } catch {
            guard revision == requestRevision, store.currentUserProfile?.uid == currentUserID,
                !(error is CancellationError), !Task.isCancelled
            else { return }
            self.error = error.localizedDescription
        }
    }

    private func open(_ id: String) async {
        guard !opening else { return }
        opening = true
        defer { opening = false }
        do {
            let chat = try await store.socialChat(id: id)
            guard store.currentUserProfile?.uid == currentUserID else { return }
            onOpenChat(chat)
        } catch { self.error = error.localizedDescription }
    }
}

struct SocialUserRow: View {
    let user: MemberSummary
    var body: some View {
        HStack(spacing: 12) {
            AvatarView(
                url: user.avatarUrl.flatMap(URL.init(string:)),
                displayName: user.username ?? String(user.uid), diameter: 40)
            VStack(alignment: .leading) {
                Text(user.username ?? String(user.uid)).foregroundStyle(.primary)
                Text("ID: \(user.uid)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
