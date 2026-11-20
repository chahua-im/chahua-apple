#if os(macOS)
    import ChahuaAPI
    import SwiftUI

    /// The macOS sidebar searches chat titles across both archive scopes rather
    /// than pushing the conversation-scoped message search used inside a chat.
    struct MacSidebarSearchView: View {
        let currentUserID: Int32
        @ObservedObject private var store: ChatStore
        let onSelect: (ChatListItem) -> Void

        @StateObject private var model: MacSidebarSearchModel
        @Environment(\.dismiss) private var dismiss
        @FocusState private var isFieldFocused: Bool

        init(
            currentUserID: Int32, store: ChatStore,
            onSelect: @escaping (ChatListItem) -> Void
        ) {
            self.currentUserID = currentUserID
            self.store = store
            self.onSelect = onSelect
            _model = StateObject(
                wrappedValue: MacSidebarSearchModel(currentUserID: currentUserID, store: store))
        }

        var body: some View {
            VStack(spacing: 0) {
                header
                VoicePlaybackHeaderRow()
                Divider()
                if model.isAvailable {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            resultsSection(.active)
                            resultsSection(.archived)
                        }
                        .padding(16)
                    }
                } else {
                    ContentUnavailableView(
                        "Search unavailable", systemImage: "magnifyingglass",
                        description: Text("Close search and reopen it for your current account."))
                }
            }
            .frame(width: 440, height: 520)
            .task {
                model.start()
                isFieldFocused = true
            }
            .onDisappear { model.stop() }
            .onChange(of: currentUserID) { _, _ in model.stop() }
        }

        private var header: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Search chats")
                        .font(.headline)
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search chat titles", text: $model.query)
                        .textFieldStyle(.plain)
                        .focused($isFieldFocused)
                        .accessibilityLabel("Search chat titles")
                    if !model.query.isEmpty {
                        Button {
                            model.query = ""
                            isFieldFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Text("Active and archived chats, including direct messages. Not message history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }

        private func resultsSection(_ scope: MacSidebarSearchModel.Scope) -> some View {
            let page = model.state(for: scope)
            let results = model.results(in: scope)
            return VStack(alignment: .leading, spacing: 8) {
                Text(scope.isArchived ? "Archived chats" : "Active chats")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(results) { chat in
                    Button {
                        guard model.isAvailable, store.currentUserProfile?.uid == currentUserID
                        else {
                            return
                        }
                        onSelect(chat)
                    } label: {
                        HStack(spacing: 12) {
                            ConversationAvatarView(item: .chat(chat), store: store)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chat.chatDisplayName)
                                    .font(.headline)
                                    .lineLimit(2)
                                Text(chat.kind == .dm ? "Direct message" : "Group")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if page.isLoading {
                    ProgressView("Loading chats…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else if results.isEmpty && !page.failed {
                    Text(
                        page.hasMore
                            ? "No matching chats in loaded pages. Load more to keep searching."
                            : "No matching chats"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                if page.failed {
                    HStack {
                        Text("Could not load chats")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry") { model.loadMore(in: scope) }
                    }
                } else if page.hasMore {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("More chats remain to be searched.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Load More") { model.loadMore(in: scope) }
                            .disabled(page.isLoading)
                    }
                }
            }
        }
    }
#endif
