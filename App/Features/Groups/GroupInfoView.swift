import ChahuaAPI
import Foundation
import SwiftUI

struct GroupInfoView: View {
    let chat: ChatListItem
    let currentUserID: Int32
    @ObservedObject private var store: ChatStore
    let onLeave: () -> Void

    @State private var groupInfo: GroupInfoResponse?
    @State private var mutedUntil: Date?
    @State private var isLoadingInfo = false
    @State private var isUpdatingMute = false
    @State private var isLeaving = false
    @State private var showsLeaveConfirmation = false
    @State private var failure: GroupInfoFailure?
    @State private var infoRevision = 0
    @Environment(\.colorScheme) private var colorScheme

    init(
        chat: ChatListItem,
        currentUserID: Int32,
        store: ChatStore,
        onLeave: @escaping () -> Void
    ) {
        self.chat = chat
        self.currentUserID = currentUserID
        self.store = store
        self.onLeave = onLeave
        _mutedUntil = State(initialValue: chat.mutedUntil)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                hero
                actions
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
                GroupMembersView(chatID: chat.id, currentUserID: currentUserID, store: store)
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(ChahuaTheme.conversationBackground(for: colorScheme))
        .navigationTitle("Group Info")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: chat.id) { await loadInfo() }
        .onChange(of: listedChat?.mutedUntil) { _, value in
            if listedChat != nil { mutedUntil = value }
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
            Text(failure?.operation.title ?? String(localized: "Couldn’t complete group action")),
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
        VStack(spacing: 12) {
            AvatarView(url: avatarURL, displayName: displayName, diameter: 104)
                .padding(.bottom, 4)
            Text(displayName)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Text(description ?? String(localized: "No group description yet."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayName)
        .accessibilityValue(description ?? String(localized: "No group description yet."))
    }

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Menu {
                    if isMuted {
                        Button("Unmute") { Task { await unmute() } }
                            .accessibilityIdentifier("group-unmute-button")
                        Divider()
                    }
                    Button("Mute for 1 hour") { Task { await mute(for: 60 * 60) } }
                        .accessibilityIdentifier("group-mute-1h-button")
                    Button("Mute for 8 hours") { Task { await mute(for: 8 * 60 * 60) } }
                        .accessibilityIdentifier("group-mute-8h-button")
                    Button("Mute for 1 day") { Task { await mute(for: 24 * 60 * 60) } }
                        .accessibilityIdentifier("group-mute-1d-button")
                    Button("Mute for 7 days") { Task { await mute(for: 7 * 24 * 60 * 60) } }
                        .accessibilityIdentifier("group-mute-7d-button")
                    Button("Mute forever") { Task { await mute(for: nil) } }
                        .accessibilityIdentifier("group-mute-forever-button")
                } label: {
                    GroupInfoActionLabel(
                        systemImage: isMuted ? "bell.slash" : "bell",
                        title: isMuted ? "Unmute" : "Mute",
                        isProgressing: isUpdatingMute
                    )
                }
                .accessibilityIdentifier("group-mute-menu")
                .accessibilityLabel("Notification settings")
                .accessibilityValue(muteStatus)
                .disabled(isLeaving || isUpdatingMute)

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
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .frame(maxWidth: 340)

            if isMuted {
                Text(muteStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var displayName: String {
        nonEmpty(groupInfo?.name) ?? chat.chatDisplayName
    }

    private var description: String? {
        nonEmpty(groupInfo?.description)
    }

    private var avatarURL: URL? {
        (groupInfo?.avatar ?? chat.avatar).flatMap(URL.init(string:))
    }

    private var listedChat: ChatListItem? {
        store.state.chats.first { $0.id == chat.id }
            ?? store.state.archivedChats.first { $0.id == chat.id }
    }

    private var isMuted: Bool {
        guard let mutedUntil else { return false }
        return mutedUntil > Date()
    }

    private var muteStatus: String {
        guard isMuted, let mutedUntil else { return String(localized: "Not muted") }
        if Calendar(identifier: .gregorian).component(.year, from: mutedUntil) >= 9000 {
            return String(localized: "Muted forever")
        }
        let date = mutedUntil.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Muted until \(date)")
    }

    private func loadInfo() async {
        guard !isLoadingInfo else { return }
        isLoadingInfo = true
        let revision = infoRevision
        let listedMuteAtStart = listedChat?.mutedUntil
        defer { isLoadingInfo = false }

        do {
            let response = try await store.groupInfo(chatID: chat.id)
            try Task.checkCancellation()
            groupInfo = response
            if infoRevision == revision, listedChat?.mutedUntil == listedMuteAtStart {
                mutedUntil = response.mutedUntil
            }
            if failure?.operation.isLoad == true { failure = nil }
        } catch is CancellationError {
            // The navigation container cancelled this screen's task.
        } catch {
            guard infoRevision == revision else { return }
            failure = .init(operation: .load, message: error.localizedDescription)
        }
    }

    private func mute(for durationSeconds: Int?) async {
        guard !isUpdatingMute, !isLeaving else { return }
        isUpdatingMute = true
        infoRevision &+= 1
        let revision = infoRevision
        failure = nil
        defer {
            if infoRevision == revision { isUpdatingMute = false }
        }

        do {
            let nextMutedUntil = try await store.muteGroup(
                chatID: chat.id, durationSeconds: durationSeconds)
            try Task.checkCancellation()
            guard infoRevision == revision else { return }
            mutedUntil = nextMutedUntil
        } catch is CancellationError {
            // The view no longer owns the presentation state.
        } catch {
            guard infoRevision == revision else { return }
            failure = .init(operation: .mute(durationSeconds), message: error.localizedDescription)
        }
    }

    private func unmute() async {
        guard !isUpdatingMute, !isLeaving else { return }
        isUpdatingMute = true
        infoRevision &+= 1
        let revision = infoRevision
        failure = nil
        defer {
            if infoRevision == revision { isUpdatingMute = false }
        }

        do {
            try await store.unmuteGroup(chatID: chat.id)
            try Task.checkCancellation()
            guard infoRevision == revision else { return }
            mutedUntil = nil
        } catch is CancellationError {
            // The view no longer owns the presentation state.
        } catch {
            guard infoRevision == revision else { return }
            failure = .init(operation: .unmute, message: error.localizedDescription)
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
        case .mute(let durationSeconds):
            Task { await mute(for: durationSeconds) }
        case .unmute:
            Task { await unmute() }
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
        // The requested iOS controls use Liquid Glass; desktop uses quieter,
        // flat action tiles. Both are SwiftUI, without custom native wrappers.
        #if os(iOS)
            .modifier(ChatGlassSurface(cornerRadius: 18, isInteractive: true))
        #else
            .background(
                ChahuaTheme.ChatBubble.incomingBackground(for: colorScheme),
                in: RoundedRectangle(cornerRadius: 18))
        #endif
    }
}

private enum GroupInfoOperation {
    case load
    case mute(Int?)
    case unmute
    case leave

    var isLoad: Bool {
        if case .load = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .load: String(localized: "Couldn’t load group info")
        case .mute, .unmute: String(localized: "Couldn’t update notifications")
        case .leave: String(localized: "Couldn’t leave group")
        }
    }
}

private struct GroupInfoFailure: Identifiable {
    let operation: GroupInfoOperation
    let message: String

    var id: String {
        switch operation {
        case .load: "load"
        case .mute: "mute"
        case .unmute: "unmute"
        case .leave: "leave"
        }
    }
}
