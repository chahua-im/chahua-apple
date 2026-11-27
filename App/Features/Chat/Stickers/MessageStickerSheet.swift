import ChahuaAPI
import SwiftUI

struct MessageStickerSheet: View {
    @ObservedObject var library: StickerLibrary
    let message: MessageResponse
    let sourceIsAvailable: () -> Bool
    let onAdded: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.voicePlaybackHeaderRoute) private var voiceHeaderRoute
    @State private var packID = ""
    @State private var emoji = ""
    @State private var name = ""
    @State private var newPackName = ""
    @State private var showsCreatePack = false
    @State private var isBusy = false
    @State private var saveTask: Task<Void, Never>?
    @State private var errorMessage: String?

    private var ownedPacks: [StickerPackSummary] {
        library.packs.filter { library.isOwnedPack($0.id) }
    }

    private var normalizedEmoji: String {
        StickerPreferences.normalizedEmojiSequences(
            emoji, maximum: StickerPreferences.maximumStickerEmojiCount
        ).joined()
    }

    private var canAdd: Bool {
        !isBusy && !library.isLoading && ownedPacks.contains { $0.id == packID }
            && !normalizedEmoji.isEmpty
            && name.trimmingCharacters(in: .whitespacesAndNewlines).count <= 255
            && !library.pendingMutationIDs.contains(packID)
            && !library.hasUncertainMessageStickerSave(message, packID: packID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sticker Pack") {
                    if library.isLoading {
                        ProgressView("Loading sticker packs…")
                    } else if ownedPacks.isEmpty {
                        Text("Create a pack to add this image as a sticker.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Sticker Pack", selection: $packID) {
                            ForEach(ownedPacks) { pack in
                                Text(verbatim: pack.name).tag(pack.id)
                            }
                        }
                    }
                    Button("Create Pack", systemImage: "plus") {
                        newPackName = ""
                        showsCreatePack = true
                    }
                    .disabled(isBusy || library.isLoading)
                    if !library.isLoading, !library.hasLoadedLibrary {
                        Button("Retry") { reload() }.disabled(isBusy)
                    }
                }
                Section("Sticker Details") {
                    // Normalize only at submission, never rewrite active IME composition.
                    TextField("Emoji", text: $emoji, prompt: Text("e.g. 😊"))
                    TextField("Name (optional)", text: $name)
                    Text("Choose one to four emoji. The name is optional.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(isBusy)
                if library.hasUncertainMessageStickerSave(message, packID: packID) {
                    Section {
                        Text(
                            "Couldn’t confirm whether the sticker was added. Check the pack before trying again."
                        )
                        .foregroundStyle(.secondary)
                        if let accountID = library.accountID {
                            NavigationLink("Sticker Pack") {
                                StickerPackDetailSettingsView(
                                    library: library, currentUserID: accountID, packID: packID
                                )
                                .task { _ = await library.loadPack(packID, force: true) }
                            }
                        }
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
                if isBusy { ProgressView("Adding sticker…") }
            }
            .navigationTitle("Add Sticker")
            .voicePlaybackHeader()
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addSticker() }.disabled(!canAdd)
                }
            }
            .alert("Create Sticker Pack", isPresented: $showsCreatePack) {
                TextField("Pack name", text: $newPackName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { createPack() }
                    .disabled(
                        newPackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || newPackName.trimmingCharacters(in: .whitespacesAndNewlines).count
                                > 255
                    )
            }
        }
        .environment(
            \.voicePlaybackHeaderRoute,
            voiceHeaderRoute?.guarded { action in if !isBusy { action() } }
        )
        .interactiveDismissDisabled(isBusy)
        .task {
            await library.refresh()
            selectAvailablePack()
            if let error = library.error {
                errorMessage = error
                library.error = nil
            }
        }
        .onChange(of: library.packs) { _, _ in selectAvailablePack() }
        .onDisappear { saveTask?.cancel() }
        #if os(macOS)
            .frame(minWidth: 360, idealWidth: 420, minHeight: 360)
        #endif
    }

    private func selectAvailablePack() {
        if !ownedPacks.contains(where: { $0.id == packID }) {
            packID = ownedPacks.first?.id ?? ""
        }
    }

    private func reload() {
        guard !isBusy else { return }
        saveTask = Task {
            await library.refresh()
            guard !Task.isCancelled else { return }
            selectAvailablePack()
            errorMessage = library.error
            library.error = nil
        }
    }

    private func createPack() {
        guard !isBusy, sourceIsAvailable() else {
            showUnavailableSource()
            return
        }
        let packName = newPackName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !packName.isEmpty, packName.count <= 255 else { return }
        isBusy = true
        errorMessage = nil
        saveTask = Task {
            defer { isBusy = false }
            guard let pack = await library.createPack(name: packName) else {
                guard !Task.isCancelled else { return }
                errorMessage = library.error
                library.error = nil
                return
            }
            guard !Task.isCancelled else { return }
            packID = pack.id
        }
    }

    private func addSticker() {
        guard canAdd else { return }
        guard sourceIsAvailable() else {
            showUnavailableSource()
            return
        }
        let targetPackID = packID
        let submittedEmoji = normalizedEmoji
        let submittedName = name
        isBusy = true
        errorMessage = nil
        saveTask = Task {
            defer { isBusy = false }
            guard sourceIsAvailable() else {
                showUnavailableSource()
                return
            }
            guard
                await library.addMessageSticker(
                    message, toPack: targetPackID, emoji: submittedEmoji, name: submittedName)
                    != nil
            else {
                guard !Task.isCancelled else { return }
                errorMessage =
                    library.error
                    ?? AppLanguage.localized("Couldn’t add sticker. Please try again.")
                library.error = nil
                return
            }
            guard !Task.isCancelled else { return }
            onAdded()
            dismiss()
        }
    }

    private func showUnavailableSource() {
        errorMessage = AppLanguage.localized(
            "Source image unavailable. The message may have changed or you may have lost access.")
    }
}
