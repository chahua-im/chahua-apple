import ChahuaAPI
import SwiftUI
import UniformTypeIdentifiers

struct ReactionManagementView: View {
    @ObservedObject var library: StickerLibrary
    let currentUserID: Int32

    @State private var pinnedReactionText = ""

    private let reactionChoices = ["👍", "❤️", "😂", "😮", "😢", "🎉", "👏", "🔥", "🙏", "👀"]

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Pinned Reaction Emojis")
                        Spacer()
                        Text(
                            "\(library.pinnedReactions.count)/\(StickerPreferences.maximumPinnedReactions)"
                        )
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                    TextField("Add up to 5 emoji", text: $pinnedReactionText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: pinnedReactionText) { _, value in
                            let normalized = StickerPreferences.normalizedPinnedReactions(value)
                            let normalizedText = normalized.joined()
                            if pinnedReactionText != normalizedText {
                                pinnedReactionText = normalizedText
                            }
                            if library.pinnedReactions != normalized {
                                library.setPinnedReactions(normalized)
                            }
                        }
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 38), spacing: 8)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(reactionChoices, id: \.self) { emoji in
                            Button(emoji) { appendPinnedReaction(emoji) }
                                .buttonStyle(.bordered)
                                .disabled(
                                    library.pinnedReactions.count
                                        >= StickerPreferences.maximumPinnedReactions
                                        && !library.pinnedReactions.contains(emoji)
                                )
                                .accessibilityLabel("Pin \(emoji) reaction")
                        }
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Pinned reactions appear first in the message reaction menu.")
            }
        }
        .navigationTitle("Reaction Management")
        .task(id: currentUserID) {
            library.setAccount(currentUserID)
            pinnedReactionText = library.pinnedReactions.joined()
        }
        .onChange(of: library.pinnedReactions) { _, reactions in
            let text = reactions.joined()
            if pinnedReactionText != text { pinnedReactionText = text }
        }
    }

    private func appendPinnedReaction(_ emoji: String) {
        var reactions = library.pinnedReactions
        if let index = reactions.firstIndex(of: emoji) {
            reactions.remove(at: index)
        } else if reactions.count < StickerPreferences.maximumPinnedReactions {
            reactions.append(emoji)
        }
        library.setPinnedReactions(reactions)
    }
}

struct StickerPackManagementView: View {
    @ObservedObject var library: StickerLibrary
    let currentUserID: Int32

    @State private var showsCreatePack = false
    @State private var newPackName = ""
    @State private var isCreatingPack = false
    @State private var createdPackID: String?

    var body: some View {
        List {
            Section {
                Button {
                    newPackName = ""
                    showsCreatePack = true
                } label: {
                    if isCreatingPack {
                        Label("Creating Pack…", systemImage: "plus")
                            .overlay(alignment: .leading) { ProgressView().offset(x: -24) }
                    } else {
                        Label("Create New Pack", systemImage: "plus")
                    }
                }
                .disabled(
                    isCreatingPack || library.pendingMutationIDs.contains("create-sticker-pack"))
            }

            packsSection
        }
        .navigationTitle("Manage Sticker Packs")
        #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                    .disabled(library.packs.count < 2 || !library.pendingMutationIDs.isEmpty)
                }
            }
        #endif
        .task(id: currentUserID) {
            library.setAccount(currentUserID)
            await library.refresh()
        }
        .refreshable { await library.refresh() }
        .navigationDestination(item: $createdPackID) { packID in
            StickerPackDetailSettingsView(
                library: library, currentUserID: currentUserID, packID: packID)
        }
        .alert("New Sticker Pack", isPresented: $showsCreatePack) {
            TextField("Pack name", text: $newPackName)
            Button("Cancel", role: .cancel) { newPackName = "" }
            Button("Create") { createPack() }
                .disabled(
                    newPackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || isCreatingPack)
        } message: {
            Text("Give your sticker pack a name.")
        }
        .alert(
            "Stickers",
            isPresented: Binding(
                get: { library.error != nil }, set: { if !$0 { library.error = nil } })
        ) {
            Button("OK") { library.error = nil }
        } message: {
            Text(currentErrorMessage)
        }
    }

    @ViewBuilder
    private var packsSection: some View {
        Section {
            if library.isLoading && library.packs.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("Loading sticker packs…")
                    Spacer()
                }
            } else if library.packs.isEmpty {
                ContentUnavailableView(
                    "No Sticker Packs", systemImage: "square.stack",
                    description: Text("Create a pack or subscribe to one from a sticker message."))
            } else {
                ForEach(library.packs) { pack in
                    NavigationLink {
                        StickerPackDetailSettingsView(
                            library: library, currentUserID: currentUserID, packID: pack.id)
                    } label: {
                        StickerPackRow(
                            pack: pack, isOwned: library.isOwnedPack(pack.id),
                            isMutating: library.pendingMutationIDs.contains(pack.id))
                    }
                    .disabled(library.pendingMutationIDs.contains(pack.id))
                }
                .onMove(perform: movePacks)
            }
        } header: {
            Text("Sticker Packs")
        } footer: {
            automaticSortFooter
        }
    }

    @ViewBuilder
    private var automaticSortFooter: some View {
        if library.autoSortPacks
            && library.packs.count > StickerPreferences.automaticSortLimit
        {
            Text("Packs below the first 20 are not auto-sorted.")
        }
    }

    private var currentErrorMessage: String { library.error ?? "" }

    private func createPack() {
        let name = newPackName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isCreatingPack else { return }
        isCreatingPack = true
        Task {
            defer { isCreatingPack = false }
            guard let pack = await library.createPack(name: name) else { return }
            newPackName = ""
            showsCreatePack = false
            createdPackID = pack.id
        }
    }

    private func movePacks(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty, library.pendingMutationIDs.isEmpty else { return }
        var reordered = library.packs
        reordered.move(fromOffsets: source, toOffset: destination)
        let timestamp = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        let updates = reordered.enumerated().map { index, pack in
            StickerPackOrderUpdate(
                stickerPackId: pack.id, lastUsedOn: timestamp - Int64(index), isAutoSort: nil)
        }
        Task { _ = await library.updatePackOrder(updates) }
    }
}

private struct StickerPackRow: View {
    let pack: StickerPackSummary
    let isOwned: Bool
    let isMutating: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let preview = pack.previewSticker {
                    StickerMediaView(media: preview.media, emoji: preview.emoji)
                } else {
                    Image(systemName: "square.stack")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isOwned {
                        Text("Owned")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.14), in: Capsule())
                    }
                    Text(pack.name).lineLimit(1)
                }
                Text("\(pack.stickerCount) \(pack.stickerCount == 1 ? "sticker" : "stickers")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isMutating { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 2)
    }
}

private struct StickerPackDetailSettingsView: View {
    @ObservedObject var library: StickerLibrary
    let currentUserID: Int32
    let packID: String

    @Environment(\.dismiss) private var dismiss
    @State private var showsRename = false
    @State private var renamePackName = ""
    @State private var confirmsDelete = false
    @State private var confirmsUnsubscribe = false
    @State private var stickerToRemove: MessageStickerResponse?
    @State private var showsFileImporter = false
    @State private var selectedFile: StickerImport?

    private var detail: StickerPackDetailResponse? { library.packDetails[packID] }
    private var pack: StickerPackSummary? {
        detail?.pack ?? library.packs.first(where: { $0.id == packID })
    }
    private var isOwned: Bool {
        library.isOwnedPack(packID) || pack?.ownerUid == currentUserID
    }

    var body: some View {
        Group {
            if let detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if library.pendingMutationIDs.contains(packID) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Updating sticker pack…")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                        }
                        if isOwned {
                            Text("Select a sticker to remove it from this pack.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        }
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10
                        ) {
                            if isOwned { addStickerCell }
                            ForEach(detail.stickers, id: \.id) { sticker in
                                stickerCell(sticker)
                            }
                        }
                        .padding()
                    }
                }
            } else if library.loadingPackIDs.contains(packID) || library.isLoading {
                ProgressView("Loading sticker pack…")
            } else {
                ContentUnavailableView(
                    "Sticker Pack Unavailable", systemImage: "square.stack",
                    description: Text("Try refreshing to load this pack."))
            }
        }
        .navigationTitle(pack?.name ?? "Sticker Pack")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarContent }
        .task(id: packID) { _ = await library.loadPack(packID) }
        .refreshable { _ = await library.loadPack(packID, force: true) }
        .fileImporter(
            isPresented: $showsFileImporter, allowedContentTypes: StickerImport.allowedContentTypes,
            allowsMultipleSelection: false, onCompletion: importSticker
        )
        .sheet(item: $selectedFile) { file in
            StickerUploadSheet(library: library, packID: packID, file: file)
        }
        .alert("Rename Pack", isPresented: $showsRename) {
            TextField("Pack name", text: $renamePackName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { renamePack() }
                .disabled(renamePackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(
            "Remove this sticker from the pack?", isPresented: stickerRemovalBinding
        ) {
            Button("Remove Sticker", role: .destructive) { removeSticker() }
            Button("Cancel", role: .cancel) { stickerToRemove = nil }
        }
        .confirmationDialog("Delete this sticker pack?", isPresented: $confirmsDelete) {
            Button("Delete Pack", role: .destructive) { deletePack() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The pack and its contents list will be removed.")
        }
        .confirmationDialog(
            "Remove this pack from your collection?", isPresented: $confirmsUnsubscribe
        ) {
            Button("Unsubscribe", role: .destructive) { unsubscribe() }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Stickers",
            isPresented: Binding(
                get: { library.error != nil }, set: { if !$0 { library.error = nil } })
        ) {
            Button("OK") { library.error = nil }
        } message: {
            Text(currentErrorMessage)
        }
    }

    private var currentErrorMessage: String { library.error ?? "" }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isOwned {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Rename Pack", systemImage: "pencil") {
                    renamePackName = pack?.name ?? ""
                    showsRename = true
                }
                .disabled(library.pendingMutationIDs.contains(packID))
                Button(role: .destructive) {
                    confirmsDelete = true
                } label: {
                    Label("Delete Pack", systemImage: "trash")
                }
                .disabled(library.pendingMutationIDs.contains(packID))
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button("Unsubscribe", role: .destructive) { confirmsUnsubscribe = true }
                    .disabled(library.pendingMutationIDs.contains(packID))
            }
        }
    }

    private var addStickerCell: some View {
        Button {
            showsFileImporter = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.title2.weight(.medium))
                Text("Add Sticker").font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(library.pendingMutationIDs.contains(packID))
        .accessibilityLabel("Add sticker")
    }

    @ViewBuilder
    private func stickerCell(_ sticker: MessageStickerResponse) -> some View {
        if isOwned {
            Button {
                stickerToRemove = sticker
            } label: {
                stickerTile(sticker)
            }
            .buttonStyle(.plain)
            .disabled(library.pendingMutationIDs.contains(packID))
            .accessibilityLabel("Remove \(sticker.name ?? sticker.emoji)")
        } else {
            stickerTile(sticker)
                .accessibilityLabel(sticker.name ?? sticker.emoji)
        }
    }

    private func stickerTile(_ sticker: MessageStickerResponse) -> some View {
        ZStack(alignment: .topTrailing) {
            StickerMediaView(media: sticker.media, emoji: sticker.emoji)
                .frame(maxWidth: .infinity, minHeight: 92)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            if isOwned {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .accessibilityHidden(true)
            }
        }
    }

    private var stickerRemovalBinding: Binding<Bool> {
        Binding(
            get: { stickerToRemove != nil }, set: { if !$0 { stickerToRemove = nil } })
    }

    private func importSticker(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            selectedFile = try StickerImport(validating: url)
        } catch {
            library.error = error.localizedDescription
        }
    }

    private func renamePack() {
        guard let pack else { return }
        let name = renamePackName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != pack.name else {
            showsRename = false
            return
        }
        Task {
            guard await library.updatePack(id: packID, name: name) != nil else { return }
            showsRename = false
        }
    }

    private func removeSticker() {
        guard let sticker = stickerToRemove else { return }
        stickerToRemove = nil
        Task { _ = await library.removeSticker(fromPack: packID, stickerID: sticker.id) }
    }

    private func deletePack() {
        Task {
            if await library.deletePack(id: packID) { dismiss() }
        }
    }

    private func unsubscribe() {
        guard let pack else { return }
        Task {
            if await library.setSubscribed(false, pack: pack) { dismiss() }
        }
    }
}

private final class StickerImport: Identifiable {
    static let maximumFileSize = 10 * 1_024 * 1_024
    static let webM = UTType(filenameExtension: "webm") ?? .movie
    static let allowedContentTypes: [UTType] = [.image, webM]

    let id = UUID()
    let url: URL
    let fileName: String
    let contentType: String
    let isWebM: Bool
    private var hasSecurityScope: Bool

    init(validating url: URL) throws {
        self.url = url
        hasSecurityScope = url.startAccessingSecurityScopedResource()
        do {
            let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .nameKey])
            guard let size = values.fileSize, size <= Self.maximumFileSize else {
                throw StickerImportError.fileTooLarge
            }
            let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
            let extensionIsWebM = url.pathExtension.caseInsensitiveCompare("webm") == .orderedSame
            let isHEIC = type?.identifier == "public.heic" || type?.identifier == "public.heif"
            guard !isHEIC, type?.conforms(to: .image) == true || extensionIsWebM else {
                throw StickerImportError.unsupportedType
            }
            guard let contentType = extensionIsWebM ? "video/webm" : type?.preferredMIMEType else {
                throw StickerImportError.unsupportedType
            }
            fileName = values.name ?? url.lastPathComponent
            self.contentType = contentType
            isWebM = extensionIsWebM
        } catch {
            if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
            hasSecurityScope = false
            throw error
        }
    }

    func releaseSecurityScope() {
        guard hasSecurityScope else { return }
        url.stopAccessingSecurityScopedResource()
        hasSecurityScope = false
    }

    deinit { releaseSecurityScope() }
}

private enum StickerImportError: LocalizedError {
    case fileTooLarge
    case unsupportedType

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: "File is too large. Maximum sticker size is 10 MB."
        case .unsupportedType: "Stickers must be an image or a WebM video."
        }
    }
}

private struct StickerUploadSheet: View {
    @ObservedObject var library: StickerLibrary
    let packID: String
    let file: StickerImport

    @Environment(\.dismiss) private var dismiss
    @State private var emoji = ""
    @State private var name = ""
    @State private var isUploading = false
    @State private var uploadError: String?

    private let emojiChoices = ["😀", "😍", "😂", "😮", "😢", "🎉", "🔥", "👍", "❤️", "👀"]

    private var normalizedEmoji: String {
        StickerPreferences.normalizedEmojiSequences(
            emoji, maximum: StickerPreferences.maximumStickerEmojiCount
        ).joined()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Preview") {
                    StickerImportPreview(file: file)
                        .frame(maxWidth: .infinity, minHeight: 180)
                }
                Section("Sticker Details") {
                    TextField("Emoji", text: $emoji, prompt: Text("e.g. 😊"))
                        .onChange(of: emoji) { _, value in
                            let normalized = StickerPreferences.normalizedEmojiSequences(
                                value, maximum: StickerPreferences.maximumStickerEmojiCount
                            ).joined()
                            if emoji != normalized { emoji = normalized }
                        }
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 38), spacing: 8)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(emojiChoices, id: \.self) { candidate in
                            Button(candidate) { appendEmoji(candidate) }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("Choose \(candidate)")
                        }
                    }
                    TextField("Name (optional)", text: $name)
                        .onChange(of: name) { _, value in
                            if value.count > 255 { name = String(value.prefix(255)) }
                        }
                    Text("Choose one to four emoji. The name is optional.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Sticker")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isUploading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isUploading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Add") { addSticker() }
                            .disabled(normalizedEmoji.isEmpty)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isUploading)
        .onDisappear { file.releaseSecurityScope() }
        .alert(
            "Couldn’t add sticker",
            isPresented: Binding(
                get: { uploadError != nil }, set: { if !$0 { uploadError = nil } })
        ) {
            Button("OK") { uploadError = nil }
        } message: {
            Text(uploadError ?? "")
        }
    }

    private func appendEmoji(_ candidate: String) {
        let choices = StickerPreferences.normalizedEmojiSequences(
            emoji + candidate, maximum: StickerPreferences.maximumStickerEmojiCount)
        emoji = choices.joined()
    }

    private func addSticker() {
        let emoji = normalizedEmoji
        guard !emoji.isEmpty, !isUploading else { return }
        isUploading = true
        let upload = StickerUpload(
            fileURL: file.url, fileName: file.fileName, contentType: file.contentType)
        Task {
            defer { isUploading = false }
            guard
                await library.addSticker(toPack: packID, upload: upload, emoji: emoji, name: name)
                    != nil
            else {
                uploadError = library.error ?? "Couldn’t add sticker. Please try again."
                library.error = nil
                return
            }
            dismiss()
        }
    }
}

private struct StickerImportPreview: View {
    let file: StickerImport
    @State private var previewImage: Image?
    @State private var previewLoaded = false

    var body: some View {
        Group {
            if file.isWebM {
                VStack(spacing: 10) {
                    Image(systemName: "film")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(file.fileName).lineLimit(1)
                }
            } else if let previewImage {
                previewImage.resizable().scaledToFit()
            } else if previewLoaded {
                ContentUnavailableView("Preview unavailable", systemImage: "photo")
            } else {
                ProgressView()
            }
        }
        .accessibilityLabel("Sticker preview")
        .task(id: file.id) {
            guard !file.isWebM else { return }
            defer { previewLoaded = true }
            // AsyncImage uses URLSession, which cannot load security-scoped local file URLs.
            #if os(macOS)
                if let image = NSImage(contentsOf: file.url) {
                    previewImage = Image(nsImage: image)
                }
            #else
                if let image = UIImage(contentsOfFile: file.url.path) {
                    previewImage = Image(uiImage: image)
                }
            #endif
        }
    }
}
