import ChahuaAPI
import Foundation
import SwiftUI

struct GroupInfoView: View {
    let chat: ChatListItem
    let currentUserID: Int32
    @ObservedObject private var store: ChatStore
    let onLeave: () -> Void
    let onSearch: () -> Void
    let onOpenMessage: (MessageResponse) -> Void
    let onOpenThread: (MessageResponse) -> Void

    @State private var groupInfo: GroupInfoResponse?
    @State private var isUpdatingNotifications = false
    @State private var isLoadingInfo = false
    @State private var isLeaving = false
    @State private var safetyConfirmation: GroupInfoSafetyAction?
    @State private var relationship: FriendRelationshipResponse?
    @State private var isLoadingRelationship = false
    @State private var isChangingRelationship = false
    @State private var failure: GroupInfoFailure?
    @State private var infoRevision = 0
    @State private var selectedSection: GroupInfoSection = .members
    @State private var selectedMediaKind: ChatAttachmentKind = .image
    @State private var showsInvitations = false
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppLanguage.storageKey) private var languageRawValue = AppLanguage.system.rawValue
    private let sessionRevision: Int

    init(
        chat: ChatListItem,
        currentUserID: Int32,
        store: ChatStore,
        onLeave: @escaping () -> Void,
        onSearch: @escaping () -> Void,
        onOpenMessage: @escaping (MessageResponse) -> Void = { _ in },
        onOpenThread: @escaping (MessageResponse) -> Void = { _ in }
    ) {
        self.chat = chat
        self.currentUserID = currentUserID
        self.store = store
        self.onLeave = onLeave
        self.onSearch = onSearch
        self.onOpenMessage = onOpenMessage
        self.onOpenThread = onOpenThread
        sessionRevision = store.sessionRevision
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
                if isDM, let peer = groupInfo?.peer ?? chat.peer {
                    NavigationLink {
                        FriendPrivacySettingsView(store: store, peerUID: peer.uid)
                            .id(peer.uid)
                    } label: {
                        HStack {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(
                                    .blue, in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                            Text("Privacy Settings")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(
                            ChahuaTheme.ChatBubble.incomingBackground(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: 18)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
                sectionTabs
                sectionContent
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isCurrentSession, !isDM, let info = groupInfo, info.myRole == .admin {
                    NavigationLink("Edit") {
                        GroupEditingView(store: store, info: info) { updated in
                            groupInfo = updated
                            infoRevision += 1
                        }
                    }
                    .accessibilityIdentifier("group-edit-button")
                    .disabled(isLeaving)
                }
            }
        }
        .navigationDestination(isPresented: $showsInvitations) {
            GroupInvitesView(store: store, chatID: chat.id)
        }
        .task(id: chat.id) { await loadInfo() }
        .onReceive(store.$groupInfoByChatID) { infos in
            guard isCurrentSession else {
                groupInfo = nil
                return
            }
            if let updated = infos[chat.id] {
                groupInfo = updated
                infoRevision &+= 1
            }
        }
        .onChange(of: store.sessionRevision) { _, _ in groupInfo = nil }
        .task(id: peerUID) { await loadRelationship() }
        .presenceScope(ChatPresenceDisplay.scope(for: chat), store: store)
        .confirmationDialog(
            safetyConfirmation?.title ?? "",
            isPresented: Binding(
                get: { safetyConfirmation != nil },
                set: { if !$0 { safetyConfirmation = nil } }),
            titleVisibility: .visible,
            presenting: safetyConfirmation
        ) { action in
            Button(action.buttonTitle, role: .destructive) {
                Task { await performSafetyAction(action) }
            }
            .accessibilityIdentifier(
                action == .leaveGroup
                    ? "group-leave-confirm-button" : "friend-action-confirm-button")
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.message(displayName))
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
            if isCurrentSession, !isDM, let groupInfo {
                VStack(spacing: 4) {
                    if groupInfo.myRole == .admin {
                        if let mode = groupInfo.speakingMode {
                            LabeledContent("Speaking permissions", value: mode.localizedTitle)
                        }
                        if let mode = groupInfo.effectiveSpeakingMode,
                            mode != .unrestricted
                        {
                            LabeledContent("Your permissions", value: mode.localizedTitle)
                            Text(mode.restrictionExplanation)
                                .multilineTextAlignment(.center)
                        }
                    }
                    if let policy = groupInfo.membershipMessagePolicy {
                        LabeledContent(
                            "Membership messages", value: policy.visibility.localizedTitle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
                .padding(.top, 6)
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

    private var sectionTabs: some View {
        Picker(
            "Chat Info",
            selection: Binding(
                get: { activeSection },
                set: { selectedSection = $0 }
            )
        ) {
            ForEach(GroupInfoSection.allCases.filter { !isDM || $0 != .members }, id: \.self) {
                section in
                Text(section.title).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("group-info-sections")
    }

    private var activeSection: GroupInfoSection {
        isDM && selectedSection == .members ? .media : selectedSection
    }

    private var sectionContent: some View {
        VStack(spacing: 16) {
            if activeSection == .media {
                Picker("Media", selection: $selectedMediaKind) {
                    Text("Images").tag(ChatAttachmentKind.image)
                    Text("Videos").tag(ChatAttachmentKind.video)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Keep browsers mounted so changing sections preserves each cursor, loaded
            // page, retry, and source-navigation state. Media/threads load only when selected.
            ZStack(alignment: .top) {
                if !isDM {
                    GroupMembersView(chatID: chat.id, currentUserID: currentUserID, store: store)
                        .modifier(GroupInfoSectionVisibility(isSelected: activeSection == .members))
                }
                attachmentSection(
                    .image, isSelected: activeSection == .media && selectedMediaKind == .image)
                attachmentSection(
                    .video, isSelected: activeSection == .media && selectedMediaKind == .video)
                attachmentSection(.other, isSelected: activeSection == .files)
                ChatThreadsView(
                    store: store, chatID: chat.id, onOpenThread: onOpenThread,
                    embedded: true, isActive: activeSection == .threads
                )
                .modifier(GroupInfoSectionVisibility(isSelected: activeSection == .threads))
            }
        }
    }

    private func attachmentSection(_ kind: ChatAttachmentKind, isSelected: Bool) -> some View {
        ChatAttachmentsView(
            store: store, chatID: chat.id, kind: kind, onOpenMessage: onOpenMessage,
            embedded: true, isActive: isSelected
        )
        .modifier(GroupInfoSectionVisibility(isSelected: isSelected))
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if let peerUID {
                Link(
                    destination: URL(
                        string:
                            "https://www.shireyishunjian.com/main/home.php?mod=space&uid=\(peerUID)"
                    )!
                ) {
                    GroupInfoActionLabel(systemImage: "globe", title: "Forum")
                }
                .accessibilityLabel("Forum / Personal Space")
                .accessibilityIdentifier("chat-forum-button")
            }

            notificationMenu

            Button(action: onSearch) {
                GroupInfoActionLabel(systemImage: "magnifyingglass", title: "Search")
            }
            .accessibilityIdentifier("group-search-button")
            .accessibilityLabel("Search messages")
            .disabled(isLeaving)

            Menu {
                if isDM {
                    if relationship?.isFriend == true {
                        Button(
                            "Remove friend", systemImage: "person.badge.minus", role: .destructive
                        ) {
                            safetyConfirmation = .removeFriend
                        }
                    }
                    Button(
                        relationship?.blocking == true ? "Unblock" : "Block",
                        systemImage: "hand.raised.slash", role: .destructive
                    ) {
                        safetyConfirmation = relationship?.blocking == true ? .unblock : .block
                    }
                    .disabled(relationship?.blocking == nil)
                } else {
                    if groupInfo?.myRole == .admin {
                        Button("Manage Invitations", systemImage: "link.badge.plus") {
                            showsInvitations = true
                        }
                        Divider()
                    }
                    Button(role: .destructive) {
                        safetyConfirmation = .leaveGroup
                    } label: {
                        Label("Leave group", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .accessibilityIdentifier("leave-group-button")
                }
            } label: {
                GroupInfoActionLabel(
                    systemImage: "ellipsis", title: "More",
                    isProgressing: isLeaving || isChangingRelationship || isLoadingRelationship)
            }
            .accessibilityIdentifier("group-more-menu")
            .disabled(
                isLeaving || isUpdatingNotifications || isChangingRelationship
                    || (isDM
                        && (isLoadingRelationship || peerUID == nil || peerUID == currentUserID))
            )
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    private var isDM: Bool { chat.kind == .dm }

    private var peerUID: Int32? {
        isDM ? (groupInfo?.peer?.uid ?? chat.peer?.uid) : nil
    }

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
        guard let groupInfo else { return store.notificationChatSnapshot(chat) }
        return store.notificationChatSnapshot(
            chat.withNotificationState(
                mutedUntil: groupInfo.mutedUntil, muteOverride: groupInfo.muteOverride,
                isMuted: groupInfo.isMuted, archived: chat.archived))
    }

    private var isMuted: Bool {
        notificationChat.notificationMuted(defaults: store.state.notificationDefaults)
    }

    private var isMutedForever: Bool {
        let current = notificationChat
        return current.notificationPermanentlyMuted(defaults: store.state.notificationDefaults)
            || NotificationMuteDeadline.isIndefinite(current.mutedUntil)
    }

    private var notificationButtonTitle: LocalizedStringKey {
        let current = notificationChat
        let defaults = store.state.notificationDefaults
        guard current.notificationMuted(defaults: defaults) else { return "Mute" }
        if !current.notificationPermanentlyMuted(defaults: defaults),
            let deadline = NotificationMuteDeadline.finiteDeadline(
                current.mutedUntil, language: AppLanguage(rawValue: languageRawValue) ?? .system)
        {
            return "until \(deadline)"
        }
        return "Unmute"
    }

    private var notificationMenu: some View {
        Menu {
            if isMuted {
                Button("Unmute", systemImage: "bell") {
                    Task { await updateNotifications(nil) }
                }
            } else {
                Menu("Mute for…", systemImage: "bell.badge") {
                    muteDuration("Mute for 1 hour", seconds: 3_600)
                    muteDuration("Mute for 8 hours", seconds: 28_800)
                    muteDuration("Mute for 1 day", seconds: 86_400)
                    muteDuration("Mute for 7 days", seconds: 604_800)
                }
            }
            Menu("Customize", systemImage: "slider.horizontal.3") {
                notificationChoice(
                    "Always notify", mode: .alwaysUnmuted,
                    selected: notificationChat.muteOverride == false)
                notificationChoice(
                    "Always mute", mode: .alwaysMuted,
                    selected: notificationChat.muteOverride == true)
                notificationChoice(
                    "Use account default", mode: .inherit,
                    selected: notificationChat.muteOverride == nil)
            }
            if !isMutedForever {
                Divider()
                Button("Mute forever", systemImage: "bell.slash", role: .destructive) {
                    Task { await updateNotifications(.init(mode: .alwaysMuted)) }
                }
            }
        } label: {
            GroupInfoActionLabel(
                systemImage: isMuted ? "bell.slash" : "bell",
                title: notificationButtonTitle,
                isProgressing: isUpdatingNotifications)
        }
        .accessibilityIdentifier("group-notification-settings")
        .accessibilityLabel("Notification settings")
        .disabled(isLeaving || isUpdatingNotifications || isChangingRelationship)
    }

    private func muteDuration(_ title: LocalizedStringKey, seconds: Int) -> some View {
        Button(title) {
            Task {
                await updateNotifications(.init(mode: .temporarilyMuted, durationSeconds: seconds))
            }
        }
    }

    private func notificationChoice(
        _ title: LocalizedStringKey, mode: NotificationSettingMode, selected: Bool
    ) -> some View {
        Button {
            Task { await updateNotifications(.init(mode: mode)) }
        } label: {
            HStack {
                Text(title)
                if selected { Image(systemName: "checkmark") }
            }
        }
    }

    /// A nil request is Unmute: remove an override only when the default already notifies.
    private func updateNotifications(_ request: UpdateNotificationSettingRequest?) async {
        guard !isUpdatingNotifications, !isLeaving, !isChangingRelationship,
            store.currentUserProfile?.uid == currentUserID
        else { return }
        isUpdatingNotifications = true
        defer { isUpdatingNotifications = false }
        do {
            let resolved: UpdateNotificationSettingRequest
            if let request {
                resolved = request
            } else {
                try await store.loadNotificationDefaults()
                guard let defaults = store.state.notificationDefaults else {
                    throw APIError.unavailable
                }
                resolved = .init(
                    mode: defaults.mutedByDefault(kind: chat.kind) ? .alwaysUnmuted : .inherit)
            }
            guard store.currentUserProfile?.uid == currentUserID else { return }
            try await store.setNotificationSetting(chatID: chat.id, request: resolved)
        } catch is CancellationError {} catch {
            failure = .init(operation: .notifications(request), message: error.localizedDescription)
        }
    }

    private var isCurrentSession: Bool {
        store.sessionRevision == sessionRevision && store.currentUserProfile?.uid == currentUserID
    }

    private func loadInfo() async {
        guard isCurrentSession, !isLoadingInfo else { return }
        isLoadingInfo = true
        let revision = infoRevision
        defer { isLoadingInfo = false }

        do {
            let response = try await store.groupInfo(chatID: chat.id)
            try Task.checkCancellation()
            guard isCurrentSession else { return }
            groupInfo = store.groupInfoByChatID[chat.id] ?? response
            store.trackNotificationExpiry(for: notificationChat)
            if failure?.operation.isLoad == true { failure = nil }
        } catch is CancellationError {
            // The navigation container cancelled this screen's task.
        } catch {
            guard isCurrentSession, infoRevision == revision else { return }
            failure = .init(operation: .load, message: error.localizedDescription)
        }
    }

    private func loadRelationship() async {
        guard let peerUID, peerUID != currentUserID, !isLoadingRelationship,
            store.currentUserProfile?.uid == currentUserID
        else { return }
        isLoadingRelationship = true
        defer { isLoadingRelationship = false }
        do {
            let response = try await store.friendRelationship(peerUID: peerUID)
            try Task.checkCancellation()
            guard store.currentUserProfile?.uid == currentUserID, self.peerUID == peerUID else {
                return
            }
            relationship = response
        } catch is CancellationError {} catch {
            failure = .init(operation: .relationship, message: error.localizedDescription)
        }
    }

    private func performSafetyAction(_ action: GroupInfoSafetyAction) async {
        if action == .leaveGroup {
            await leaveGroup()
            return
        }
        guard let peerUID, peerUID != currentUserID, !isChangingRelationship,
            !isUpdatingNotifications, !isLeaving,
            store.currentUserProfile?.uid == currentUserID
        else { return }
        isChangingRelationship = true
        defer { isChangingRelationship = false }
        do {
            switch action {
            case .removeFriend: try await store.removeFriend(peerUID: peerUID)
            case .block: try await store.setUserBlocked(peerUID: peerUID, blocked: true)
            case .unblock: try await store.setUserBlocked(peerUID: peerUID, blocked: false)
            case .leaveGroup: return
            }
        } catch is CancellationError {
            return
        } catch {
            failure = .init(operation: .safety(action), message: error.localizedDescription)
            return
        }
        guard store.currentUserProfile?.uid == currentUserID else { return }
        if action == .removeFriend {
            onLeave()
        } else {
            // Retry a failed refresh without repeating a mutation that already committed.
            relationship = nil
            await loadRelationship()
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
        case .notifications(let request):
            Task { await updateNotifications(request) }
        case .relationship:
            Task { await loadRelationship() }
        case .safety(let action):
            Task { await performSafetyAction(action) }
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum GroupInfoSection: CaseIterable {
    case members, media, files, threads

    var title: LocalizedStringKey {
        switch self {
        case .members: "Members"
        case .media: "Media"
        case .files: "Files"
        case .threads: "Threads"
        }
    }
}

private struct GroupInfoSectionVisibility: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .frame(height: isSelected ? nil : 0, alignment: .top)
            .clipped()
            .opacity(isSelected ? 1 : 0)
            .allowsHitTesting(isSelected)
            .accessibilityHidden(!isSelected)
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
    case notifications(UpdateNotificationSettingRequest?)
    case relationship
    case safety(GroupInfoSafetyAction)

    var isLoad: Bool {
        if case .load = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .load: AppLanguage.localized("Couldn’t load group info")
        case .leave: AppLanguage.localized("Couldn’t leave group")
        case .notifications: AppLanguage.localized("Couldn’t update notifications")
        case .relationship: AppLanguage.localized("Couldn’t load friendship")
        case .safety: AppLanguage.localized("Couldn’t update friendship")
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
        case .notifications: "notifications"
        case .relationship: "relationship"
        case .safety: "safety"
        }
    }
}

private enum GroupInfoSafetyAction {
    case leaveGroup, removeFriend, block, unblock

    var title: String {
        switch self {
        case .leaveGroup: AppLanguage.localized("Leave group")
        case .removeFriend: AppLanguage.localized("Remove friend")
        case .block: AppLanguage.localized("Block user")
        case .unblock: AppLanguage.localized("Unblock user")
        }
    }

    var buttonTitle: LocalizedStringKey {
        switch self {
        case .leaveGroup: "Leave"
        case .removeFriend: "Remove"
        case .block: "Block"
        case .unblock: "Unblock"
        }
    }

    func message(_ name: String) -> String {
        switch self {
        case .leaveGroup: AppLanguage.localized("Are you sure you want to leave this group?")
        case .removeFriend: AppLanguage.localized("Remove \(name) from your friends?")
        case .block: AppLanguage.localized("Block \(name)?")
        case .unblock: AppLanguage.localized("Unblock \(name)?")
        }
    }
}
