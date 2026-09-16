import ChahuaAPI
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct MessageComposerView: View {
    @Binding var text: String
    @ObservedObject var attachmentState: ComposerAttachmentState
    let maxHeight: CGFloat
    let isEnabled: Bool
    let canSend: Bool
    let onSubmit: () async -> Bool
    var onCompositionChanged: ((Bool) -> Void)? = nil
    var replyToMessage: MessagePreview? = nil
    var replyFocusRequest = 0
    var onCancelReply: (() -> Void)? = nil
    var onOpenReply: ((String) -> Void)? = nil
    var editingMessage: MessageResponse? = nil
    var onCancelEdit: (() -> Void)? = nil
    var onRequestEditLastMessage: (() -> Bool)? = nil
    var attachments: [LocalOutgoingAttachment] = []
    var attachmentProgress: [String: Double] = [:]
    var compressionEnabled = true
    var onImportImages: (([URL]) async throws -> Void)? = nil
    var onRemoveAttachment: ((String) async throws -> Void)? = nil
    var onRetryAttachment: ((String) async throws -> Void)? = nil
    var onCompressionChanged: ((Bool) async throws -> Void)? = nil
    var onReorderAttachments: (([String]) async throws -> Void)? = nil
    var onDiscardAttachments: (() async throws -> Void)? = nil
    var stickerLibrary: StickerLibrary? = nil
    var onSendSticker: ((MessageStickerResponse) async -> Bool)? = nil
    var onSendVoice: ((URL) async -> Bool)? = nil
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @StateObject private var input = ComposerInputState()
    @StateObject private var voiceRecorder = ComposerVoiceRecorder()
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 15
    @FocusState private var isInputFocused: Bool
    @State private var showsAttachmentDialog = false
    @State private var isSubmitting = false
    @State private var showsStickerPicker = false

    private var isAcquiring: Bool { attachmentState.isAcquiring }
    private var imageError: String? {
        get { attachmentState.error }
        nonmutating set { attachmentState.error = newValue }
    }

    private var canSubmit: Bool { isEnabled && canSend && !isAcquiring && !isSubmitting && !voiceRecorder.isActive }
    private var hasText: Bool { !(input.editorText ?? text).isEmpty }
    private var hasContent: Bool { hasText || (editingMessage == nil && !attachments.isEmpty) }
    private var canAcquire: Bool { isEnabled && !isAcquiring && !isSubmitting && !voiceRecorder.isActive && editingMessage == nil && onImportImages != nil }
    private var canPickSticker: Bool { canSubmit && editingMessage == nil && stickerLibrary != nil && onSendSticker != nil }
    private var showsVoiceButton: Bool { !hasContent && editingMessage == nil }
    private var canStartVoice: Bool {
        isEnabled && canSend && !isAcquiring && !isSubmitting && !voiceRecorder.isActive
            && !hasContent && editingMessage == nil && onSendVoice != nil
            && !showsPhotos && !showsFiles && !showsAttachmentDialog
    }

    private var editorText: Binding<String> {
        Binding(
            get: { input.editorText ?? text },
            set: { input.receiveEditorText($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if editingMessage == nil, !attachments.isEmpty {
                Button(action: presentAttachmentDialog) {
                    Label("Review \(attachments.count) attachments", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .disabled(!isEnabled || isAcquiring || voiceRecorder.isActive)
            }
            if isAcquiring {
                ProgressView("Preparing attachments…")
                    .font(.caption).controlSize(.small).padding(8)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if !voiceRecorder.isActive {
                Menu {
                    Button("Photos", systemImage: "photo.on.rectangle") {
                        showsStickerPicker = false
                        input.settleNativeInput()
                        isInputFocused = false
                        showsPhotos = true
                    }
                    Button("Files", systemImage: "folder") {
                        showsStickerPicker = false
                        input.settleNativeInput()
                        isInputFocused = false
                        showsFiles = true
                    }
                    PasteButton(supportedContentTypes: [.image, .movie, .fileURL]) { importProviders($0) }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 20))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .disabled(!canAcquire)
                .accessibilityLabel(editingMessage == nil ? "Add media" : "Attachments cannot be changed while editing")
                .modifier(ChatGlassSurface(cornerRadius: 22))
                }

            VStack(spacing: 0) {
                if let editing = editingMessage {
                    editMarker(editing)
                } else if let reply = replyToMessage {
                    replyMarker(reply)
                }

                if voiceRecorder.isActive, let onSendVoice {
                    ComposerVoicePanel(
                        recorder: voiceRecorder,
                        isEnabled: isEnabled && canSend && !isSubmitting,
                        onSendVoice: onSendVoice
                    )
                } else {
                HStack(alignment: .bottom, spacing: 0) {
                    TextField("Message", text: editorText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: fontSize))
                        .lineLimit(1...6)
                        .frame(maxHeight: max(20, maxHeight - 24))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 12)
                        .padding(.vertical, 12)
                        .disabled(!isEnabled || isAcquiring || voiceRecorder.isActive)
                        .focused($isInputFocused)
                        #if !os(macOS)
                        .onSubmit(submit)
                        #endif
                        .onKeyPress(.escape) {
                            guard !input.isComposing else { return .ignored }
                            if let editing = editingMessage, (input.editorText ?? text) == editing.message {
                                onCancelEdit?()
                            } else if replyToMessage != nil {
                                onCancelReply?()
                            } else {
                                isInputFocused = false
                            }
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            guard !input.isComposing, !hasText, attachments.isEmpty, replyToMessage == nil, editingMessage == nil,
                                onRequestEditLastMessage?() == true
                            else { return .ignored }
                            return .handled
                        }
                        .background(
                            ComposerInputBridge(
                                input: input, draft: $text, isFocused: isInputFocused,
                                isEnabled: isEnabled && !isAcquiring && !voiceRecorder.isActive && !showsAttachmentDialog && !showsStickerPicker,
                                onCompositionChanged: onCompositionChanged, onSubmit: submit,
                                focusOnEntry: true
                            )
                            .accessibilityHidden(true)
                        )
                        .accessibilityLabel("Message")

                    Button(action: toggleStickerPicker) {
                        Image(systemName: showsStickerPicker ? "xmark" : "face.smiling")
                            .font(.system(size: 20))
                            .foregroundStyle(showsStickerPicker ? ChahuaTheme.accent : .secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(!showsStickerPicker && !canPickSticker)
                    .accessibilityLabel(showsStickerPicker ? "Close stickers" : "Stickers")
                }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .modifier(ChatGlassSurface(cornerRadius: 22))

            if !voiceRecorder.isActive {
                Button {
                    if showsVoiceButton { startVoiceRecording() }
                    else { submit() }
                } label: {
                    Image(systemName: showsVoiceButton ? "mic" : "paperplane.fill")
                        .font(.system(size: 20))
                        .foregroundStyle((showsVoiceButton ? canStartVoice : hasContent && canSubmit) ? ChahuaTheme.accent : .secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .disabled(showsVoiceButton ? !canStartVoice : !hasContent || !canSubmit)
                .modifier(ChatGlassSurface(cornerRadius: 22, isInteractive: showsVoiceButton ? canStartVoice : hasContent && canSubmit))
                .accessibilityLabel(showsVoiceButton ? Text("Record voice message") : Text("Send message"))
                .modifier(ComposerSendFocus())
            }
        }
        .buttonStyle(.plain)
        .padding(12)
            if showsStickerPicker, let stickerLibrary {
                StickerPickerView(library: stickerLibrary, isEnabled: canPickSticker, onSelect: sendSticker)
            }
        }
        #if os(iOS)
        .background {
            ComposerOutsideTapObserver(isFocused: isInputFocused || showsStickerPicker) {
                showsStickerPicker = false
                isInputFocused = false
            }
        }
        #endif
        .sheet(isPresented: $showsAttachmentDialog, onDismiss: {
            input.receiveExternalText(text)
            #if os(macOS)
            if isEnabled { isInputFocused = true }
            #else
            isInputFocused = false
            #endif
        }) {
            ComposerAttachmentDialog(
                text: $text, attachments: attachments, progress: attachmentProgress,
                compressionEnabled: compressionEnabled, isEnabled: isEnabled,
                canSend: canSend, isAcquiring: isAcquiring, attachmentError: imageError,
                onCompositionChanged: onCompositionChanged,
                onRemove: { id in performImageOperation { try await onRemoveAttachment?(id) } },
                onRetry: { id in performImageOperation { try await onRetryAttachment?(id) } },
                onCompressionChanged: { enabled in performImageOperation { try await onCompressionChanged?(enabled) } },
                onReorder: { ids in performImageOperation { try await onReorderAttachments?(ids) } },
                onImportProviders: importProviders,
                onSubmit: onSubmit,
                onCancel: {
                    guard let onDiscardAttachments else {
                        if attachments.isEmpty { return }
                        throw APIError.unavailable
                    }
                    attachmentState.isAcquiring = true
                    defer { attachmentState.isAcquiring = false }
                    try await onDiscardAttachments()
                }
            )
        }
        .photosPicker(isPresented: $showsPhotos, selection: $selectedPhotos, matching: .any(of: [.images, .videos]))
        .onChange(of: selectedPhotos) { _, photos in
            guard !photos.isEmpty else { return }
            performImageOperation(opensDialog: true) {
                var urls: [URL] = []
                defer {
                    ComposerImageAcquisition.removeTemporary(urls)
                    selectedPhotos = []
                }
                for photo in photos {
                    guard let image = try await photo.loadTransferable(type: ComposerImportedImage.self) else {
                        throw ComposerImageAcquisition.AcquisitionError.unavailable
                    }
                    urls.append(image.url)
                }
                try await onImportImages?(urls)
            }
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.image, .movie], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): performImageOperation(opensDialog: true) { try await onImportImages?(urls) }
            case .failure(let error): imageError = error.localizedDescription
            }
        }
        #if os(macOS)
        .onPasteCommand(of: [.image, .movie, .fileURL]) { importProviders($0) }
        #endif
        .onDrop(of: [.image, .movie, .fileURL], isTargeted: nil) { providers in
            guard canAcquire else { return false }
            return attachmentState.acceptDrop(providers)
        }
        .alert("Couldn’t update attachments", isPresented: Binding(get: { imageError != nil && !showsAttachmentDialog }, set: { if !$0 { imageError = nil } })) {
            Button("OK") { imageError = nil }
        } message: {
            Text(imageError ?? "")
        }
        .alert("Voice message", isPresented: Binding(get: { voiceRecorder.error != nil }, set: { if !$0 { voiceRecorder.error = nil } })) {
            Button("OK") { voiceRecorder.error = nil }
        } message: {
            Text(voiceRecorder.error ?? "")
        }
        .onDisappear { voiceRecorder.discard() }
        .onChange(of: scenePhase) { _, phase in
            voiceRecorder.setSceneActive(phase == .active)
            // A permission alert can make the scene inactive; only backgrounding cancels it.
            if phase == .background { voiceRecorder.suspend() }
        }
        .onAppear {
            input.receiveExternalText(text)
            voiceRecorder.setSceneActive(scenePhase == .active)
        }
        .onChange(of: text) { _, text in
            input.receiveExternalText(text)
            if !text.isEmpty { voiceRecorder.discard() }
        }
        .onChange(of: isInputFocused) { _, focused in
            if focused { showsStickerPicker = false }
        }
        .onChange(of: editingMessage?.id) { _, id in
            showsStickerPicker = false
            if id != nil { voiceRecorder.discard() }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                showsStickerPicker = false
                voiceRecorder.suspend()
            }
        }
        .onChange(of: attachmentState.dropRequest?.id) { _, id in
            guard id != nil, let providers = attachmentState.takeDrop() else { return }
            importProviders(providers)
        }
        .onChange(of: attachments.map(\.id)) { oldIDs, newIDs in
            if newIDs.contains(where: { !oldIDs.contains($0) }) {
                voiceRecorder.discard()
                if !showsAttachmentDialog { presentAttachmentDialog() }
            }
        }
        .onChange(of: replyFocusRequest) { _, _ in
            if isEnabled && !voiceRecorder.isActive { isInputFocused = true }
        }
    }

    private func performImageOperation(opensDialog: Bool = false, _ operation: @escaping @MainActor () async throws -> Void) {
        guard canAcquire else { return }
        if !showsAttachmentDialog {
            input.settleNativeInput()
            guard !input.isComposing else {
                imageError = "Finish composing your text before adding attachments."
                return
            }
        }
        let restoresInputFocus = isInputFocused
        attachmentState.isAcquiring = true
        imageError = nil
        Task {
            defer {
                attachmentState.isAcquiring = false
                if restoresInputFocus && isEnabled && !showsAttachmentDialog && !opensDialog {
                    isInputFocused = true
                }
            }
            do { try await operation() }
            catch { imageError = error.localizedDescription }
        }
    }

    private func importProviders(_ providers: [NSItemProvider]) {
        performImageOperation(opensDialog: true) {
            var urls: [URL] = []
            defer { ComposerImageAcquisition.removeTemporary(urls) }
            for provider in providers {
                urls.append(try await ComposerImageAcquisition.materialize(provider))
            }
            try await onImportImages?(urls)
        }
    }

    private func replyMarker(_ reply: MessagePreview) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                onOpenReply?(reply.id)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "Reply to \(reply.sender.name.flatMap { $0.isEmpty ? nil : $0 } ?? "User \(reply.sender.uid)")"
                    )
                    .font(.system(size: fontSize * 13 / 15, weight: .semibold))
                    .foregroundStyle(ChahuaTheme.accent)
                    Text(messagePreview(reply))
                        .font(.system(size: fontSize * 12 / 15))
                        .foregroundStyle(.primary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(ChahuaTheme.accent)
                        .frame(width: 3)
                }
                .contentShape(Rectangle())
            }
            .disabled(reply.isDeleted || voiceRecorder.isBusy)
            Button {
                onCancelReply?()
                if !voiceRecorder.isActive { isInputFocused = true }
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36, alignment: .topTrailing)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Cancel reply")
            .disabled(!isEnabled || voiceRecorder.isBusy)
            .modifier(ComposerSendFocus())
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private func editMarker(_ message: MessageResponse) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit message")
                    .font(.system(size: fontSize * 13 / 15, weight: .semibold))
                    .foregroundStyle(ChahuaTheme.accent)
                Text(message.message ?? "")
                    .font(.system(size: fontSize * 12 / 15))
                    .foregroundStyle(.primary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(ChahuaTheme.accent)
                    .frame(width: 3)
            }
            Button {
                onCancelEdit?()
                isInputFocused = true
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36, alignment: .topTrailing)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Cancel edit")
            .disabled(!isEnabled)
            .modifier(ComposerSendFocus())
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }
    private func startVoiceRecording() {
        guard canStartVoice else { return }
        input.settleNativeInput()
        guard !input.isComposing, !hasText else { return }
        showsStickerPicker = false
        isInputFocused = false
        voiceRecorder.start()
    }


    private func toggleStickerPicker() {
        guard showsStickerPicker || canPickSticker else { return }
        input.settleNativeInput()
        guard !input.isComposing else { return }
        if showsStickerPicker {
            showsStickerPicker = false
            isInputFocused = true
        } else {
            isInputFocused = false
            showsStickerPicker = true
        }
    }

    private func sendSticker(_ sticker: MessageStickerResponse) async -> Bool {
        guard canPickSticker, let onSendSticker else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        let sent = await onSendSticker(sticker)
        if sent { showsStickerPicker = false }
        return sent
    }

    private func presentAttachmentDialog() {
        guard !voiceRecorder.isActive else { return }
        input.settleNativeInput()
        guard !input.isComposing else { return }
        showsStickerPicker = false
        isInputFocused = false
        showsAttachmentDialog = true
    }

    private func submit() {
        guard canSubmit, input.prepareSubmission(allowEmptyUnfocused: editingMessage == nil && !attachments.isEmpty) else { return }
        if editingMessage == nil, !attachments.isEmpty {
            presentAttachmentDialog()
            return
        }
        isSubmitting = true
        Task {
            _ = await onSubmit()
            isSubmitting = false
        }
    }
}

private struct ChatComposerInsetKey: EnvironmentKey {
    nonisolated static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var chatComposerInset: CGFloat {
        get { self[ChatComposerInsetKey.self] }
        set { self[ChatComposerInsetKey.self] = newValue }
    }
}

/// Keep the scroll viewport behind the composer, with clearance for its current height.
struct ChatComposerOverlay<Composer: View>: ViewModifier {
    @ViewBuilder let composer: () -> Composer
    @State private var composerHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.chatComposerInset, composerHeight)
            .overlay(alignment: .bottom) {
                composer()
                    .background {
                        GeometryReader { geometry in
                            Color.clear
                                .onAppear { composerHeight = geometry.size.height }
                                .onChange(of: geometry.size.height) { _, height in composerHeight = height }
                        }
                    }
            }
    }
}
