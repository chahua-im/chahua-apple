#if os(iOS)
    import ChahuaAPI
    import SwiftUI

    // iOS uses a pushed settings hierarchy so phones and iPads retain native back navigation.
    // A single SwiftUI settings form cannot provide the separate category destinations.
    struct IOSSettingsNavigationView: View {
        let settings: NotificationSettingsView
        @State private var protectsEditorEdits = false
        @State private var compactTitleOpacity: Double = 0
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                List {
                    settings.accountSummary(transitionTarget: compactTitleOpacity < 0.5)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(
                            !settings.usesHeroLayout
                                ? nil
                                : EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
                        )
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: OwnProfileHeroBottomKey.self,
                                    value: geometry.frame(in: .named("own-profile-scroll")).maxY)
                            }
                        }
                    Section {
                        NavigationLink(value: SettingsPage.savedMessages) {
                            SettingsPageLabel(page: .savedMessages)
                        }
                    }
                    Section("General") {
                        ForEach(SettingsPage.generalPages) { page in
                            NavigationLink(value: page) {
                                SettingsPageLabel(page: page)
                            }
                        }
                    }
                    Section("Privacy and Security") {
                        ForEach(SettingsPage.privacyPages) { page in
                            if page == .blockedUsers {
                                settings.blockedUsersRow
                            } else {
                                NavigationLink(value: page) {
                                    SettingsPageLabel(page: page)
                                }
                            }
                        }
                    }
                    Section("Stickers") {
                        ForEach(SettingsPage.stickerPages) { page in
                            NavigationLink(value: page) {
                                SettingsPageLabel(page: page)
                            }
                        }
                    }
                    Section("Notifications") {
                        NavigationLink(value: SettingsPage.notifications) {
                            SettingsPageLabel(page: .notifications)
                        }
                    }
                    Section {
                        settings.signOutRow
                    }
                }
                .listStyle(.insetGrouped)
                .coordinateSpace(name: "own-profile-scroll")
                .onPreferenceChange(OwnProfileHeroBottomKey.self) { bottom in
                    guard let bottom else { return }
                    compactTitleOpacity = Double(min(1, max(0, (44 - bottom) / 44)))
                }
                .contentMargins(
                    .top, settings.usesHeroLayout ? 0 : 16, for: .scrollContent
                )
                .scrollContentBackground(.visible)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: SettingsPage.self) { page in
                    settings.page(page, grouped: true)
                        .navigationBarTitleDisplayMode(.inline)
                }
                .toolbar {
                    if #available(iOS 26, *) {
                        ToolbarItem(placement: .topBarLeading) {
                            closeButton
                        }
                        .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .topBarLeading) {
                            closeButton
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 8) {
                            let avatar = AvatarView(
                                url: settings.me.avatarUrl.flatMap(URL.init(string:)),
                                displayName: settings.me.username, diameter: 24
                            )
                            .accessibilityHidden(true)
                            if compactTitleOpacity >= 0.5 && settings.usesHeroLayout {
                                avatar.modifier(AccountAvatarEndpoint(role: .hero))
                            } else {
                                avatar
                            }
                            Text(settings.me.username)
                                .font(.headline)
                                .lineLimit(1)
                        }
                        .opacity(compactTitleOpacity)
                        .accessibilityHidden(compactTitleOpacity < 0.5)
                        .allowsHitTesting(false)
                    }
                }
            }
            .onPreferenceChange(SettingsEditorExitProtectionKey.self) {
                protectsEditorEdits = $0
            }
        }

        private var closeButton: some View {
            Button("Close", systemImage: "xmark") {
                if let onClose = settings.onClose {
                    onClose()
                } else {
                    dismiss()
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.system(size: 18, weight: .medium))
            .frame(width: 44, height: 44)
            .modifier(ChatGlassSurface(cornerRadius: 22, isInteractive: true))
            .disabled(protectsEditorEdits)
        }
    }

    private struct OwnProfileHeroBottomKey: PreferenceKey {
        static let defaultValue: CGFloat? = nil

        static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
            if let next = nextValue() { value = next }
        }
    }
#endif
