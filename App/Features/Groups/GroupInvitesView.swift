import ChahuaAPI
import Foundation
import SwiftUI

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

struct GroupInvitesView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var exitGuard: FormExitGuard
    let exitOwner: UUID
    let chatID: String
    let onBack: () -> Void
    @State private var groupInfo: GroupInfoResponse?
    @State private var accountUID: Int32?
    @State private var sessionRevision: Int
    @State private var accessRevoked = false
    @State private var loading = false
    @State private var busy = false
    @State private var invites: [GroupInvite] = []
    @State private var type = GroupInviteType.generic
    @State private var target: MemberSummary?
    @State private var requiredGroup: SocialGroupSummary?
    @State private var destination: SocialGroupSummary?
    @State private var expires = false
    @State private var expiry: Date
    @State private var initialExpiry: Date
    @State private var revoking: GroupInvite?
    @State private var error: String?
    @State private var notice: String?
    @State private var sendKeys: [String: String] = [:]
    @State private var operationTask: Task<Void, Never>?

    init(
        store: ChatStore, exitGuard: FormExitGuard, exitOwner: UUID,
        chatID: String, onBack: @escaping () -> Void
    ) {
        self.store = store
        self.exitGuard = exitGuard
        self.exitOwner = exitOwner
        self.chatID = chatID
        self.onBack = onBack
        _groupInfo = State(initialValue: store.groupInfoByChatID[chatID])
        _accountUID = State(initialValue: store.currentUserProfile?.uid)
        _sessionRevision = State(initialValue: store.sessionRevision)
        let initialExpiry = Date().addingTimeInterval(86_400)
        _initialExpiry = State(initialValue: initialExpiry)
        _expiry = State(initialValue: initialExpiry)
    }

    var body: some View {
        Form {
            if loading { ProgressView("Loading invitations…") }
            if let error {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("Refresh") { Task { await load() } }.disabled(busy || loading)
                }
            }
            if authorized {
                Section("Create invitation") {
                    Picker("Type", selection: $type) {
                        Text("Anyone with the link").tag(GroupInviteType.generic)
                        Text("Specific user").tag(GroupInviteType.targeted)
                        Text("Members of another group").tag(GroupInviteType.membership)
                    }
                    if type == .targeted {
                        NavigationLink(
                            target.map { $0.username ?? String($0.uid) } ?? "Choose recipient"
                        ) {
                            GroupInviteUserPicker(store: store) {
                                guard authorized, !busy else { return }
                                target = $0
                            }
                        }
                    }
                    if type == .membership {
                        NavigationLink(requiredGroup?.name ?? "Choose prerequisite group") {
                            GroupInviteGroupPicker(store: store, title: "Prerequisite Group") {
                                guard authorized, !busy else { return }
                                requiredGroup = $0
                            }
                        }
                    }
                    Toggle("Set expiry", isOn: $expires)
                    if expires { DatePicker("Expires", selection: $expiry, in: Date()...) }
                    Button("Create invitation") {
                        operationTask = Task { await create() }
                    }
                    .disabled(
                        busy || (type == .targeted && target == nil)
                            || (type == .membership && requiredGroup == nil)
                            || (expires && expiry <= Date()))
                }
                Section("Send invite card") {
                    NavigationLink(destination?.name ?? "Choose destination group") {
                        GroupInviteGroupPicker(store: store, title: "Destination Group") {
                            guard authorized, !busy else { return }
                            destination = $0
                        }
                    }
                    Text("Sends an invitation card, not a forwarded message.").font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Invitations") {
                    if invites.isEmpty && !loading {
                        Text("No invitations").foregroundStyle(.secondary)
                    }
                    ForEach(invites) { invite in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(invite.code).font(.headline).textSelection(.enabled)
                            Text(invite.status + " · " + invite.inviteType.rawValue).font(
                                .subheadline)
                            if let target = invite.targetUid { Text("Recipient: \(target)") }
                            if let required = invite.requiredChatId {
                                Text("Required group: \(required)")
                            }
                            if let expiry = invite.expiresAt {
                                Text("Expires \(expiry.formatted())")
                            }
                            HStack {
                                Button("Copy URL") { copy(invite) }
                                Button("Send card") {
                                    operationTask = Task { await share(invite) }
                                }
                                .disabled(destination == nil)
                                Button("Revoke", role: .destructive) { revoking = invite }
                            }
                            .disabled(busy || !invite.isActive)
                        }
                        .padding(.vertical, 6)
                    }
                }
            } else if !loading && error == nil {
                Text("Only group administrators can manage invitations.")
            }
            if busy { ProgressView() }
            if let notice { Text(notice).foregroundStyle(.secondary) }
        }
        .disabled(busy || !isCurrentSession)
        .navigationTitle("Group Invitations")
        .formBackProtection(exitGuard, onBack: onBack)
        .onChange(of: isDirty, initial: true) { _, _ in refreshExitProtection() }
        .onChange(of: busy) { _, _ in refreshExitProtection() }
        .onChange(of: authorized) { _, allowed in
            if !allowed {
                accessRevoked = true
                operationTask?.cancel()
                revoking = nil
                invites = []
            }
            refreshExitProtection()
        }
        .onReceive(store.$groupInfoByChatID) { infos in
            guard isCurrentSession, let info = infos[chatID] else { return }
            groupInfo = info
        }
        .onReceive(store.chatAccessInvalidations) { invalidatedChatID in
            guard invalidatedChatID == chatID else { return }
            accessRevoked = true
            operationTask?.cancel()
            revoking = nil
            invites = []
            refreshExitProtection()
        }
        .task(id: chatID) { await load() }
        .onDisappear { operationTask?.cancel() }
        .confirmationDialog(
            "Revoke invitation?",
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            titleVisibility: .visible
        ) {
            if let invite = revoking {
                Button("Revoke", role: .destructive) {
                    operationTask = Task { await revoke(invite) }
                }
            }
            Button("Cancel", role: .cancel) { revoking = nil }
        } message: {
            Text("This invitation link will no longer allow anyone to join.")
        }
    }

    private var isCurrentSession: Bool {
        accountUID != nil && accountUID == store.currentUserProfile?.uid
            && sessionRevision == store.sessionRevision
    }

    private var authorized: Bool {
        let info = store.groupInfoByChatID[chatID] ?? groupInfo
        return isCurrentSession && !accessRevoked && info?.kind == .group
            && info?.myRole == .admin
    }

    private var isDirty: Bool {
        type != .generic || target != nil || requiredGroup != nil || expires
    }

    private func refreshExitProtection() {
        guard authorized else {
            exitGuard.unregister(owner: exitOwner)
            return
        }
        exitGuard.update(
            owner: exitOwner, isDirty: isDirty, isSubmitting: busy,
            accountID: accountUID, sessionRevision: sessionRevision)
    }

    private func load() async {
        guard isCurrentSession, !accessRevoked, !loading, !busy else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let info = try await store.groupInfo(chatID: chatID)
            guard isCurrentSession, !accessRevoked, !Task.isCancelled else { return }
            groupInfo = info
            guard authorized else {
                invites = []
                return
            }
            let page = try await store.listGroupInvites(chatID: chatID)
            guard authorized, !Task.isCancelled else { return }
            invites = page.invites
        } catch is CancellationError {} catch {
            guard isCurrentSession, !accessRevoked, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func create() async {
        guard !Task.isCancelled, authorized, !busy, type != .targeted || target != nil,
            type != .membership || requiredGroup != nil, !expires || expiry > Date()
        else { return }
        busy = true
        refreshExitProtection()
        error = nil
        notice = nil
        defer {
            busy = false
            if !Task.isCancelled { refreshExitProtection() }
        }
        do {
            let invite = try await store.createGroupInvite(
                body: .init(
                    chatId: chatID, inviteType: type,
                    targetUid: type == .targeted ? target?.uid : nil,
                    requiredChatId: type == .membership ? requiredGroup?.id : nil,
                    expiresAt: expires ? expiry : nil))
            guard authorized, !Task.isCancelled else { return }
            invites.insert(invite, at: 0)
            type = .generic
            target = nil
            requiredGroup = nil
            expires = false
            expiry = initialExpiry
        } catch is CancellationError {} catch {
            guard authorized, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func revoke(_ invite: GroupInvite) async {
        guard !Task.isCancelled, authorized, !busy else { return }
        busy = true
        refreshExitProtection()
        error = nil
        defer {
            busy = false
            if !Task.isCancelled { refreshExitProtection() }
        }
        do {
            try await store.revokeGroupInvite(id: invite.id)
            guard authorized, !Task.isCancelled else { return }
            invites.removeAll { $0.id == invite.id }
        } catch is CancellationError {} catch {
            guard authorized, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func share(_ invite: GroupInvite) async {
        guard !Task.isCancelled, authorized, !busy, let destination, invite.isActive else { return }
        busy = true
        refreshExitProtection()
        error = nil
        notice = nil
        defer {
            busy = false
            if !Task.isCancelled { refreshExitProtection() }
        }
        let operation = invite.id + ":" + destination.id
        let key = sendKeys[operation] ?? UUID().uuidString
        sendKeys[operation] = key
        do {
            try await store.sendGroupInvite(
                body: .init(
                    sourceChatId: chatID, inviteId: invite.id,
                    destinationChatId: destination.id, clientGeneratedId: key))
            guard authorized, !Task.isCancelled else { return }
            sendKeys.removeValue(forKey: operation)
            notice = "Invitation card sent."
        } catch is CancellationError {} catch {
            guard authorized, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func copy(_ invite: GroupInvite) {
        guard authorized, !busy, let url = GroupInviteLink.url(code: invite.code) else { return }
        // SwiftUI has no clipboard-write API; the system pasteboard is required for explicit Copy on each platform.
        #if os(iOS)
            UIPasteboard.general.url = url
        #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #endif
        notice = "Invitation URL copied."
    }
}

private struct GroupInviteUserPicker: View {
    let store: ChatStore
    let onSelect: (MemberSummary) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var members: [MemberSummary] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            TextField("Search users", text: $query).onSubmit { Task { await search() } }
            Button("Search") { Task { await search() } }.disabled(
                loading || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if loading { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(members, id: \.uid) { member in
                Button(member.username ?? String(member.uid)) {
                    onSelect(member)
                    dismiss()
                }
            }
        }
        .navigationTitle("Recipient")
    }
    private func search() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            members = try await store.searchUsers(query: query).members
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

private struct GroupInviteGroupPicker: View {
    let store: ChatStore
    let title: String
    let onSelect: (SocialGroupSummary) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var groups: [SocialGroupSummary] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        List {
            TextField("Search joined groups", text: $query).onSubmit {
                Task { await load(more: false) }
            }
            Button("Search") { Task { await load(more: false) } }.disabled(loading)
            if let error { Text(error).foregroundStyle(.red) }
            if loaded, query.trimmingCharacters(in: .whitespacesAndNewlines) != submittedQuery {
                Text(
                    submittedQuery.isEmpty
                        ? "Showing all joined groups. Submit Search to apply your changes."
                        : "Showing results for “\(submittedQuery)”. Submit Search to apply your changes."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if loaded && groups.isEmpty { Text("No matching joined groups") }
            ForEach(groups) { group in
                Button(group.name) {
                    onSelect(group)
                    dismiss()
                }
            }
            if cursor != nil {
                Button("Load more") { Task { await load(more: true) } }.disabled(loading)
            }
            if loading { ProgressView() }
        }
        .navigationTitle(title)
        .task { await load(more: false) }
    }
    private func load(more: Bool) async {
        guard !loading else { return }
        let requestedQuery =
            more ? submittedQuery : query.trimmingCharacters(in: .whitespacesAndNewlines)
        loading = true
        error = nil
        defer { loading = false }
        do {
            let page = try await store.searchJoinedGroups(
                query: requestedQuery, after: more ? cursor : nil)
            groups =
                more
                ? groups
                    + page.groups.filter { candidate in !groups.contains { $0.id == candidate.id } }
                : page.groups
            cursor = page.nextCursor
            submittedQuery = requestedQuery
            loaded = true
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
