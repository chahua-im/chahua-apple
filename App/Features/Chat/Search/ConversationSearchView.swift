import ChahuaAPI
import SwiftUI

/// Presentation-free search content shared by the conversation list on both platforms.
struct ConversationSearchView: View {
    @ObservedObject var model: ConversationSearchModel
    let onClose: () -> Void
    let onOpenChat: (ChatListItem) -> Void
    let onOpenProfile: (Int32) -> Void
    let onOpenInvite: (String) -> Void

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
                searchField
                Divider()
            #endif
            if model.isAvailable {
                if model.normalizedQuery.isEmpty {
                    Text("Enter a group name, username, UID, invite code or invite link")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(24)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 18) {
                                invitesSection
                                chatsSection
                                peopleSection
                                if let error = model.directory.openingError {
                                    Text(error).font(.callout).foregroundStyle(.red)
                                }
                                if model.isEmpty {
                                    Text("No results found")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.vertical, 24)
                                }
                            }
                            .padding(12)
                        }
                        .onChange(of: model.selection) { _, value in
                            if let value { proxy.scrollTo(value, anchor: .center) }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Search unavailable", systemImage: "magnifyingglass",
                    description: Text("Close search and reopen it for your current account."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            model.start()
            #if os(iOS)
                isFieldFocused = true
            #endif
            model.reconcileSelection()
        }
        .onDisappear { model.stop() }
        .onChange(of: model.resultIDs) { _, _ in model.reconcileSelection() }
        #if os(macOS)
            .onExitCommand(perform: onClose)
        #endif
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($isFieldFocused)
                    .accessibilityLabel("Directory search")
                    .onSubmit { openSelection() }
                if !model.query.isEmpty {
                    Button {
                        isFieldFocused = false
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close search")
                }
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isFieldFocused ? Color.accentColor : .clear, lineWidth: 1.5)
            }
            #if os(iOS)
                Button("Cancel", action: onClose)
                    .buttonStyle(.plain)
            #endif
        }
        .padding(12)
    }

    @ViewBuilder
    private var invitesSection: some View {
        let directory = model.directory
        if directory.invite != nil || directory.invitePhase == .loading
            || directory.invitePhase == .failed
        {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Invites")
                if let invite = directory.invite, let code = directory.inviteCode {
                    resultButton(.invite(code)) {
                        HStack(spacing: 10) {
                            AvatarView(
                                url: invite.chat.avatar.flatMap(URL.init(string:)),
                                displayName: invite.chat.name ?? code, diameter: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(invite.chat.name ?? code)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text(code).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "link").foregroundStyle(.secondary)
                        }
                    }
                }
                sectionStatus(
                    directory.invitePhase, failure: "Could not load invite",
                    retry: directory.retryInvite)
            }
        }
    }

    @ViewBuilder
    private var chatsSection: some View {
        let chats = model.chats
        let groups = model.groups
        let hasPages = ConversationSearchModel.Scope.allCases.contains {
            let page = model.state(for: $0)
            return page.isLoading || page.failed || page.hasMore
        }
        let isLoading =
            model.directory.groupsPhase == .loading
            || ConversationSearchModel.Scope.allCases.contains { model.state(for: $0).isLoading }
        if !chats.isEmpty || !groups.isEmpty || hasPages
            || model.directory.groupsPhase == .loading || model.directory.groupsPhase == .failed
        {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Chats")
                ForEach(chats) { chat in
                    resultButton(.chat(chat.id)) {
                        HStack(spacing: 10) {
                            ConversationAvatarView(item: .chat(chat), store: model.store)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(chat.chatDisplayName)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text(
                                    chat.kind == .dm
                                        ? LocalizedStringKey("Direct message") : "Group"
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if chat.archived {
                                Text("Archived")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.quaternary, in: Capsule())
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                    }
                }
                ForEach(groups) { group in
                    resultButton(.group(group.id)) {
                        HStack(spacing: 10) {
                            AvatarView(
                                url: group.avatar.flatMap(URL.init(string:)),
                                displayName: group.name, diameter: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(group.name).font(.headline).foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text("Group").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if model.directory.openingGroupID == group.id { ProgressView() }
                        }
                    }
                    .disabled(model.directory.openingGroupID != nil)
                }
                sectionStatus(
                    model.directory.groupsPhase == .loading ? .idle : model.directory.groupsPhase,
                    failure: "Could not load groups",
                    retry: model.directory.retryGroups)
                if isLoading {
                    ProgressView("Loading chats…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                if model.directory.nextGroupCursor != nil, model.directory.groupsPhase == .loaded {
                    Button("Load more groups") { model.directory.loadMoreGroups() }
                }
                ForEach(ConversationSearchModel.Scope.allCases, id: \.self) { scope in
                    localPageStatus(scope)
                }
            }
        }
    }

    @ViewBuilder
    private var peopleSection: some View {
        let directory = model.directory
        if !directory.people.isEmpty || directory.peoplePhase == .loading
            || directory.peoplePhase == .failed
        {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("People")
                ForEach(directory.people, id: \.uid) { person in
                    resultButton(.person(person.uid)) { SocialUserRow(user: person) }
                }
                sectionStatus(
                    directory.peoplePhase, failure: "Could not load people",
                    retry: directory.retryPeople)
            }
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func sectionStatus(
        _ phase: DirectorySearchModel.Phase, failure: LocalizedStringKey,
        retry: @escaping () -> Void
    ) -> some View {
        if phase == .loading {
            ProgressView("Searching…").frame(maxWidth: .infinity).padding(.vertical, 6)
        } else if phase == .failed {
            HStack {
                Text(failure).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Retry", action: retry)
            }
        }
    }

    @ViewBuilder
    private func localPageStatus(_ scope: ConversationSearchModel.Scope) -> some View {
        let page = model.state(for: scope)
        if page.failed {
            HStack {
                Text(
                    scope.isArchived
                        ? LocalizedStringKey("Could not load archived chats")
                        : "Could not load chats"
                )
                .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Retry") { model.loadMore(in: scope) }
            }
        } else if page.hasMore && !page.isLoading {
            Button(
                scope.isArchived
                    ? LocalizedStringKey("Load more archived chats") : "Load more active chats"
            ) {
                model.loadMore(in: scope)
            }
        }
    }

    private func resultButton<Content: View>(
        _ id: ConversationSearchModel.ResultID, @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            open(id)
        } label: {
            content()
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if model.selection == id {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12))
            }
        }
        .accessibilityAddTraits(model.selection == id ? .isSelected : [])
        .id(id)
    }

    private func openSelection() {
        model.open(
            onOpenChat: onOpenChat, onOpenProfile: onOpenProfile, onOpenInvite: onOpenInvite)
    }

    private func open(_ id: ConversationSearchModel.ResultID) {
        model.open(
            id, onOpenChat: onOpenChat, onOpenProfile: onOpenProfile, onOpenInvite: onOpenInvite)
    }
}
