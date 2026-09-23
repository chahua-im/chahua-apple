import ChahuaAPI
import Foundation
import SwiftUI

struct GroupMembersView: View {
    @StateObject private var model: GroupMembersModel
    @State private var searchText = ""
    @State private var pendingAction: PendingMemberAction?
    @State private var failedAction: FailedMemberAction?
    @Environment(\.colorScheme) private var colorScheme

    init(chatID: String, currentUserID: Int32, store: ChatStore) {
        _model = StateObject(
            wrappedValue: GroupMembersModel(chatID: chatID, currentUserID: currentUserID, store: store)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Members")
                    .font(.headline)
                Spacer()
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Refresh")
                .disabled(model.loadPhase == .loading)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search members", text: $searchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    #endif
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(ChahuaTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 10))

            LazyVStack(spacing: 0) {
                if model.isInitialLoad {
                    ProgressView("Loading group members…")
                        .padding(20)
                } else if model.loadPhase == .failed {
                    ChahuaRecoverableErrorView(
                        title: "Couldn’t load group members",
                        message: "Check your connection and try again.",
                        retryTitle: "Retry",
                        onRetry: { Task { await model.refresh() } }
                    )
                    .padding(16)
                } else {
                    membersContent
                }
            }
            .frame(maxWidth: .infinity)
            .background(ChahuaTheme.ChatBubble.incomingBackground(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: 18))
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .onSubmit { model.submitSearch(searchText) }
        .onChange(of: searchText) { _, value in model.updateSearchQuery(value) }
        .task { await model.loadIfNeeded() }
        .onDisappear {
            pendingAction = nil
            model.cancelPendingRequests()
        }
        .confirmationDialog(
            Text(pendingAction?.confirmationTitle ?? String(localized: "Confirm member action")),
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingAction
        ) { action in
            Button(action.confirmationTitle, role: action.kind == .remove ? .destructive : nil) {
                perform(action)
            }
            .accessibilityIdentifier(action.confirmationIdentifier)
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.confirmationMessage)
        }
        .alert(
            "Couldn’t update member",
            isPresented: Binding(
                get: { failedAction != nil },
                set: { if !$0 { failedAction = nil } }
            )
        ) {
            if let failedAction, model.canManage(failedAction.action.member) {
                Button("Retry") { perform(failedAction.action) }
            }
            Button("OK", role: .cancel) { failedAction = nil }
        } message: {
            Text(failedAction?.message ?? "")
        }
    }

    @ViewBuilder
    private var membersContent: some View {
        if model.loadPhase == .loading {
            HStack(spacing: ChahuaTheme.Spacing.small) {
                ProgressView()
                Text("Refreshing group members…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Refreshing group members…")
        }

        if model.loadError != nil {
            ChahuaRecoverableErrorView(
                title: "Couldn’t refresh group members",
                message: "The current directory is still shown. Try again to refresh it.",
                retryTitle: "Retry",
                onRetry: { Task { await model.refresh() } }
            )
            .padding(16)
        }

        if model.members.isEmpty, model.loadPhase == .loaded {
            ChahuaEmptyStateView(
                title: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "No group members"
                    : "No matching members",
                message: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Members will appear here when they are available."
                    : "Try a different name or submit a more specific search.",
                systemImage: "person.2"
            )
            .padding(20)
        }

        ForEach(model.members) { member in
            VStack(spacing: 0) {
                memberRow(member)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                if member.uid != model.members.last?.uid {
                    Divider()
                        .padding(.leading, 68)
                }
            }
                .onAppear {
                    if member.uid == model.members.last?.uid {
                        model.loadMore()
                    }
                }
        }

        if model.isLoadingMore {
            HStack {
                Spacer()
                ProgressView("Loading more members…")
                    .controlSize(.small)
                Spacer()
            }
            .accessibilityLabel("Loading more group members")
            .padding(16)
        } else if model.loadMoreError != nil {
            HStack {
                VStack(alignment: .leading, spacing: ChahuaTheme.Spacing.xSmall) {
                    Text("Couldn’t load more members")
                    Text("Try again to continue the directory.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Retry") { model.loadMore() }
                    .buttonStyle(.bordered)
            }
            .padding(16)
        } else if model.nextCursor != nil {
            Button("Load more members") { model.loadMore() }
                .disabled(!model.mutatingMemberIDs.isEmpty)
                .padding(16)
        }
    }

    @ViewBuilder
    private func memberRow(_ member: MemberResponse) -> some View {
        if model.canManage(member) {
            Menu {
                Button(member.role == .admin ? "Demote to member" : "Promote to admin") {
                    pendingAction = .init(member: member, kind: member.role == .admin ? .demote : .promote)
                }
                .accessibilityIdentifier("group-member-\(member.uid)-toggle-role")
                Button("Remove from group", role: .destructive) {
                    pendingAction = .init(member: member, kind: .remove)
                }
                .accessibilityIdentifier("group-member-\(member.uid)-remove")
            } label: {
                memberRowLabel(member, isActionable: true)
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .foregroundStyle(.primary)
            .accessibilityIdentifier("group-member-\(member.uid)")
            .accessibilityLabel(memberName(member))
            .accessibilityValue(Text(memberRoleLabel(member.role)))
            .accessibilityHint("Show member actions")
        } else {
            memberRowLabel(member, isActionable: false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("group-member-\(member.uid)")
                .accessibilityLabel(memberName(member))
                .accessibilityValue(Text(memberRoleLabel(member.role)))
        }
    }

    private func memberRowLabel(_ member: MemberResponse, isActionable: Bool) -> some View {
        HStack(spacing: ChahuaTheme.Spacing.medium) {
            AvatarView(
                url: member.avatarUrl.flatMap(URL.init(string:)),
                displayName: memberName(member),
                diameter: 40
            )
            .accessibilityHidden(true)

            Text(memberName(member))
                .font(.body.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if member.role == .admin {
                Text("Admin")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(ChahuaTheme.secondaryBackground, in: Capsule())
            }

            if model.mutatingMemberIDs.contains(member.uid) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Updating \(memberName(member))")
            } else if isActionable {
                Image(systemName: "ellipsis")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private func perform(_ action: PendingMemberAction) {
        pendingAction = nil
        guard model.canManage(action.member) else {
            failedAction = .init(
                action: action,
                message: String(localized: "You no longer have permission to manage group members.")
            )
            return
        }
        Task {
            do {
                switch action.kind {
                case .promote:
                    try await model.updateRole(of: action.member, to: .admin)
                case .demote:
                    try await model.updateRole(of: action.member, to: .member)
                case .remove:
                    try await model.remove(action.member)
                }
            } catch is CancellationError {
                // A disappearing screen should not surface a cancelled request.
            } catch {
                guard !Task.isCancelled else { return }
                failedAction = .init(action: action, message: error.localizedDescription)
            }
        }
    }

    private func memberName(_ member: MemberResponse) -> String {
        let username = member.username?.trimmingCharacters(in: .whitespacesAndNewlines)
        return username?.isEmpty == false ? username! : String(localized: "User \(member.uid)")
    }

    private func memberRoleLabel(_ role: GroupRole) -> LocalizedStringKey {
        role == .admin ? "Admin" : "Member"
    }
}

private struct PendingMemberAction: Identifiable {
    enum Kind {
        case promote
        case demote
        case remove
    }

    let member: MemberResponse
    let kind: Kind

    var id: String {
        switch kind {
        case .promote: "promote-\(member.uid)"
        case .demote: "demote-\(member.uid)"
        case .remove: "remove-\(member.uid)"
        }
    }

    var confirmationIdentifier: String {
        "group-member-\(member.uid)-confirm-\(id)"
    }

    var confirmationTitle: String {
        switch kind {
        case .promote: String(localized: "Promote member")
        case .demote: String(localized: "Demote member")
        case .remove: String(localized: "Remove member")
        }
    }

    var confirmationMessage: String {
        let name = memberDisplayName
        return switch kind {
        case .promote: String(localized: "Promote \(name) to admin?")
        case .demote: String(localized: "Demote \(name) to member?")
        case .remove: String(localized: "Remove \(name) from this group?")
        }
    }

    private var memberDisplayName: String {
        let username = member.username?.trimmingCharacters(in: .whitespacesAndNewlines)
        return username?.isEmpty == false ? username! : String(localized: "User \(member.uid)")
    }
}

private struct FailedMemberAction: Identifiable {
    let action: PendingMemberAction
    let message: String

    var id: String { action.id }
}
