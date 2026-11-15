#if os(macOS)
    import SwiftUI

    /// One progress value drives both moving regions, badge cross-fades and titlebar controls.
    /// Keeping both list trees mounted also retains each scope's native scroll position.
    struct MacArchiveSidebar<Header: View, Content: View>: View {
        let isArchived: Bool
        var allowsInteractiveBack = true
        let activeBadges: ConversationTabBadges
        let archivedBadges: ConversationTabBadges
        let badgeColor: ConversationUnreadBadgeColor
        @Binding var selection: ConversationListScope
        let onSearch: () -> Void
        let onBack: () -> Void
        @ViewBuilder let header: (CGFloat) -> Header
        @ViewBuilder let list: (Bool) -> Content
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var progress: CGFloat

        init(
            isArchived: Bool, allowsInteractiveBack: Bool = true,
            activeBadges: ConversationTabBadges, archivedBadges: ConversationTabBadges,
            badgeColor: ConversationUnreadBadgeColor,
            selection: Binding<ConversationListScope>, onSearch: @escaping () -> Void,
            onBack: @escaping () -> Void,
            @ViewBuilder header: @escaping (CGFloat) -> Header,
            @ViewBuilder list: @escaping (Bool) -> Content
        ) {
            self.isArchived = isArchived
            self.allowsInteractiveBack = allowsInteractiveBack
            self.activeBadges = activeBadges
            self.archivedBadges = archivedBadges
            self.badgeColor = badgeColor
            _selection = selection
            self.onSearch = onSearch
            self.onBack = onBack
            self.header = header
            self.list = list
            _progress = State(initialValue: isArchived ? 1 : 0)
        }

        private var animation: Animation {
            .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32)
        }

        var body: some View {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    header(1 - progress)
                    layers(width: geometry.size.width) {
                        MacSidebarSearchButton(onSearch: onSearch)
                            .padding(.horizontal, 14)
                    } archived: {
                        Button(action: onBack) {
                            HStack(spacing: 2) {
                                Image(systemName: "chevron.backward")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.tint)
                                    .frame(width: 26, height: 30)
                                Text("Archived")
                                    .font(.system(size: 16, weight: .bold))
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
                    .frame(height: 30)
                    .padding(.top, 4)
                    .padding(.bottom, 8)

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
                .background {
                    MacSidebarBackGesture(
                        isEnabled: isArchived && allowsInteractiveBack,
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
                if isArchived && allowsInteractiveBack { onBack() }
            }
            .background {
                Button("Back to chats") { onBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!isArchived || !allowsInteractiveBack)
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

    struct MacSidebarSearchButton: View {
        var onSearch: (() -> Void)?

        var body: some View {
            Button {
                onSearch?()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                    Text("Search (⌘K)")
                        .font(.system(size: 13))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(height: 30)
                // Search is a content-sized pill, not an editable native text field.
                // Match the capsule's fill, clipping and hit geometry at every width.
                .background(Color.secondary.opacity(0.1), in: Capsule(style: .circular))
                .contentShape(Capsule(style: .circular))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search conversations")
            .accessibilityIdentifier("sidebar-search")
        }
    }
#endif
