import ChahuaAPI
import Foundation
import SwiftUI

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

struct GroupInvitesView: View {
    let store: ChatStore
    let chatID: String
    @State private var authorized = false
    @State private var loading = false
    @State private var busy = false
    @State private var invites: [GroupInvite] = []
    @State private var type = GroupInviteType.generic
    @State private var target: MemberSummary?
    @State private var requiredGroup: SocialGroupSummary?
    @State private var destination: SocialGroupSummary?
    @State private var expires = false
    @State private var expiry = Date().addingTimeInterval(86_400)
    @State private var revoking: GroupInvite?
    @State private var error: String?
    @State private var notice: String?
    @State private var sendKeys: [String: String] = [:]

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
                            GroupInviteUserPicker(store: store) { target = $0 }
                        }
                    }
                    if type == .membership {
                        NavigationLink(requiredGroup?.name ?? "Choose prerequisite group") {
                            GroupInviteGroupPicker(store: store, title: "Prerequisite Group") {
                                requiredGroup = $0
                            }
                        }
                    }
                    Toggle("Set expiry", isOn: $expires)
                    if expires { DatePicker("Expires", selection: $expiry, in: Date()...) }
                    Button("Create invitation") { Task { await create() } }
                        .disabled(
                            busy || (type == .targeted && target == nil)
                                || (type == .membership && requiredGroup == nil)
                                || (expires && expiry <= Date()))
                }
                Section("Send invite card") {
                    NavigationLink(destination?.name ?? "Choose destination group") {
                        GroupInviteGroupPicker(store: store, title: "Destination Group") {
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
                                Button("Send card") { Task { await share(invite) } }.disabled(
                                    destination == nil)
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
        .navigationTitle("Group Invitations")
        .task(id: chatID) { await load() }
        .confirmationDialog(
            "Revoke invitation?",
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            titleVisibility: .visible
        ) {
            if let invite = revoking {
                Button("Revoke", role: .destructive) { Task { await revoke(invite) } }
            }
            Button("Cancel", role: .cancel) { revoking = nil }
        } message: {
            Text("This invitation link will no longer allow anyone to join.")
        }
    }

    private func load() async {
        guard !loading, !busy else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let info = try await store.groupInfo(chatID: chatID)
            authorized = info.kind == .group && info.myRole == .admin
            guard authorized else {
                invites = []
                return
            }
            invites = try await store.listGroupInvites(chatID: chatID).invites
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func create() async {
        guard authorized, !busy, type != .targeted || target != nil,
            type != .membership || requiredGroup != nil, !expires || expiry > Date()
        else { return }
        busy = true
        error = nil
        notice = nil
        defer { busy = false }
        do {
            let invite = try await store.createGroupInvite(
                body: .init(
                    chatId: chatID, inviteType: type,
                    targetUid: type == .targeted ? target?.uid : nil,
                    requiredChatId: type == .membership ? requiredGroup?.id : nil,
                    expiresAt: expires ? expiry : nil))
            invites.insert(invite, at: 0)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func revoke(_ invite: GroupInvite) async {
        guard authorized, !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await store.revokeGroupInvite(id: invite.id)
            invites.removeAll { $0.id == invite.id }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func share(_ invite: GroupInvite) async {
        guard authorized, !busy, let destination, invite.isActive else { return }
        busy = true
        error = nil
        notice = nil
        defer { busy = false }
        let operation = invite.id + ":" + destination.id
        let key = sendKeys[operation] ?? UUID().uuidString
        sendKeys[operation] = key
        do {
            try await store.sendGroupInvite(
                body: .init(
                    sourceChatId: chatID, inviteId: invite.id,
                    destinationChatId: destination.id, clientGeneratedId: key))
            sendKeys.removeValue(forKey: operation)
            notice = "Invitation card sent."
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func copy(_ invite: GroupInvite) {
        guard let url = GroupInviteLink.url(code: invite.code) else { return }
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
