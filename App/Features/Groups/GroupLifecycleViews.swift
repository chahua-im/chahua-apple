import ChahuaAPI
import Foundation
import SwiftUI

nonisolated enum GroupInviteLink {
    static func code(from value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty,
            value.rangeOfCharacter(
                from: CharacterSet(charactersIn: "/?#:").union(.whitespacesAndNewlines)) == nil
        {
            return value
        }
        guard let components = URLComponents(string: value),
            components.scheme == nil
                || ["https", "http"].contains(components.scheme?.lowercased() ?? "")
        else { return nil }
        let parts = components.path.split(separator: "/")
        guard parts.count == 3, parts[0] == "chats", parts[1] == "join",
            let code = String(parts[2]).removingPercentEncoding, !code.isEmpty,
            code.rangeOfCharacter(
                from: CharacterSet(charactersIn: "/?#:").union(.whitespacesAndNewlines)) == nil
        else { return nil }
        return code
    }

    @MainActor
    static func url(code: String) -> URL? {
        var components = URLComponents(
            url: AppConfiguration.applicationURL, resolvingAgainstBaseURL: false)
        components?.path = "/chats/join/" + code
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }
}

struct CreateGroupView: View {
    let store: ChatStore
    let onOpenChat: (ChatListItem) -> Void
    @State private var name = ""
    @State private var busy = false
    @State private var completed = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Group name") {
                TextField("Name", text: $name)
                    .disabled(busy || completed)
            }
            if let error { Text(error).foregroundStyle(.red) }
            Button {
                Task { await create() }
            } label: {
                if busy { ProgressView() } else { Text("Create Group") }
            }
            .disabled(
                name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy || completed)
        }
        .navigationTitle("Create Group")
    }

    private func create() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy, !completed else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let chat = try await store.createGroup(name: trimmed)
            completed = true
            onOpenChat(chat)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

struct JoinGroupView: View {
    let store: ChatStore
    let onOpenChat: (ChatListItem) -> Void
    @State private var input: String
    @State private var preview: GroupInvitePreview?
    @State private var busy = false
    @State private var completed = false
    @State private var error: String?
    private let initialCode: String

    init(store: ChatStore, initialCode: String = "", onOpenChat: @escaping (ChatListItem) -> Void) {
        self.store = store
        self.initialCode = initialCode
        self.onOpenChat = onOpenChat
        _input = State(initialValue: initialCode)
    }

    var body: some View {
        Form {
            Section("Invitation") {
                TextField("Invite code or URL", text: $input)
                    .autocorrectionDisabled()
                    .disabled(busy || completed)
                Button("Preview invitation") { Task { await lookup() } }
                    .disabled(GroupInviteLink.code(from: input) == nil || busy || completed)
            }
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
            if let preview, preview.invite.code == GroupInviteLink.code(from: input) {
                Section("Group preview") {
                    HStack {
                        AvatarView(
                            url: preview.chat.avatar.flatMap(URL.init(string:)),
                            displayName: preview.chat.name ?? "Group", diameter: 48)
                        Text(preview.chat.name ?? "Group")
                    }
                    if let description = preview.chat.description, !description.isEmpty {
                        Text(description)
                    }
                    Text(
                        preview.alreadyMember ? "You are already a member." : preview.invite.status)
                    if let expiry = preview.invite.expiresAt {
                        Text("Expires \(expiry.formatted())")
                    }
                    Button(preview.alreadyMember ? "Open Group" : "Join Group") {
                        Task { await join(preview) }
                    }
                    .disabled(
                        busy || completed || (!preview.alreadyMember && !preview.invite.isActive))
                }
            }
        }
        .navigationTitle("Join Group")
        .onChange(of: input) { _, _ in
            preview = nil
            error = nil
        }
        .task { if !initialCode.isEmpty { await lookup() } }
    }

    private func lookup() async {
        guard !busy, !completed, let code = GroupInviteLink.code(from: input) else { return }
        busy = true
        error = nil
        preview = nil
        defer { busy = false }
        do {
            let response = try await store.previewGroupInvite(code: code)
            guard GroupInviteLink.code(from: input) == code else { return }
            preview = response
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func join(_ preview: GroupInvitePreview) async {
        guard !busy, !completed, preview.invite.code == GroupInviteLink.code(from: input),
            preview.alreadyMember || preview.invite.isActive
        else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let chat =
                preview.alreadyMember
                ? store.groupChatSnapshot(preview.chat)
                : try await store.redeemGroupInvite(code: preview.invite.code)
            completed = true
            onOpenChat(chat)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
