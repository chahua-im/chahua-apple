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
    @ObservedObject var store: ChatStore
    @ObservedObject var exitGuard: FormExitGuard
    let onOpenChat: (ChatListItem) -> Void
    @State private var name = ""
    @State private var busy = false
    @State private var completed = false
    @State private var error: String?
    @State private var exitOwner = UUID()
    private let accountUID: Int32?
    private let sessionRevision: Int

    init(store: ChatStore, exitGuard: FormExitGuard, onOpenChat: @escaping (ChatListItem) -> Void) {
        self.store = store
        self.exitGuard = exitGuard
        self.onOpenChat = onOpenChat
        accountUID = store.currentUserProfile?.uid
        sessionRevision = store.sessionRevision
    }

    private var isCurrentSession: Bool {
        accountUID != nil && store.currentUserProfile?.uid == accountUID
            && store.sessionRevision == sessionRevision
    }

    private func updateProtection() {
        guard isCurrentSession else {
            exitGuard.unregister(owner: exitOwner)
            return
        }
        exitGuard.update(
            owner: exitOwner, isDirty: !completed && !name.isEmpty,
            isSubmitting: busy, accountID: accountUID, sessionRevision: sessionRevision)
    }

    var body: some View {
        Form {
            Section("Group name") {
                TextField("Name", text: $name)
                    .disabled(busy || completed || !isCurrentSession)
            }
            if let error { Text(error).foregroundStyle(.red) }
            Button {
                Task { await create() }
            } label: {
                if busy { ProgressView() } else { Text("Create Group") }
            }
            .disabled(
                name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy || completed
                    || !isCurrentSession)
        }
        .navigationTitle("Create Group")
        .onChange(of: name.isEmpty, initial: true) { _, _ in updateProtection() }
        .onChange(of: busy) { _, _ in updateProtection() }
        .onChange(of: completed) { _, _ in updateProtection() }
        .onChange(of: store.sessionRevision) { _, _ in updateProtection() }
    }

    private func create() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy, !completed, isCurrentSession else { return }
        busy = true
        updateProtection()
        error = nil
        defer {
            busy = false
            updateProtection()
        }
        do {
            let chat = try await store.createGroup(name: trimmed)
            guard isCurrentSession else { return }
            completed = true
            busy = false
            updateProtection()
            onOpenChat(chat)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

struct JoinGroupView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var exitGuard: FormExitGuard
    let onOpenChat: (ChatListItem) -> Void
    @StateObject private var model: JoinGroupModel
    @State private var exitOwner = UUID()

    private struct PreviewLookupIdentity: Hashable {
        let code: String?
        let accountUID: Int32?
        let sessionRevision: Int
    }

    init(
        store: ChatStore, exitGuard: FormExitGuard, initialCode: String = "",
        onOpenChat: @escaping (ChatListItem) -> Void
    ) {
        self.store = store
        self.exitGuard = exitGuard
        self.onOpenChat = onOpenChat
        _model = StateObject(wrappedValue: JoinGroupModel(store: store, initialCode: initialCode))
    }

    var body: some View {
        Form {
            Section("Invitation") {
                TextField("Invite code or URL", text: $model.input)
                    .autocorrectionDisabled()
                    .disabled(model.isSubmitting || model.completed || !model.isCurrentSession)
            }
            if model.isLoadingPreview { ProgressView() }
            if let error = model.error {
                Section {
                    Text(error).foregroundStyle(.red)
                    if model.canRetryPreview {
                        Button("Retry") { Task { await model.retryPreview() } }
                            .disabled(model.isLoadingPreview || model.isSubmitting)
                    }
                }
            }
            if let preview = model.preview, preview.invite.code == model.parsedCode {
                Section("Group preview") {
                    HStack {
                        AvatarView(
                            url: preview.chat.avatar.flatMap(URL.init(string:)),
                            displayName: preview.chat.name ?? AppLanguage.localized("Group"),
                            diameter: 48)
                        Text(preview.chat.name ?? AppLanguage.localized("Group"))
                    }
                    if let createdAt = preview.chat.createdAt {
                        LabeledContent("Group created") {
                            Text(createdAt, format: .dateTime.year().month(.wide).day())
                        }
                    }
                    if let description = preview.chat.description, !description.isEmpty {
                        Text(description)
                            .textSelection(.enabled)
                    }
                    if let mode = preview.chat.speakingMode, mode != .unrestricted {
                        LabeledContent("Speaking permissions", value: mode.localizedTitle)
                    }
                    if preview.alreadyMember { Text("You are already a member.") }
                    if let status = model.statusTitle {
                        LabeledContent("Invitation status", value: status)
                    }
                    if let expiry = preview.invite.expiresAt {
                        LabeledContent("Expires") {
                            Text(expiry, format: .dateTime.year().month().day().hour().minute())
                        }
                    } else {
                        Text("This invitation never expires.")
                    }
                }
            }
            Button {
                Task {
                    if let chat = await model.submit() {
                        updateProtection()
                        onOpenChat(chat)
                    }
                }
            } label: {
                if model.isSubmitting { ProgressView() } else { Text(model.actionTitle) }
            }
            .disabled(!model.canSubmit)
        }
        .navigationTitle("Join Group")
        .onChange(of: model.isDirty, initial: true) { _, _ in updateProtection() }
        .onChange(of: model.isSubmitting) { _, _ in updateProtection() }
        .onChange(of: model.completed) { _, _ in updateProtection() }
        .onChange(of: store.sessionRevision) { _, _ in updateProtection() }
        .task(
            id: PreviewLookupIdentity(
                code: model.parsedCode, accountUID: store.currentUserProfile?.uid,
                sessionRevision: store.sessionRevision)
        ) {
            await model.loadPreview()
        }
        .onDisappear { model.cancel() }
    }

    private func updateProtection() {
        guard model.isCurrentSession else {
            exitGuard.unregister(owner: exitOwner)
            return
        }
        exitGuard.update(
            owner: exitOwner, isDirty: model.isDirty, isSubmitting: model.isSubmitting,
            accountID: store.currentUserProfile?.uid, sessionRevision: store.sessionRevision)
    }
}
