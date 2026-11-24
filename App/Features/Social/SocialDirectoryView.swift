import ChahuaAPI
import SwiftUI

/// The add-friend screen shares the directory's independently retriable server searches.
struct SocialDirectoryView: View {
    let currentUserID: Int32
    @ObservedObject var store: ChatStore
    var usersOnly = false
    let onOpenChat: (ChatListItem) -> Void
    let onOpenProfile: (Int32) -> Void

    @State private var query = ""
    @StateObject private var model: DirectorySearchModel

    init(
        currentUserID: Int32, store: ChatStore, usersOnly: Bool = false,
        onOpenChat: @escaping (ChatListItem) -> Void,
        onOpenProfile: @escaping (Int32) -> Void
    ) {
        self.currentUserID = currentUserID
        self.store = store
        self.usersOnly = usersOnly
        self.onOpenChat = onOpenChat
        self.onOpenProfile = onOpenProfile
        _model = StateObject(
            wrappedValue: DirectorySearchModel(
                currentUserID: currentUserID, store: store,
                includesGroups: !usersOnly, includesInvites: false))
    }

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
            if !usersOnly,
                !model.groups.isEmpty || model.groupsPhase == .loading
                    || model.groupsPhase == .failed
            {
                Section("Chats") {
                    ForEach(model.groups) { group in
                        Button {
                            Task {
                                if let chat = await model.openGroup(group.id) { onOpenChat(chat) }
                            }
                        } label: {
                            HStack {
                                AvatarView(
                                    url: group.avatar.flatMap(URL.init(string:)),
                                    displayName: group.name, diameter: 40)
                                Text(group.name).foregroundStyle(.primary)
                                Spacer()
                                if model.openingGroupID == group.id { ProgressView() }
                            }
                        }
                        .disabled(model.openingGroupID != nil)
                    }
                    if model.groupsPhase == .loading {
                        ProgressView("Searching…")
                    } else if model.groupsPhase == .failed {
                        Text("Could not load groups").foregroundStyle(.secondary)
                        Button("Retry") { model.retryGroups() }
                    } else if model.nextGroupCursor != nil {
                        Button("Load more groups") { model.loadMoreGroups() }
                    }
                }
            }
            if !model.people.isEmpty || model.peoplePhase == .loading
                || model.peoplePhase == .failed
            {
                Section("People") {
                    ForEach(model.people, id: \.uid) { user in
                        Button {
                            guard model.canOpenPerson(user.uid) else { return }
                            onOpenProfile(user.uid)
                        } label: {
                            SocialUserRow(user: user)
                        }
                        .buttonStyle(.plain)
                    }
                    if model.peoplePhase == .loading {
                        ProgressView("Searching…")
                    } else if model.peoplePhase == .failed {
                        Text("Could not load people").foregroundStyle(.secondary)
                        Button("Retry") { model.retryPeople() }
                    }
                }
            }
            if let error = model.openingError { Text(error).foregroundStyle(.red) }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                model.isSettled, model.people.isEmpty, model.groups.isEmpty
            {
                Text("No results found").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(usersOnly ? LocalizedStringKey("Add Friend") : "Directory")
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: query) { _, value in model.search(value) }
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
