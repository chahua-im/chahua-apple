import ChahuaAPI
import Foundation
import SwiftUI

struct GroupInfoView: View {
    let chat: ChatListItem
    let currentUserID: Int32
    @ObservedObject private var store: ChatStore
    let onLeave: () -> Void
    let onSearch: () -> Void

    @State private var groupInfo: GroupInfoResponse?
    @State private var showsNotificationSettings = false
    @State private var isLoadingInfo = false
    @State private var isLeaving = false
    @State private var showsLeaveConfirmation = false
    @State private var failure: GroupInfoFailure?
    @State private var infoRevision = 0
    @Environment(\.colorScheme) private var colorScheme

    init(
        chat: ChatListItem,
        currentUserID: Int32,
        store: ChatStore,
        onLeave: @escaping () -> Void,
        onSearch: @escaping () -> Void
    ) {
        self.chat = chat
        self.currentUserID = currentUserID
        self.store = store
        self.onLeave = onLeave
        self.onSearch = onSearch
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                hero
                actions
                if let description {
                    descriptionCard(description)
                }
                if isLoadingInfo, groupInfo == nil {
                    ProgressView()
                        .controlSize(.small)
                } else if failure?.operation.isLoad == true {
                    HStack {
                        Text("Couldn’t load group info")
                            .foregroundStyle(.secondary)
                        Button("Retry") { retry(.load) }
                    }
                    .font(.footnote)
                }
                if isDM, let peer = groupInfo?.peer {
                    ReadReceiptPrivacySettingsRows(store: store, peerUID: peer.uid)
                        .id(peer.uid)
                        .padding(.horizontal, 16)
                }
                sectionTabs
                if !isDM {
                    GroupMembersView(chatID: chat.id, currentUserID: currentUserID, store: store)
                }
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(ChahuaTheme.conversationBackground(for: colorScheme))
        .navigationTitle(isDM ? "Chat Info" : "Group Info")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: chat.id) { await loadInfo() }
        .presenceScope(ChatPresenceDisplay.scope(for: chat), store: store)
        .sheet(isPresented: $showsNotificationSettings) {
            NavigationStack {
                ChatNotificationSettingsView(store: store, chat: notificationChat)
            }
            .frame(minWidth: 320, minHeight: 420)
        }
        .confirmationDialog(
            "Leave group",
            isPresented: $showsLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Leave", role: .destructive) { Task { await leaveGroup() } }
                .accessibilityIdentifier("group-leave-confirm-button")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to leave this group?")
        }
        .alert(
            Text(
                failure?.operation.title ?? AppLanguage.localized("Couldn’t complete group action")),
            isPresented: Binding(
                get: { failure != nil && failure?.operation.isLoad == false },
                set: { if !$0 { failure = nil } }
            )
        ) {
            if let failure {
                Button("Retry") { retry(failure.operation) }
            }
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure?.message ?? "")
        }
    }

    private var hero: some View {
        VStack(spacing: 6) {
            AvatarView(
                url: avatarURL, displayName: displayName, diameter: 104,
                isOnline: ChatPresenceDisplay.isOnline(chat, in: store.state)
            )
            .padding(.bottom, 8)
            Text(displayName)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if let subtitle = ChatPresenceDisplay.subtitle(for: chat, in: store.state) {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func descriptionCard(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Description")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(description)
                .font(.body)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            ChahuaTheme.ChatBubble.incomingBackground(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .accessibilityElement(children: .combine)
    }

    /// Placeholder section bar: only group Members exists; media sections are not implemented yet.
    private var sectionTabs: some View {
        let sections = GroupInfoSection.allCases.filter { !isDM || $0 != .members }
        let selected = sections.first
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(sections, id: \.self) { section in
                    Text(section.title)
                        .font(.body.weight(section == selected ? .semibold : .regular))
                        .foregroundStyle(section == selected ? .primary : .secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background {
                            if section == selected {
                                Capsule().fill(ChahuaTheme.secondaryBackground)
                            }
                        }
                        .accessibilityAddTraits(section == selected ? .isSelected : [])
                }
            }
            .padding(4)
        }
        .background(
            ChahuaTheme.ChatBubble.incomingBackground(for: colorScheme), in: Capsule())
    }

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    showsNotificationSettings = true
                } label: {
                    GroupInfoActionLabel(
                        systemImage: isMuted ? "bell.slash" : "bell",
                        title: "Notifications")
                }
                .accessibilityIdentifier("group-notification-settings")
                .accessibilityLabel("Notification settings")
                .disabled(isLeaving)

                Button(action: onSearch) {
                    GroupInfoActionLabel(systemImage: "magnifyingglass", title: "Search")
                }
                .accessibilityIdentifier("group-search-button")
                .accessibilityLabel("Search messages")
                .disabled(isLeaving)

                if !isDM {
                    Menu {
                        Button(role: .destructive) {
                            showsLeaveConfirmation = true
                        } label: {
                            Label("Leave group", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .accessibilityIdentifier("leave-group-button")
                    } label: {
                        GroupInfoActionLabel(
                            systemImage: "ellipsis", title: "More", isProgressing: isLeaving
                        )
                    }
                    .accessibilityIdentifier("group-more-menu")
                    .disabled(isLeaving)
                }
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .frame(maxWidth: 560)

            Text(LocalizedStringKey(isMuted ? "Notifications muted" : "Notifications enabled"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var isDM: Bool { chat.kind == .dm }

    private var displayName: String {
        isDM ? chat.chatDisplayName : nonEmpty(groupInfo?.name) ?? chat.chatDisplayName
    }

    private var description: String? {
        nonEmpty(groupInfo?.description)
    }

    private var avatarURL: URL? {
        isDM ? chat.chatAvatarURL : (groupInfo?.avatar ?? chat.avatar).flatMap(URL.init(string:))
    }

    private var listedChat: ChatListItem? {
        store.state.chats.first { $0.id == chat.id }
            ?? store.state.archivedChats.first { $0.id == chat.id }
    }

    private var notificationChat: ChatListItem {
        if let listedChat { return listedChat }
        guard let groupInfo else { return chat }
        return store.notificationChatSnapshot(
            chat.withNotificationState(
                mutedUntil: groupInfo.mutedUntil, muteOverride: groupInfo.muteOverride,
                isMuted: groupInfo.isMuted, archived: chat.archived))
    }

    private var isMuted: Bool {
        notificationChat.notificationMuted(defaults: store.state.notificationDefaults)
    }

    private func loadInfo() async {
        guard !isLoadingInfo else { return }
        isLoadingInfo = true
        let revision = infoRevision
        defer { isLoadingInfo = false }

        do {
            let response = try await store.groupInfo(chatID: chat.id)
            try Task.checkCancellation()
            groupInfo = response
            if failure?.operation.isLoad == true { failure = nil }
        } catch is CancellationError {
            // The navigation container cancelled this screen's task.
        } catch {
            guard infoRevision == revision else { return }
            failure = .init(operation: .load, message: error.localizedDescription)
        }
    }

    private func leaveGroup() async {
        guard !isLeaving else { return }
        isLeaving = true
        failure = nil
        defer { isLeaving = false }

        do {
            try await store.leaveGroup(chatID: chat.id, uid: currentUserID)
            try Task.checkCancellation()
            onLeave()
        } catch is CancellationError {
            // Cancellation does not imply that the server rejected the leave.
        } catch {
            failure = .init(operation: .leave, message: error.localizedDescription)
        }
    }

    private func retry(_ operation: GroupInfoOperation) {
        failure = nil
        switch operation {
        case .load:
            Task { await loadInfo() }
        case .leave:
            Task { await leaveGroup() }
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct GroupInfoActionLabel: View {
    let systemImage: String
    let title: LocalizedStringKey
    var isProgressing = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 6) {
            if isProgressing {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 24)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .frame(height: 24)
            }
            Text(title)
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(Color.accentColor)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .contentShape(RoundedRectangle(cornerRadius: 18))
        // Flat tiles on every platform, matching the Flutter group detail actions.
        .background(
            ChahuaTheme.ChatBubble.incomingBackground(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 18))
    }
}

private enum GroupInfoOperation {
    case load
    case leave

    var isLoad: Bool {
        if case .load = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .load: AppLanguage.localized("Couldn’t load group info")
        case .leave: AppLanguage.localized("Couldn’t leave group")
        }
    }
}

private struct GroupInfoFailure: Identifiable {
    let operation: GroupInfoOperation
    let message: String

    var id: String {
        switch operation {
        case .load: "load"
        case .leave: "leave"
        }
    }
}

private enum GroupInfoSection: CaseIterable {
    case members, media, files, links, voice

    var title: LocalizedStringKey {
        switch self {
        case .members: "Members"
        case .media: "Media"
        case .files: "Files"
        case .links: "Links"
        case .voice: "Voice"
        }
    }
}
