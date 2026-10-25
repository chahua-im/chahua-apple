import ChahuaAPI
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct GroupEditingView: View {
    @ObservedObject var store: ChatStore
    let info: GroupInfoResponse
    let onUpdated: (GroupInfoResponse) -> Void
    @State private var name: String
    @State private var description: String
    @State private var savedName: String
    @State private var savedDescription: String
    @State private var selectingAvatar = false
    @State private var busy = false
    @State private var error: String?
    @State private var avatar: LocalOutgoingAttachment?
    @State private var progress = 0.0
    @State private var uploadingAvatar = false
    @State private var task: Task<Void, Never>?
    @State private var directory: URL
    @State private var speakingMode: SpeakingMode?
    @State private var membershipVisibility: MembershipMessageVisibility?
    private let sessionRevision: Int
    private let accountUID: Int32?

    init(
        store: ChatStore, info: GroupInfoResponse, onUpdated: @escaping (GroupInfoResponse) -> Void
    ) {
        self.store = store
        self.info = info
        self.onUpdated = onUpdated
        accountUID = store.currentUserProfile?.uid
        sessionRevision = store.sessionRevision
        _speakingMode = State(initialValue: info.speakingMode)
        _membershipVisibility = State(initialValue: info.membershipMessagePolicy?.visibility)
        _directory = State(
            initialValue: FileManager.default.temporaryDirectory.appendingPathComponent(
                "group-avatar-\(UUID().uuidString)", isDirectory: true))
        _name = State(initialValue: info.name ?? "")
        _description = State(initialValue: info.description ?? "")
        _savedName = State(initialValue: info.name ?? "")
        _savedDescription = State(initialValue: info.description ?? "")
    }

    var body: some View {
        Form {
            Section("Group name") {
                TextField("Name", text: $name)
                Button("Save name") {
                    task = Task {
                        await save(
                            .init(name: name.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                }
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || name == savedName)
            }
            Section("Description") {
                TextEditor(text: $description).frame(minHeight: 100)
                Button("Save description") {
                    task = Task { await save(.init(description: description)) }
                }
                .disabled(description == savedDescription)
                Text("An empty description clears the existing description.").font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Speaking permissions") {
                if let currentMode = currentInfo.speakingMode {
                    Picker(
                        "Speaking permissions",
                        selection: Binding(
                            get: { speakingMode ?? currentMode },
                            set: { speakingMode = $0 })
                    ) {
                        ForEach(SpeakingMode.allCases, id: \.self) { mode in
                            Text(mode.localizedTitle).tag(mode)
                        }
                    }
                    .accessibilityIdentifier("group-speaking-mode-picker")
                    Button("Save speaking permissions") {
                        task = Task { await saveSpeakingMode() }
                    }
                    .disabled(speakingMode == nil || speakingMode == currentMode)
                    if let mode = speakingMode ?? currentInfo.speakingMode {
                        Text(mode.restrictionExplanation)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(
                        "Group and personal restrictions use the stricter setting. Admins are exempt."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Speaking permissions are unavailable.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Membership messages") {
                if let currentVisibility = currentInfo.membershipMessagePolicy?.visibility {
                    Picker(
                        "Who can see membership messages",
                        selection: Binding(
                            get: { membershipVisibility ?? currentVisibility },
                            set: { membershipVisibility = $0 })
                    ) {
                        ForEach(MembershipMessageVisibility.allCases, id: \.self) { visibility in
                            Text(visibility.localizedTitle).tag(visibility)
                        }
                    }
                    .accessibilityIdentifier("group-membership-visibility-picker")
                    Button("Save membership message policy") {
                        guard let membershipVisibility else { return }
                        task = Task {
                            await save(.init(membershipMessageVisibility: membershipVisibility))
                        }
                    }
                    .disabled(
                        membershipVisibility == nil || membershipVisibility == currentVisibility)
                    Text(
                        "Applies to past and new membership messages. Account preferences may hide them further."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Membership message policy is unavailable.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Avatar") {
                Button("Choose image…") { selectingAvatar = true }
                if let avatar {
                    Text(avatar.fileName)
                    Button("Upload avatar") { task = Task { await uploadAvatar(avatar) } }
                }
                if uploadingAvatar { ProgressView(value: progress) }
            }
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .disabled(busy || !authorized)
        .navigationTitle("Edit Group")
        .fileImporter(isPresented: $selectingAvatar, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                task = Task { await importAvatar(url) }
            case .failure(let error): self.error = error.localizedDescription
            }
        }
        .onChange(of: currentInfo.speakingMode) { oldValue, newValue in
            if speakingMode == nil || speakingMode == oldValue { speakingMode = newValue }
        }
        .onChange(of: currentInfo.membershipMessagePolicy?.visibility) { oldValue, newValue in
            if membershipVisibility == nil || membershipVisibility == oldValue {
                membershipVisibility = newValue
            }
        }
        .onDisappear {
            task?.cancel()
            let directory = directory
            Task.detached { try? FileManager.default.removeItem(at: directory) }
        }
    }

    private var currentInfo: GroupInfoResponse {
        store.groupInfoByChatID[info.id] ?? info
    }

    private var authorized: Bool {
        store.groupInfoByChatID[info.id]?.myRole == .admin
            && accountUID == store.currentUserProfile?.uid
            && sessionRevision == store.sessionRevision
    }

    private func saveSpeakingMode() async {
        guard !busy, authorized, let speakingMode else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let updated = try await store.updateGroupSpeakingMode(
                chatID: info.id, speakingMode: speakingMode)
            guard authorized, !Task.isCancelled else { return }
            self.speakingMode = updated.speakingMode
            if let updatedInfo = store.groupInfoByChatID[info.id] { onUpdated(updatedInfo) }
        } catch is CancellationError {} catch {
            guard authorized, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func save(_ body: UpdateGroupBody) async {
        guard !busy, authorized else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let updated = try await store.updateGroup(chatID: info.id, body: body)
            guard authorized, !Task.isCancelled else { return }
            if body.name != nil {
                savedName = updated.name ?? ""
                name = savedName
            }
            if body.description != nil {
                savedDescription = updated.description ?? ""
                description = savedDescription
            }
            if body.membershipMessageVisibility != nil {
                membershipVisibility = updated.membershipMessagePolicy?.visibility
            }
            onUpdated(updated)
        } catch is CancellationError {} catch {
            guard authorized, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func importAvatar(_ url: URL) async {
        guard !busy, authorized else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let imported = try await OutgoingImageProcessor(directory: directory).importImage(
                from: url, directory: directory, position: 0)
            guard imported.mimeType.hasPrefix("image/") else {
                throw OutgoingImageError.unsupportedImage
            }
            guard authorized else { return }
            avatar = imported
        } catch is CancellationError {} catch {
            guard authorized, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func uploadAvatar(_ avatar: LocalOutgoingAttachment) async {
        guard !busy, authorized else { return }
        busy = true
        uploadingAvatar = true
        error = nil
        progress = 0
        defer {
            busy = false
            uploadingAvatar = false
        }
        do {
            let allocation = try await store.groupAvatarUpload(
                chatID: info.id, filename: avatar.fileName,
                contentType: avatar.mimeType, size: avatar.byteCount, width: avatar.width,
                height: avatar.height)
            guard authorized, !Task.isCancelled else { return }
            try await OutgoingAttachmentUploader(directory: directory).upload(
                file: URL(fileURLWithPath: avatar.sourcePath),
                allocation: .init(
                    attachmentId: allocation.imageId, uploadURL: allocation.uploadUrl,
                    headers: allocation.uploadHeaders)
            ) { value in
                Task { @MainActor in
                    guard authorized, !Task.isCancelled else { return }
                    progress = value
                }
            }
            try Task.checkCancellation()
            guard authorized else { return }
            let updated = try await store.updateGroup(
                chatID: info.id, body: .init(avatarImageId: allocation.imageId))
            guard authorized, !Task.isCancelled else { return }
            self.avatar = nil
            onUpdated(updated)
        } catch is CancellationError {} catch {
            guard authorized, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
