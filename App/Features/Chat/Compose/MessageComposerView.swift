import ChahuaAPI
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    import AVFoundation
#endif

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
    var onOpenReply: ((MessageID) -> Void)? = nil
    var isEditing = false
    var initialEditText = ""
    var hasEditChanges: ((String) -> Bool)? = nil
    var editIdentity: String? = nil
    var editMentionNames: [Int32: String] = [:]
    var allowsEditingMedia = false
    var editExitGuard: FormExitGuard? = nil
    var onCancelEdit: (() -> Void)? = nil
    var onEscapeEdit: ((String) -> Void)? = nil
    var onRequestEditLastMessage: (() -> Bool)? = nil
    var attachments: [ComposerMediaItem] = []
    var attachmentProgress: [String: Double] = [:]
    var compressionEnabled = true
    var onImportImages: (([URL]) async throws -> Void)? = nil
    var onImportFiles: (([URL]) async throws -> Void)? = nil
    var onRemoveAttachment: ((String) async throws -> Void)? = nil
    var onRetryAttachment: ((String) async throws -> Void)? = nil
    var onCompressionChanged: ((Bool) async throws -> Void)? = nil
    var onReorderAttachments: (([String]) async throws -> Void)? = nil
    var onDiscardAttachments: (() async throws -> Void)? = nil
    var stickerLibrary: StickerLibrary? = nil
    var onSendSticker: ((MessageStickerResponse) async -> Bool)? = nil
    var onSendVoice: ((URL) async -> Bool)? = nil
    nonisolated var onSearchMembers: ComposerMemberSearch? = nil
    var linkPreviewScope = ""
    var linkPreviewChoices: Binding<[LinkPreviewInput]> = .constant([])
    var initialLinkPreviews: [MessageLinkPreview] = []
    var onPreviewLinks: (([String]) async throws -> [MessageLinkPreview])? = nil
    var onEditDraftChanged: ((String) -> Void)? = nil
    @StateObject private var linkPreviews = DraftLinkPreviewState()
    @State private var showsLinkManagement = false
    @State private var linkManagementStoleFocus = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showsPhotos = false
    @State private var showsFiles = false
    #if os(iOS)
        @State private var showsCamera = false
        @State private var isRequestingCameraPermission = false
        @State private var presentsCameraAfterAttachmentDialog = false
        @State private var capturedPhotoURL: URL?
    #endif
    @StateObject private var input = ComposerInputState()
    @StateObject private var voiceRecorder = ComposerVoiceRecorder()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isWideChatLayout) private var isWideChatLayout
    @AppStorage(MessageTextSizePreference.storageKey)
    private var messageTextSize = MessageTextSizePreference.defaultValue
    #if os(iOS)
        @ScaledMetric(relativeTo: .body) private var scaledDefaultMessageTextSize: CGFloat = 17
    #endif
    private var fontSize: CGFloat {
        #if os(iOS)
            MessageTextSizePreference.scaledSize(
                messageTextSize, systemSize: scaledDefaultMessageTextSize, defaultSize: 17)
        #else
            MessageTextSizePreference.scaledBodySize(messageTextSize)
        #endif
    }
    @FocusState private var isInputFocused: Bool
    @State private var showsAttachmentDialog = false
    @State private var attachmentCaption = ""
    @State private var attachmentSubmitted = false
    @State private var attachmentDialogEditIdentity: String?
    @State private var isSubmitting = false
    @State private var showsStickerPicker = false
    @State private var stickerPickerStoleFocus = false
    @State private var acquisitionTask: Task<Void, Never>?
    @State private var acquisitionGeneration = UUID()

    private var isAcquiring: Bool {
        #if os(iOS)
            attachmentState.isAcquiring || isRequestingCameraPermission
        #else
            attachmentState.isAcquiring
        #endif
    }
    private var isCameraPresented: Bool {
        #if os(iOS)
            showsCamera
        #else
            false
        #endif
    }
    private var imageError: String? {
        get { attachmentState.error }
        nonmutating set { attachmentState.error = newValue }
    }

    private var canSubmit: Bool {
        isEnabled && canSend && !isAcquiring && !isSubmitting && !voiceRecorder.isActive
            && (!isEditing || input.isComposing || editHasChanges(text))
    }
    // The binding intentionally excludes native IME preedit; it still enables
    // explicit Send, which commits the visible marked text before submitting.
    private var hasText: Bool { input.isComposing || !(input.editorText ?? text).isEmpty }
    private var hasContent: Bool { hasText || !attachments.isEmpty }
    private var canAcquire: Bool {
        isEnabled && !isAcquiring && !isSubmitting && !voiceRecorder.isActive
            && (!isEditing || allowsEditingMedia) && (onImportImages != nil || onImportFiles != nil)
            && !isCameraPresented
    }
    private var canPickSticker: Bool {
        canSubmit && !isEditing && stickerLibrary != nil && onSendSticker != nil
    }
    private var showsVoiceButton: Bool { !hasContent && !isEditing }
    private var showsVoiceControl: Bool { showsVoiceButton || voiceRecorder.isActive }
    private var canStartVoice: Bool {
        isEnabled && canSend && !isAcquiring && !isSubmitting && !voiceRecorder.isActive
            && !hasContent && !isEditing && onSendVoice != nil
            && !showsPhotos && !showsFiles && !showsAttachmentDialog
            && !isCameraPresented
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

    private var controlSpacing: CGFloat {
        #if os(macOS)
            10
        #else
            8
        #endif
    }

    private var horizontalInset: CGFloat {
        #if os(macOS)
            16
        #else
            isWideChatLayout ? 20 : 12
        #endif
    }

    private var editorLeadingInset: CGFloat {
        #if os(macOS)
            16
        #else
            12
        #endif
    }

    private var stickerControlSize: CGFloat {
        #if os(macOS)
            32
        #else
            44
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
            HStack(alignment: .bottom, spacing: controlSpacing) {
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
                        #if os(iOS)
                            Button("Take Photo", systemImage: "camera") {
                                takePhoto()
                            }
                            .disabled(onImportImages == nil)
                        #endif
                        Button("Photos", systemImage: "photo.on.rectangle") {
                            dismissStickerPicker(restoreFocus: false)
                            input.settleNativeInput()
                            isInputFocused = false
                            showsPhotos = true
                        }
                        .disabled(onImportImages == nil)
                        if !attachments.isEmpty {
                            Button("Attachments", systemImage: "photo.on.rectangle") {
                                presentAttachmentDialog()
                            }
                        }
                        if !isEditing {
                            Button("Files", systemImage: "folder") {
                                dismissStickerPicker(restoreFocus: false)
                                input.settleNativeInput()
                                isInputFocused = false
                                showsFiles = true
                            }
                            .disabled(onImportFiles == nil)
                        }
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 20))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    // Preserve Camera → Photos → Files even when the menu opens upward.
                    .menuOrder(.fixed)
                    #if os(macOS)
                        // macOS menus have their own style and indicator defaults;
                        // inherited plain button styling alone does not control them.
                        // Reserve the attachment column with explicit button-menu chrome.
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .frame(width: 44, height: 44)
                    #endif
                    .disabled(!canAcquire)
                    .accessibilityLabel(
                        !isEditing || allowsEditingMedia
                            ? "Add attachments" : "Attachments cannot be changed while editing"
                    )
                    .modifier(ChatGlassSurface(cornerRadius: 22))
                }

                VStack(spacing: 0) {
                    if isEditing {
                        editMarker
                    } else if let reply = replyToMessage {
                        replyMarker(reply)
                    }
                    if !voiceRecorder.isActive {
                        DraftLinkPreviewControls(
                            state: linkPreviews, isEnabled: isEnabled && !isSubmitting,
                            onOpen: openLinkManagement)
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
                                #if os(macOS)
                                    // The native scrolling editor must take only the width
                                    // left after the trailing sticker button is laid out.
                                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                    .padding(.trailing, 4)
                                #endif
                                .padding(.leading, editorLeadingInset)
                                .padding(.vertical, 12)
                                .disabled(!isEnabled || isAcquiring || voiceRecorder.isActive)
                                .modifier(ComposerFormattingShortcuts(input: input))
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
                                    if isEditing {
                                        if let onEscapeEdit {
                                            onEscapeEdit(text)
                                        } else if text == initialEditText {
                                            onCancelEdit?()
                                        }
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
                                        !isEditing,
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
                                    .frame(width: stickerControlSize, height: stickerControlSize)
                                    .contentShape(Rectangle())
                            }
                            #if os(macOS)
                                .padding(.vertical, 6)
                                .padding(.trailing, 6)
                            #endif
                            .disabled(!showsStickerPicker && !canPickSticker)
                            .accessibilityLabel(showsStickerPicker ? "Close stickers" : "Stickers")
                            .modifier(ComposerSendFocus())
                        }
                        #if os(macOS)
                            .frame(minHeight: 44)
                        #endif
                    }
                }
                #if os(macOS)
                    // Only the input column expands; the attachment and voice/send
                    // columns retain their own non-overlapping 44-point hit regions.
                    .frame(minWidth: 0, maxWidth: .infinity)
                #endif
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
            .padding(.horizontal, horizontalInset)
            #if os(macOS)
                .padding(.top, 12)
                .padding(.bottom, 16)
            #else
                .padding(.vertical, 12)
            #endif
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
            isPresented: $showsLinkManagement,
            onDismiss: {
                if linkManagementStoleFocus && isEnabled { isInputFocused = true }
                linkManagementStoleFocus = false
            }
        ) {
            DraftLinkPreviewManagement(state: linkPreviews)
        }
        .sheet(
            isPresented: $showsAttachmentDialog,
            onDismiss: {
                #if os(iOS)
                    let shouldPresentCamera = presentsCameraAfterAttachmentDialog
                    presentsCameraAfterAttachmentDialog = false
                #endif
                if !attachmentSubmitted, attachmentDialogEditIdentity == editIdentity {
                    text = attachmentCaption
                }
                attachmentCaption = ""
                input.receiveExternalText(text)
                #if os(macOS)
                    if isEnabled { isInputFocused = true }
                #else
                    isInputFocused = false
                #endif
                #if os(iOS)
                    if shouldPresentCamera {
                        // The attachment sheet has fully dismissed at this callback; schedule
                        // full-screen camera for the next presentation transaction.
                        DispatchQueue.main.async { showsCamera = true }
                    }
                #endif
            }
        ) {
            ComposerAttachmentDialog(
                text: $attachmentCaption, attachments: attachments, progress: attachmentProgress,
                compressionEnabled: compressionEnabled, isEnabled: isEnabled,
                canSend: canSend && (!isEditing || editHasChanges(attachmentCaption)),
                isAcquiring: isAcquiring, attachmentError: imageError,
                onCompositionChanged: onCompositionChanged,
                onRemove: { id in performImageOperation { try await onRemoveAttachment?(id) } },
                onRetry: { id in performImageOperation { try await onRetryAttachment?(id) } },
                onCompressionChanged: { enabled in
                    performImageOperation { try await onCompressionChanged?(enabled) }
                },
                onReorder: { ids in performImageOperation { try await onReorderAttachments?(ids) }
                },
                onImportProviders: importProviders,
                onTakePhoto: takePhoto,
                onSubmit: {
                    guard attachmentDialogEditIdentity == editIdentity else { return false }
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
                onSearchMembers: onSearchMembers,
                isEditing: isEditing, allowsCompressionChanges: !isEditing,
                onEscapeEdit: { onEscapeEdit?(attachmentCaption) },
                editExitGuard: editExitGuard, linkPreviews: linkPreviews
            )
        }
        #if os(iOS)
            .fullScreenCover(
                isPresented: $showsCamera,
                onDismiss: {
                    guard let capturedPhotoURL else { return }
                    self.capturedPhotoURL = nil
                    importCapturedPhoto(capturedPhotoURL)
                }
            ) {
                ComposerCameraPicker(
                    onCapture: { url in
                        capturedPhotoURL = url
                        showsCamera = false
                    },
                    onCancel: { showsCamera = false },
                    onError: { error in
                        imageError = error.localizedDescription
                        showsCamera = false
                    }
                )
                .ignoresSafeArea()
            }
        #endif
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
            isPresented: $showsFiles, allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                performImageOperation(opensDialog: true) { try await onImportFiles?(urls) }
            case .failure(let error): imageError = error.localizedDescription
            }
        }
        .onDrop(of: [.item, .fileURL], isTargeted: nil) { providers in
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
        .onDisappear {
            linkPreviews.suspend()
            acquisitionTask?.cancel()
            acquisitionGeneration = UUID()
            attachmentState.prepareForEditing = nil
            attachmentState.cancelEditingWork = nil
            voiceRecorder.discard()
            #if os(iOS)
                if let capturedPhotoURL {
                    ComposerImageAcquisition.removeTemporary([capturedPhotoURL])
                    self.capturedPhotoURL = nil
                }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            voiceRecorder.setSceneActive(phase == .active)
            // A permission alert can make the scene inactive; only backgrounding cancels it.
            if phase == .background { voiceRecorder.suspend() }
        }
        .onAppear {
            input.setMentionNames(editMentionNames)
            input.receiveExternalText(text)
            voiceRecorder.setSceneActive(scenePhase == .active)
            attachmentState.prepareForEditing = prepareForEditing
            attachmentState.cancelEditingWork = cancelEditingWork
            refreshLinkPreviews()
        }
        .onChange(of: text) { _, text in
            input.receiveExternalText(text)
            if !text.isEmpty { voiceRecorder.discard() }
            if !showsAttachmentDialog { refreshLinkPreviews() }
        }
        .onChange(of: attachmentCaption) { _, _ in
            if showsAttachmentDialog { refreshLinkPreviews() }
            if showsAttachmentDialog && isEditing && attachmentDialogEditIdentity == editIdentity {
                onEditDraftChanged?(attachmentCaption)
            }
        }
        .onChange(of: showsAttachmentDialog) { _, _ in refreshLinkPreviews() }
        .onChange(of: linkPreviewScope) { _, _ in
            showsLinkManagement = false
            refreshLinkPreviews()
        }
        .onChange(of: linkPreviewChoices.wrappedValue) { _, _ in refreshLinkPreviews() }
        .onChange(of: isInputFocused) { _, focused in
            if focused { dismissStickerPicker(restoreFocus: false) }
        }
        .onChange(of: editIdentity) { _, _ in
            cancelEditingWork()
            if showsAttachmentDialog {
                attachmentSubmitted = true
                showsAttachmentDialog = false
            }
            input.setMentionNames(editMentionNames)
            dismissStickerPicker(restoreFocus: false)
            voiceRecorder.discard()
            input.receiveExternalText(text)
            showsLinkManagement = false
            refreshLinkPreviews()
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                showsLinkManagement = false
                dismissStickerPicker(restoreFocus: false)
                voiceRecorder.suspend()
            }
            refreshLinkPreviews()
        }
        .onChange(of: attachmentState.dropRequest?.id) { _, id in
            guard id != nil, let providers = attachmentState.takeDrop() else { return }
            importProviders(providers)
        }
        .onChange(of: attachments.map(\.id)) { oldIDs, newIDs in
            if !isEditing, newIDs.contains(where: { !oldIDs.contains($0) }) {
                voiceRecorder.discard()
                if !showsAttachmentDialog { presentAttachmentDialog() }
            }
        }
        .onChange(of: replyFocusRequest) { _, _ in
            if isEnabled && !voiceRecorder.isActive { isInputFocused = true }
        }
    }

    private func refreshLinkPreviews() {
        guard isEnabled, let onPreviewLinks else {
            linkPreviews.invalidate()
            return
        }
        linkPreviews.configure(
            scope: linkPreviewScope,
            text: showsAttachmentDialog && attachmentDialogEditIdentity == editIdentity
                ? attachmentCaption : text,
            automatic: !isEditing, choices: linkPreviewChoices.wrappedValue,
            initial: initialLinkPreviews, fetch: onPreviewLinks,
            saveChoices: { linkPreviewChoices.wrappedValue = $0 })
    }

    private func openLinkManagement() {
        input.settleNativeInput()
        guard !input.isComposing else { return }
        dismissStickerPicker(restoreFocus: false)
        linkManagementStoleFocus = isInputFocused
        isInputFocused = false
        refreshLinkPreviews()
        showsLinkManagement = true
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
        let generation = acquisitionGeneration
        acquisitionTask = Task {
            defer {
                if generation == acquisitionGeneration { attachmentState.isAcquiring = false }
                if restoresInputFocus && isEnabled && !showsAttachmentDialog && !opensDialog {
                    isInputFocused = true
                }
            }
            do {
                try await operation()
                if generation == acquisitionGeneration, !Task.isCancelled,
                    opensDialog, !showsAttachmentDialog
                {
                    presentAttachmentDialog()
                }
            } catch {
                if generation == acquisitionGeneration, !Task.isCancelled {
                    imageError = error.localizedDescription
                }
            }
        }
    }

    private func takePhoto() {
        #if os(iOS)
            guard canAcquire else { return }
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                imageError = "This device doesn’t have an available camera."
                return
            }
            if !showsAttachmentDialog {
                input.settleNativeInput()
                guard !input.isComposing else {
                    imageError = "Finish composing your text before adding attachments."
                    return
                }
                dismissStickerPicker(restoreFocus: false)
                isInputFocused = false
            }
            let generation = acquisitionGeneration
            isRequestingCameraPermission = true
            Task {
                let granted = await cameraPermissionGranted()
                guard generation == acquisitionGeneration else { return }
                isRequestingCameraPermission = false
                guard granted else {
                    imageError =
                        "Camera access is disabled. Enable Camera in Settings to take a photo."
                    return
                }
                guard generation == acquisitionGeneration,
                    isEnabled && !isSubmitting && !voiceRecorder.isActive
                else { return }
                if showsAttachmentDialog {
                    presentsCameraAfterAttachmentDialog = true
                    showsAttachmentDialog = false
                } else {
                    showsCamera = true
                }
            }
        #endif
    }

    #if os(iOS)

        private func cameraPermissionGranted() async -> Bool {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                true
            case .notDetermined:
                await AVCaptureDevice.requestAccess(for: .video)
            case .denied, .restricted:
                false
            @unknown default:
                false
            }
        }

        private func importCapturedPhoto(_ url: URL) {
            guard canAcquire else {
                ComposerImageAcquisition.removeTemporary([url])
                return
            }
            performImageOperation(opensDialog: true) {
                defer { ComposerImageAcquisition.removeTemporary([url]) }
                try await onImportImages?([url])
            }
        }
    #endif

    private func importProviders(_ providers: [NSItemProvider]) {
        performImageOperation(opensDialog: true) {
            var urls: [URL] = []
            defer { ComposerImageAcquisition.removeTemporary(urls) }
            for provider in providers where ComposerPastePolicy.supports(provider) {
                let url = try await ComposerImageAcquisition.materialize(provider)
                urls.append(url)
                try Task.checkCancellation()
                if ComposerPastePolicy.isFile(provider, materializedURL: url) {
                    guard let onImportFiles else { throw APIError.unavailable }
                    try await onImportFiles([url])
                } else {
                    guard let onImportImages else { throw APIError.unavailable }
                    try await onImportImages([url])
                }
            }
        }
    }

    private func replyMarker(_ reply: MessagePreview) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                onOpenReply?(reply.id)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "Reply to \(MessageSummaryContent.author(reply))"
                    )
                    .font(.system(size: fontSize * 13 / 15, weight: .semibold))
                    .foregroundStyle(ChahuaTheme.accent)
                    MessageSummaryText(reply, fontSize: fontSize * 12 / 15)
                        // The composer has already resolved system sizing or the explicit override.
                        .dynamicTypeSize(.large)
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
            .disabled(voiceRecorder.isBusy)
            .modifier(ComposerSendFocus())
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private var editMarker: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit message")
                    .font(.system(size: fontSize * 13 / 15, weight: .semibold))
                    .foregroundStyle(ChahuaTheme.accent)
                Text(initialEditText)
                    .font(.system(size: fontSize * 12 / 15))
                    .foregroundStyle(.secondary)
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
                onEscapeEdit?(text)
                isInputFocused = true
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36, alignment: .topTrailing)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Cancel edit")
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
        attachmentDialogEditIdentity = editIdentity
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
                allowEmptyUnfocused: !attachments.isEmpty)
        else { return }
        sendCommittedText()
    }

    private func submit() {
        guard canSubmit,
            input.prepareExplicitSubmission(
                allowEmptyUnfocused: !attachments.isEmpty)
        else { return }
        sendCommittedText()
    }

    private func sendCommittedText() {
        _ = input.onMentionKey?(.dismiss)
        if !isEditing, !attachments.isEmpty {
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

    private func editHasChanges(_ text: String) -> Bool {
        hasEditChanges?(text)
            ?? (text.trimmingCharacters(in: .whitespacesAndNewlines)
                != initialEditText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func prepareForEditing() async throws {
        guard input.prepareForEditing() else { throw APIError.unavailable }
        let task = acquisitionTask
        cancelAcquisition()
        if let task { await task.value }
    }

    private func cancelEditingWork() {
        voiceRecorder.discard()
        cancelAcquisition()
    }

    private func cancelAcquisition() {
        dismissStickerPicker(restoreFocus: false)
        acquisitionGeneration = UUID()
        acquisitionTask?.cancel()
        acquisitionTask = nil
        attachmentState.isAcquiring = false
        _ = attachmentState.takeDrop()
        selectedPhotos = []
        showsPhotos = false
        showsFiles = false
        #if os(iOS)
            showsCamera = false
            isRequestingCameraPermission = false
            presentsCameraAfterAttachmentDialog = false
            if let capturedPhotoURL {
                ComposerImageAcquisition.removeTemporary([capturedPhotoURL])
                self.capturedPhotoURL = nil
            }
        #endif
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
///
/// On iOS the viewport also extends under the home indicator, like Telegram; the inset
/// is the distance from the composer's top to the viewport bottom, so it covers the
/// home-indicator area when the keyboard is hidden and only the composer above it.
struct ChatComposerOverlay<Composer: View>: ViewModifier {
    @ViewBuilder let composer: () -> Composer
    /// Composer top and the viewport bottom, in window coordinates. The viewport
    /// extends under the home indicator on iOS, beyond its own safe-area frame.
    @State private var composerTop: CGFloat = 0
    @State private var viewportBottom: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.chatComposerInset, max(0, viewportBottom - composerTop))
            #if os(iOS)
                .ignoresSafeArea(.container, edges: .bottom)
            #endif
            .background {
                GeometryReader { geometry in
                    let bottom = geometry.frame(in: .global).maxY
                    Color.clear
                        .onAppear { viewportBottom = bottom }
                        .onChange(of: bottom) { _, bottom in viewportBottom = bottom }
                }
                #if os(iOS)
                    .ignoresSafeArea(.container, edges: .bottom)
                #endif
            }
            .overlay(alignment: .bottom) {
                composer()
                    .background {
                        GeometryReader { geometry in
                            let top = geometry.frame(in: .global).minY
                            Color.clear
                                .onAppear { composerTop = top }
                                .onChange(of: top) { _, top in composerTop = top }
                        }
                    }
            }
    }
}
