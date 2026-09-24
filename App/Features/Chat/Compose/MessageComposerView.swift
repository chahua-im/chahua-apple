import ChahuaAPI
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct MessageComposerView: View {
    @Binding var text: String
    @ObservedObject var attachmentState: ComposerAttachmentState
    let maxHeight: CGFloat
    let isEnabled: Bool
    let canSend: Bool
    let onSubmit: (String) async -> Bool
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
    nonisolated var onSearchMembers: ComposerMemberSearch? = nil
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @StateObject private var input = ComposerInputState()
    @StateObject private var voiceRecorder = ComposerVoiceRecorder()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MessageTextSizePreference.storageKey)
    private var messageTextSize = MessageTextSizePreference.defaultValue
    #if os(iOS)
        @ScaledMetric(relativeTo: .body) private var scaledDefaultMessageTextSize: CGFloat = 17
    #endif
    private var fontSize: CGFloat {
        #if os(iOS)
            scaledDefaultMessageTextSize
                * CGFloat(MessageTextSizePreference.clamped(messageTextSize))
                / CGFloat(MessageTextSizePreference.defaultValue)
        #else
            MessageTextSizePreference.scaledBodySize(messageTextSize)
        #endif
    }
    @FocusState private var isInputFocused: Bool
    @State private var showsAttachmentDialog = false
    @State private var attachmentCaption = ""
    @State private var attachmentSubmitted = false
    @State private var isSubmitting = false
    @State private var showsStickerPicker = false
    @State private var stickerPickerStoleFocus = false

    private var isAcquiring: Bool { attachmentState.isAcquiring }
    private var imageError: String? {
        get { attachmentState.error }
        nonmutating set { attachmentState.error = newValue }
    }

    private var canSubmit: Bool {
        isEnabled && canSend && !isAcquiring && !isSubmitting && !voiceRecorder.isActive
    }
    // The binding intentionally excludes native IME preedit; it still enables
    // explicit Send, which commits the visible marked text before submitting.
    private var hasText: Bool { input.isComposing || !(input.editorText ?? text).isEmpty }
    private var hasContent: Bool { hasText || (editingMessage == nil && !attachments.isEmpty) }
    private var canAcquire: Bool {
        isEnabled && !isAcquiring && !isSubmitting && !voiceRecorder.isActive
            && editingMessage == nil && onImportImages != nil
    }
    private var canPickSticker: Bool {
        canSubmit && editingMessage == nil && stickerLibrary != nil && onSendSticker != nil
    }
    private var showsVoiceButton: Bool { !hasContent && editingMessage == nil }
    private var showsVoiceControl: Bool { showsVoiceButton || voiceRecorder.isActive }
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

    #if os(macOS)
        private var messageEditor: some View {
            ComposerTextInput(
                input: input, draft: $text,
                isEnabled: isEnabled && !isAcquiring && !voiceRecorder.isActive
                    && !showsAttachmentDialog && !showsStickerPicker,
                onCompositionChanged: onCompositionChanged, onSubmit: keyboardSubmit,
                onPasteMedia: canAcquire ? { importProviders($0) } : nil,
                focus: Binding(get: { isInputFocused }, set: { isInputFocused = $0 }),
                fontSize: fontSize, maximumHeight: max(20, maxHeight - 24),
                accessibilityLabel: "Message"
            )
            .overlay(alignment: .topLeading) {
                // Marked IME text is native-only until commit; the hint must still disappear.
                if !hasText {
                    Text("Message")
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
    #else
        private var composerInputBridge: some View {
            let enabled =
                isEnabled && !isAcquiring && !voiceRecorder.isActive && !showsAttachmentDialog
                && !showsStickerPicker
            return ComposerInputBridge(
                input: input, draft: $text, isFocused: isInputFocused, isEnabled: enabled,
                onCompositionChanged: onCompositionChanged, onSubmit: keyboardSubmit,
                onPasteImages: canAcquire ? { importProviders($0) } : nil
            )
            .accessibilityHidden(true)
        }
    #endif

    private var messageTextField: some View {
        #if os(macOS)
            messageEditor
        #else
            TextField("Message", text: editorText, axis: .vertical)
                .background(composerInputBridge)
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            ComposerMentionSuggestions(
                input: input, wireText: text,
                isEnabled: isEnabled && isInputFocused && !isAcquiring && !isSubmitting
                    && !voiceRecorder.isActive && !showsAttachmentDialog && !showsStickerPicker,
                search: onSearchMembers
            )
            HStack(alignment: .bottom, spacing: 8) {
                if voiceRecorder.previewURL != nil {
                    Button {
                        voiceRecorder.discard()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 20))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .accessibilityLabel("Discard voice message")
                    .disabled(voiceRecorder.phase == .sending)
                    .modifier(ChatGlassSurface(cornerRadius: 22))
                    .modifier(ComposerSendFocus())
                } else if !voiceRecorder.isActive {
                    Menu {
                        Button("Photos", systemImage: "photo.on.rectangle") {
                            dismissStickerPicker(restoreFocus: false)
                            input.settleNativeInput()
                            isInputFocused = false
                            showsPhotos = true
                        }
                        Button("Files", systemImage: "folder") {
                            dismissStickerPicker(restoreFocus: false)
                            input.settleNativeInput()
                            isInputFocused = false
                            showsFiles = true
                        }
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 20))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .disabled(!canAcquire)
                    .accessibilityLabel(
                        editingMessage == nil
                            ? "Add media" : "Attachments cannot be changed while editing"
                    )
                    .modifier(ChatGlassSurface(cornerRadius: 22))
                }

                VStack(spacing: 0) {
                    if let editing = editingMessage {
                        editMarker(editing)
                    } else if let reply = replyToMessage {
                        replyMarker(reply)
                    }

                    if voiceRecorder.isActive {
                        ComposerVoicePanel(recorder: voiceRecorder)
                    } else {
                        HStack(alignment: .bottom, spacing: 0) {
                            messageTextField
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
                                    .onSubmit(keyboardSubmit)
                                    .onKeyPress(keys: [.return]) { press in
                                        guard press.modifiers.isEmpty, !input.isComposing,
                                            case .committed = input.nativeInput?.snapshot()
                                        else { return .ignored }
                                        keyboardSubmit()
                                        return .handled
                                    }
                                #endif
                                .onKeyPress(.escape) {
                                    guard !input.isComposing else { return .ignored }
                                    if input.onMentionKey?(.dismiss) == true { return .handled }
                                    if let editing = editingMessage, text == editing.message {
                                        onCancelEdit?()
                                    } else if replyToMessage != nil {
                                        onCancelReply?()
                                    } else {
                                        isInputFocused = false
                                    }
                                    return .handled
                                }
                                .onKeyPress(.upArrow) {
                                    guard !input.isComposing else { return .ignored }
                                    if input.onMentionKey?(.up) == true { return .handled }
                                    guard !hasText, attachments.isEmpty, replyToMessage == nil,
                                        editingMessage == nil,
                                        onRequestEditLastMessage?() == true
                                    else { return .ignored }
                                    return .handled
                                }
                                .onKeyPress(.downArrow) {
                                    guard !input.isComposing else { return .ignored }
                                    return input.onMentionKey?(.down) == true ? .handled : .ignored
                                }
                                .accessibilityLabel("Message")

                            Button(action: toggleStickerPicker) {
                                Image(systemName: showsStickerPicker ? "xmark" : "face.smiling")
                                    .font(.system(size: 20))
                                    .foregroundStyle(
                                        showsStickerPicker ? ChahuaTheme.accent : .secondary
                                    )
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .disabled(!showsStickerPicker && !canPickSticker)
                            .accessibilityLabel(showsStickerPicker ? "Close stickers" : "Stickers")
                            .modifier(ComposerSendFocus())
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .modifier(ChatGlassSurface(cornerRadius: 22))

                ZStack {
                    // The user-requested touch hold/drag interaction and pointer click
                    // interaction need separate platform controls. Keep either control
                    // mounted here so recording state never replaces an active gesture.
                    #if os(iOS)
                        ComposerVoiceControlIOS(
                            recorder: voiceRecorder,
                            isEnabled: isEnabled && canSend && !isSubmitting && onSendVoice != nil,
                            canStart: canStartVoice,
                            onStart: startVoiceRecording,
                            onSendVoice: onSendVoice
                        )
                        .opacity(showsVoiceControl ? 1 : 0)
                        .allowsHitTesting(showsVoiceControl)
                        .accessibilityHidden(!showsVoiceControl)
                    #elseif os(macOS)
                        ComposerVoiceControlMac(
                            recorder: voiceRecorder,
                            isEnabled: isEnabled && canSend && !isSubmitting && onSendVoice != nil,
                            canStart: canStartVoice,
                            onStart: startVoiceRecording,
                            onSendVoice: onSendVoice
                        )
                        .opacity(showsVoiceControl ? 1 : 0)
                        .allowsHitTesting(showsVoiceControl)
                        .accessibilityHidden(!showsVoiceControl)
                    #endif

                    if !showsVoiceControl {
                        Button(action: submit) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(
                                    hasContent && canSubmit ? ChahuaTheme.accent : .secondary
                                )
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .disabled(!hasContent || !canSubmit)
                        .modifier(
                            ChatGlassSurface(
                                cornerRadius: 22, isInteractive: hasContent && canSubmit)
                        )
                        .accessibilityLabel("Send message")
                        .modifier(ComposerSendFocus())
                    }
                }
                .frame(width: 44, height: 44)
                .zIndex(1)
            }
            .buttonStyle(.plain)
            .padding(12)
            if showsStickerPicker, let stickerLibrary {
                StickerPickerView(
                    library: stickerLibrary, isEnabled: canPickSticker, onSelect: sendSticker)
            }
        }
        #if os(iOS)
            .background {
                ComposerOutsideTapObserver(isFocused: isInputFocused || showsStickerPicker) {
                    dismissStickerPicker(restoreFocus: false)
                    isInputFocused = false
                }
            }
        #endif
        .sheet(
            isPresented: $showsAttachmentDialog,
            onDismiss: {
                if !attachmentSubmitted { text = attachmentCaption }
                attachmentCaption = ""
                input.receiveExternalText(text)
                #if os(macOS)
                    if isEnabled { isInputFocused = true }
                #else
                    isInputFocused = false
                #endif
            }
        ) {
            ComposerAttachmentDialog(
                text: $attachmentCaption, attachments: attachments, progress: attachmentProgress,
                compressionEnabled: compressionEnabled, isEnabled: isEnabled,
                canSend: canSend, isAcquiring: isAcquiring, attachmentError: imageError,
                onCompositionChanged: onCompositionChanged,
                onRemove: { id in performImageOperation { try await onRemoveAttachment?(id) } },
                onRetry: { id in performImageOperation { try await onRetryAttachment?(id) } },
                onCompressionChanged: { enabled in
                    performImageOperation { try await onCompressionChanged?(enabled) }
                },
                onReorder: { ids in performImageOperation { try await onReorderAttachments?(ids) }
                },
                onImportProviders: importProviders,
                onSubmit: {
                    let sent = await onSubmit(attachmentCaption)
                    if sent { attachmentSubmitted = true }
                    return sent
                },
                onCancel: {
                    guard let onDiscardAttachments else {
                        if attachments.isEmpty { return }
                        throw APIError.unavailable
                    }
                    attachmentState.isAcquiring = true
                    defer { attachmentState.isAcquiring = false }
                    try await onDiscardAttachments()
                },
                onSearchMembers: onSearchMembers
            )
        }
        .photosPicker(
            isPresented: $showsPhotos, selection: $selectedPhotos,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: selectedPhotos) { _, photos in
            guard !photos.isEmpty else { return }
            performImageOperation(opensDialog: true) {
                var urls: [URL] = []
                defer {
                    ComposerImageAcquisition.removeTemporary(urls)
                    selectedPhotos = []
                }
                for photo in photos {
                    guard
                        let image = try await photo.loadTransferable(
                            type: ComposerImportedImage.self)
                    else {
                        throw ComposerImageAcquisition.AcquisitionError.unavailable
                    }
                    urls.append(image.url)
                }
                try await onImportImages?(urls)
            }
        }
        .fileImporter(
            isPresented: $showsFiles, allowedContentTypes: [.image, .movie],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                performImageOperation(opensDialog: true) { try await onImportImages?(urls) }
            case .failure(let error): imageError = error.localizedDescription
            }
        }
        .onDrop(of: [.image, .movie, .fileURL], isTargeted: nil) { providers in
            guard canAcquire else { return false }
            return attachmentState.acceptDrop(providers)
        }
        .alert(
            "Couldn’t update attachments",
            isPresented: Binding(
                get: { imageError != nil && !showsAttachmentDialog },
                set: { if !$0 { imageError = nil } })
        ) {
            Button("OK") { imageError = nil }
        } message: {
            Text(imageError ?? "")
        }
        .alert(
            "Voice message",
            isPresented: Binding(
                get: { voiceRecorder.error != nil }, set: { if !$0 { voiceRecorder.error = nil } })
        ) {
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
            input.setMentionNames(MessageMentions.names(in: editingMessage?.mentions ?? []))
            input.receiveExternalText(text)
            voiceRecorder.setSceneActive(scenePhase == .active)
        }
        .onChange(of: text) { _, text in
            input.receiveExternalText(text)
            if !text.isEmpty { voiceRecorder.discard() }
        }
        .onChange(of: isInputFocused) { _, focused in
            if focused { dismissStickerPicker(restoreFocus: false) }
        }
        .onChange(of: editingMessage?.id) { _, id in
            input.setMentionNames(MessageMentions.names(in: editingMessage?.mentions ?? []))
            dismissStickerPicker(restoreFocus: false)
            if id != nil { voiceRecorder.discard() }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                dismissStickerPicker(restoreFocus: false)
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

    private func performImageOperation(
        opensDialog: Bool = false, _ operation: @escaping @MainActor () async throws -> Void
    ) {
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
            do { try await operation() } catch { imageError = error.localizedDescription }
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
                Text(messagePreview(message.replyPreview))
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
    private func startVoiceRecording(holding: Bool) -> Bool {
        guard canStartVoice else { return false }
        input.settleNativeInput()
        guard !input.isComposing, !hasText else { return false }
        dismissStickerPicker(restoreFocus: false)
        isInputFocused = false
        voiceRecorder.start(holding: holding)
        return true
    }

    private func toggleStickerPicker() {
        guard showsStickerPicker || canPickSticker else { return }
        input.settleNativeInput()
        guard !input.isComposing else { return }
        if showsStickerPicker {
            dismissStickerPicker(restoreFocus: true)
        } else {
            stickerPickerStoleFocus = isInputFocused
            isInputFocused = false
            showsStickerPicker = true
        }
    }

    private func dismissStickerPicker(restoreFocus: Bool) {
        guard showsStickerPicker else { return }
        let shouldRestore = restoreFocus && stickerPickerStoleFocus && isEnabled
        showsStickerPicker = false
        stickerPickerStoleFocus = false
        if shouldRestore { isInputFocused = true }
    }

    private func sendSticker(_ sticker: MessageStickerResponse) async -> Bool {
        guard canPickSticker, let onSendSticker else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        let sent = await onSendSticker(sticker)
        if sent { dismissStickerPicker(restoreFocus: true) }
        return sent
    }

    private func presentAttachmentDialog() {
        guard !voiceRecorder.isActive, !showsAttachmentDialog else { return }
        input.settleNativeInput()
        guard !input.isComposing else { return }
        // The modal owns its edits until send or dismissal, not the compose bar.
        attachmentCaption = text
        attachmentSubmitted = false
        dismissStickerPicker(restoreFocus: false)
        isInputFocused = false
        showsAttachmentDialog = true
    }

    private func keyboardSubmit() {
        guard !input.isComposing else { return }
        if input.onMentionKey?(.accept) == true { return }
        guard canSubmit,
            input.prepareSubmission(
                allowEmptyUnfocused: editingMessage == nil && !attachments.isEmpty)
        else { return }
        sendCommittedText()
    }

    private func submit() {
        guard canSubmit,
            input.prepareExplicitSubmission(
                allowEmptyUnfocused: editingMessage == nil && !attachments.isEmpty)
        else { return }
        sendCommittedText()
    }

    private func sendCommittedText() {
        _ = input.onMentionKey?(.dismiss)
        if editingMessage == nil, !attachments.isEmpty {
            presentAttachmentDialog()
            return
        }
        isSubmitting = true
        let submittedText = text
        Task {
            _ = await onSubmit(submittedText)
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
                                .onChange(of: geometry.size.height) { _, height in
                                    composerHeight = height
                                }
                        }
                    }
            }
    }
}
