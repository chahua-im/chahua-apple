import ChahuaAPI
import SwiftUI

struct AccountNotificationPreferencesView: View {
    @ObservedObject var store: ChatStore
    @State private var totals: [ChatKind: Int] = [:]
    @State private var error: String?
    @State private var revision = 0

    var body: some View {
        Group {
            ForEach([ChatKind.dm, .group], id: \.self) { kind in
                NavigationLink {
                    NotificationCategoryView(store: store, kind: kind)
                } label: {
                    HStack {
                        Text(LocalizedStringKey(kind == .dm ? "Direct messages" : "Groups"))
                        Spacer()
                        if let defaults = store.state.notificationDefaults {
                            Text(
                                LocalizedStringKey(
                                    defaults.mutedByDefault(kind: kind) ? "Off" : "On")
                            )
                            .foregroundStyle(.secondary)
                        }
                        if let count = totals[kind] {
                            Text("\(count) exceptions").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let error {
                Text(verbatim: error).foregroundStyle(.red)
                Button("Retry") { Task { await load() } }
            }
        }
        .task { await load() }
        .onReceive(store.notificationPreferenceChanges) { _ in
            Task { await loadCounts() }
        }
    }

    private func load() async {
        do {
            try await store.loadNotificationDefaults()
            error = nil
        } catch is CancellationError { return } catch { self.error = error.localizedDescription }
        await loadCounts()
    }

    private func loadCounts() async {
        revision += 1
        let token = revision
        do {
            async let direct = store.notificationExceptions(kind: .dm, after: nil)
            async let groups = store.notificationExceptions(kind: .group, after: nil)
            let (dmPage, groupPage) = try await (direct, groups)
            guard token == revision else { return }
            totals = [.dm: dmPage.totalCount, .group: groupPage.totalCount]
        } catch is CancellationError {} catch {
            if token == revision { self.error = error.localizedDescription }
        }
    }
}

private struct NotificationCategoryView: View {
    @ObservedObject var store: ChatStore
    let kind: ChatKind
    @State private var exceptions: [NotificationException] = []
    @State private var totalCount: Int?
    @State private var loadedPages = 1
    @State private var nextCursor: String?
    @State private var loading = false
    @State private var saving = false
    @State private var revision = 0
    @State private var error: String?
    @State private var selectedChat: ChatListItem?
    @State private var showsPicker = false
    @State private var confirmsClear = false

    var body: some View {
        Form {
            Section {
                if let defaults = store.state.notificationDefaults {
                    Toggle(
                        "Enable notifications",
                        isOn: Binding(
                            get: { !defaults.mutedByDefault(kind: kind) },
                            set: { enabled in
                                Task { await changeDefault(muted: !enabled) }
                            })
                    )
                    .disabled(store.notificationDefaultsSaving)
                } else {
                    ProgressView()
                }
            }
            Section {
                Button("Add exception") { showsPicker = true }
                if let totalCount { Text("\(totalCount) exceptions").foregroundStyle(.secondary) }
                ForEach(exceptions) { exception in
                    HStack {
                        Button {
                            selectedChat = chat(for: exception)
                        } label: {
                            HStack {
                                AvatarView(
                                    url: (exception.peer?.avatarUrl ?? exception.avatar).flatMap(
                                        URL.init(string:)),
                                    displayName: exception.peer?.username ?? exception.name,
                                    diameter: 40)
                                VStack(alignment: .leading) {
                                    Text(exception.peer?.username ?? exception.name)
                                    Text(
                                        LocalizedStringKey(
                                            exception.muteOverride == true
                                                ? "Always mute" : "Always notify")
                                    )
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button("Remove", role: .destructive) {
                            Task { await restore(exception.chatId) }
                        }
                    }
                }
                if nextCursor != nil {
                    Button("Load More") { Task { await load(more: true) } }
                }
                if loading { ProgressView() }
                if (totalCount ?? 0) > 0 {
                    Button("Delete all exceptions", role: .destructive) { confirmsClear = true }
                }
            } header: {
                Text("Exceptions")
            }
            if let error {
                Section {
                    Text(verbatim: error).foregroundStyle(.red)
                    Button("Retry") { Task { await load() } }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(LocalizedStringKey(kind == .dm ? "Direct messages" : "Groups"))
        .disabled(saving)
        .task {
            do { try await store.loadNotificationDefaults() } catch is CancellationError {
                return
            } catch { self.error = error.localizedDescription }
            await load()
        }
        .onReceive(store.notificationPreferenceChanges) { _ in Task { await load() } }
        .refreshable { await load() }
        .sheet(item: $selectedChat) { chat in
            NavigationStack { ChatNotificationSettingsView(store: store, chat: chat) }
                .frame(minWidth: 320, minHeight: 420)
        }
        .sheet(isPresented: $showsPicker) {
            NavigationStack {
                NotificationExceptionPicker(store: store, kind: kind)
            }
            .frame(minWidth: 320, minHeight: 420)
        }
        .confirmationDialog(
            "Remove all notification exceptions?", isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("Delete all exceptions", role: .destructive) {
                Task {
                    saving = true
                    defer { saving = false }
                    do {
                        try await store.clearNotificationExceptions(kind: kind)
                    } catch is CancellationError {} catch {
                        self.error = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func chat(for exception: NotificationException) -> ChatListItem {
        ChatListItem(
            id: exception.chatId, name: exception.name, avatar: exception.avatar,
            unreadCount: 0, mutedUntil: exception.mutedUntil, muteOverride: exception.muteOverride,
            isMuted: exception.isMuted, archived: exception.archived, kind: exception.kind,
            peer: exception.peer)
    }

    private func load(more: Bool = false) async {
        if more && loading { return }
        revision += 1
        let token = revision
        loading = true
        defer { if token == revision { loading = false } }
        do {
            let depth = more ? 1 : loadedPages
            var cursor = more ? nextCursor : nil
            var rows: [NotificationException] = []
            var count = 0
            for _ in 0..<depth {
                let page = try await store.notificationExceptions(kind: kind, after: cursor)
                guard token == revision else { return }
                rows += page.exceptions
                count = page.totalCount
                cursor = page.nextCursor
                if cursor == nil { break }
            }
            if more {
                let ids = Set(exceptions.map(\.chatId))
                exceptions += rows.filter { !ids.contains($0.chatId) }
                loadedPages += 1
            } else {
                exceptions = rows
            }
            nextCursor = cursor
            totalCount = count
            error = nil
        } catch is CancellationError {} catch {
            if token == revision { self.error = error.localizedDescription }
        }
    }

    private func changeDefault(muted: Bool) async {
        do {
            try await store.setNotificationDefault(kind: kind, muted: muted)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func restore(_ chatID: String) async {
        saving = true
        defer { saving = false }
        do {
            try await store.setNotificationSetting(chatID: chatID, request: .init(mode: .inherit))
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

private struct NotificationExceptionPicker: View {
    @ObservedObject var store: ChatStore
    let kind: ChatKind
    @State private var query = ""
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(
                (store.state.chats + store.state.archivedChats).filter {
                    $0.kind == kind
                        && (query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || "\($0.chatDisplayName) \($0.peer?.uid.description ?? "")"
                                .localizedCaseInsensitiveContains(
                                    query.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            ) { chat in
                Button(chat.chatDisplayName) {
                    guard !saving, let defaults = store.state.notificationDefaults else { return }
                    saving = true
                    Task {
                        defer { saving = false }
                        do {
                            try await store.setNotificationSetting(
                                chatID: chat.id,
                                request: .init(
                                    mode: defaults.mutedByDefault(kind: kind)
                                        ? .alwaysUnmuted : .alwaysMuted))
                            dismiss()
                        } catch is CancellationError {} catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
            }
            if store.state.isRefreshingChats || store.state.isRefreshingArchivedChats {
                ProgressView()
            }
            if store.state.chatListLoadPhase == .failed
                || store.state.archivedChatListLoadPhase == .failed
            {
                Button("Retry") { Task { await loadChats() } }
            }
            if let error { Text(verbatim: error).foregroundStyle(.red) }
        }
        .navigationTitle("Add exception")
        .searchable(text: $query, prompt: "Search")
        .disabled(saving || store.state.notificationDefaults == nil)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .task { await loadChats() }
    }

    private func loadChats() async {
        async let active: Void = store.loadActiveChats()
        async let archived: Void = store.loadArchivedChats()
        _ = await (active, archived)
    }
}
