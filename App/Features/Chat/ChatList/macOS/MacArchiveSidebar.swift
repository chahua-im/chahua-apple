#if os(macOS)
    import SwiftUI

    /// One progress value drives both moving regions, badge cross-fades and titlebar controls.
    /// Keeping both list trees mounted also retains each scope's native scroll position.
    struct MacArchiveSidebar<Header: View, Content: View, SearchField: View, Search: View>: View {
        let isArchived: Bool
        var allowsInteractiveBack = true
        var isSearching = false
        let activeBadges: ConversationTabBadges
        let archivedBadges: ConversationTabBadges
        let badgeColor: ConversationUnreadBadgeColor
        @Binding var selection: ConversationListScope
        @ViewBuilder let searchField: () -> SearchField
        let onBack: () -> Void
        @ViewBuilder let header: (CGFloat) -> Header
        @ViewBuilder let list: (Bool) -> Content
        @ViewBuilder let search: () -> Search
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var progress: CGFloat

        init(
            isArchived: Bool, allowsInteractiveBack: Bool = true, isSearching: Bool = false,
            activeBadges: ConversationTabBadges, archivedBadges: ConversationTabBadges,
            badgeColor: ConversationUnreadBadgeColor,
            selection: Binding<ConversationListScope>,
            onBack: @escaping () -> Void,
            @ViewBuilder searchField: @escaping () -> SearchField,
            @ViewBuilder header: @escaping (CGFloat) -> Header,
            @ViewBuilder list: @escaping (Bool) -> Content,
            @ViewBuilder search: @escaping () -> Search
        ) {
            self.isArchived = isArchived
            self.allowsInteractiveBack = allowsInteractiveBack
            self.isSearching = isSearching
            self.activeBadges = activeBadges
            self.archivedBadges = archivedBadges
            self.badgeColor = badgeColor
            _selection = selection
            self.searchField = searchField
            self.onBack = onBack
            self.header = header
            self.list = list
            self.search = search
            _progress = State(initialValue: isArchived ? 1 : 0)
        }

        private var animation: Animation {
            .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32)
        }

        var body: some View {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    header(isSearching ? 1 : 1 - progress)
                    // One mounted input owns both states; only the content below it changes.
                    ZStack(alignment: .leading) {
                        searchField()
                            .padding(.horizontal, 14)
                            .opacity(isArchived && !isSearching ? 0 : 1)
                            .allowsHitTesting(!isArchived || isSearching)
                            .accessibilityHidden(isArchived && !isSearching)
                        if isArchived && !isSearching {
                            Button(action: onBack) {
                                HStack(spacing: 2) {
                                    Image(systemName: "chevron.backward")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(.tint)
                                        .frame(width: 26, height: 30)
                                    Text("Archived").font(.system(size: 16, weight: .bold))
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 6)
                            .padding(.trailing, 14)
                            .accessibilityLabel("Back to chats")
                            .accessibilityIdentifier("archived-back")
                        }
                    }
                    .frame(height: 30)
                    .padding(.top, 4)
                    .padding(.bottom, 8)

                    ZStack(alignment: .top) {
                        VStack(spacing: 0) {
                            // The picker itself never transitions. Its paired badges reserve the
                            // larger width before either count fades, keeping labels stationary.
                            ConversationScopePicker(
                                selection: $selection, badges: activeBadges, badgeColor: badgeColor,
                                archivedBadges: archivedBadges, archiveProgress: progress
                            )
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)

                            layers(width: geometry.size.width) {
                                list(false)
                            } archived: {
                                list(true)
                            }
                        }
                        .opacity(isSearching ? 0 : 1)
                        .allowsHitTesting(!isSearching)
                        .accessibilityHidden(isSearching)
                        if isSearching { search() }
                    }
                }
                .background {
                    MacSidebarBackGesture(
                        isEnabled: isArchived && allowsInteractiveBack && !isSearching,
                        onChange: { distance in
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                progress = 1 - min(1, max(0, distance / geometry.size.width))
                            }
                        },
                        onFinish: { committed in
                            withAnimation(animation) { progress = isArchived ? 1 : 0 }
                            if committed { onBack() }
                        })
                }
            }
            .onChange(of: isArchived) { _, archived in
                withAnimation(animation) { progress = archived ? 1 : 0 }
            }
            .onExitCommand {
                if isArchived && allowsInteractiveBack && !isSearching { onBack() }
            }
            .background {
                Button("Back to chats") { onBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!isArchived || !allowsInteractiveBack || isSearching)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }

        private func layers<Active: View, Archived: View>(
            width: CGFloat, @ViewBuilder active: () -> Active,
            @ViewBuilder archived: () -> Archived
        ) -> some View {
            ZStack(alignment: .topLeading) {
                active()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .offset(x: reduceMotion ? 0 : -0.3 * width * progress)
                    .opacity(1 - progress)
                    .allowsHitTesting(!isArchived)
                    .accessibilityHidden(isArchived)
                archived()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .offset(x: reduceMotion ? 0 : width * (1 - progress))
                    .opacity(progress)
                    .allowsHitTesting(isArchived)
                    .accessibilityHidden(!isArchived)
            }
            .clipped()
        }
    }

    struct MacSidebarSearchField: View {
        @Binding var query: String
        let isSearching: Bool
        let focusRequest: Int
        let onActivate: () -> Void
        let onClose: () -> Void
        let onSubmit: () -> Void
        let onMoveSelection: (Int) -> Void
        @FocusState private var isFocused: Bool

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                TextField("Search (⌘K)", text: $query)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .focused($isFocused)
                    .accessibilityLabel("Search conversations")
                    .accessibilityIdentifier("sidebar-search")
                    .onSubmit(onSubmit)
                    .onKeyPress(.upArrow) {
                        guard isSearching else { return .ignored }
                        onMoveSelection(-1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard isSearching else { return .ignored }
                        onMoveSelection(1)
                        return .handled
                    }
                Button(action: cancelSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityLabel("Close search")
                .accessibilityIdentifier("sidebar-search-cancel")
                .help("Close search")
                // Reserve the same space before activation so the input never resizes.
                .opacity(isSearching ? 1 : 0)
                .allowsHitTesting(isSearching)
                .accessibilityHidden(!isSearching)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(
                isSearching ? Color(nsColor: .textBackgroundColor) : Color.secondary.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isFocused ? Color.accentColor : .clear, lineWidth: 1.5)
            }
            .onAppear {
                if isSearching { isFocused = true }
            }
            .onChange(of: isFocused) { _, focused in
                if focused && !isSearching { onActivate() }
            }
            .onChange(of: isSearching) { _, searching in isFocused = searching }
            .onChange(of: focusRequest) { _, _ in isFocused = true }
            .onExitCommand(perform: cancelSearch)
        }

        private func cancelSearch() {
            isFocused = false
            onClose()
        }
    }
#endif
