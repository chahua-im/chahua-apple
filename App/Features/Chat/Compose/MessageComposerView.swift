import ChahuaAPI
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct MessageComposerView: View {
    @Binding var text: String
    let maxHeight: CGFloat
    let isEnabled: Bool
    let canSend: Bool
    let onSubmit: () -> Void
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
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var isAcquiring = false
    @State private var imageError: String?
    @StateObject private var input = ComposerInputState()
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 15
    @FocusState private var isInputFocused: Bool
    @State private var restoresFocusAfterSend = false

    private var canSubmit: Bool { isEnabled && canSend && !input.isComposing && !isAcquiring }
    private var hasText: Bool { !(input.editorText ?? text).isEmpty }
    private var hasContent: Bool { hasText || (editingMessage == nil && !attachments.isEmpty) }
    private var canAcquire: Bool { isEnabled && !input.isComposing && !isAcquiring && editingMessage == nil && onImportImages != nil }

    private var editorText: Binding<String> {
        Binding(
            get: { input.editorText ?? text },
            set: { input.receiveEditorText($0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if editingMessage == nil, !attachments.isEmpty {
                ComposerImageTray(
                    attachments: attachments, progress: attachmentProgress,
                    isEnabled: canAcquire, compressionEnabled: compressionEnabled,
                    onRemove: { id in performImageOperation { try await onRemoveAttachment?(id) } },
                    onRetry: { id in performImageOperation { try await onRetryAttachment?(id) } },
                    onCompressionChanged: { enabled in performImageOperation { try await onCompressionChanged?(enabled) } },
                    onReorder: { ids in performImageOperation { try await onReorderAttachments?(ids) } }
                )
            }
            if isAcquiring {
                ProgressView("Saving images on this device…")
                    .font(.caption).controlSize(.small).padding(8)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button("Photos", systemImage: "photo.on.rectangle") { showsPhotos = true }
                    Button("Files", systemImage: "folder") { showsFiles = true }
                    PasteButton(supportedContentTypes: [.image, .fileURL]) { importProviders($0) }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 20))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .disabled(!canAcquire)
                .accessibilityLabel(editingMessage == nil ? "Add images" : "Images cannot be changed while editing")
                .modifier(ChatGlassSurface(cornerRadius: 22))

            VStack(spacing: 0) {
                if let editing = editingMessage {
                    editMarker(editing)
                } else if let reply = replyToMessage {
                    replyMarker(reply)
                }

                HStack(alignment: .bottom, spacing: 0) {
                    TextField("Message", text: editorText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: fontSize))
                        .lineLimit(1...6)
                        .frame(maxHeight: max(20, maxHeight - 24))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 12)
                        .padding(.vertical, 12)
                        .disabled(!isEnabled || isAcquiring)
                        .focused($isInputFocused)
                        .onSubmit(submit)
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
                                isEnabled: isEnabled && !isAcquiring, onCompositionChanged: onCompositionChanged
                            )
                            .accessibilityHidden(true)
                        )
                        .accessibilityLabel("Message")

                    Button {
                    } label: {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .disabled(true)
                    .accessibilityLabel("Emoji (unavailable)")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .modifier(ChatGlassSurface(cornerRadius: 22))

            Button(action: submit) {
                Image(systemName: hasContent ? "paperplane.fill" : "mic")
                    .font(.system(size: 20))
                    .foregroundStyle(hasContent && canSubmit ? ChahuaTheme.accent : .secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .disabled(!hasContent || !canSubmit)
            .modifier(ChatGlassSurface(cornerRadius: 22, isInteractive: hasContent && canSubmit))
            .accessibilityLabel(hasContent ? Text("Send message") : Text("Voice message (unavailable)"))
            .modifier(ComposerSendFocus())
        }
        .buttonStyle(.plain)
        .padding(12)
        }
        .photosPicker(isPresented: $showsPhotos, selection: $selectedPhotos, matching: .images)
        .onChange(of: selectedPhotos) { _, photos in
            guard !photos.isEmpty else { return }
            performImageOperation {
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
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): performImageOperation { try await onImportImages?(urls) }
            case .failure(let error): imageError = error.localizedDescription
            }
        }
        #if os(macOS)
        .onPasteCommand(of: [.image, .fileURL]) { importProviders($0) }
        #endif
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            guard canAcquire else { return false }
            importProviders(providers)
            return true
        }
        .alert("Couldn’t update images", isPresented: Binding(get: { imageError != nil }, set: { if !$0 { imageError = nil } })) {
            Button("OK") { imageError = nil }
        } message: {
            Text(imageError ?? "")
        }
        .onAppear { input.receiveExternalText(text) }
        .onChange(of: text) { _, text in input.receiveExternalText(text) }
        .onChange(of: replyFocusRequest) { _, _ in
            if isEnabled { isInputFocused = true }
        }
        .onChange(of: isEnabled) { _, enabled in
            guard enabled, restoresFocusAfterSend else { return }
            restoresFocusAfterSend = false
            isInputFocused = true
        }
    }

    private func performImageOperation(_ operation: @escaping @MainActor () async throws -> Void) {
        guard canAcquire else { return }
        input.settleNativeInput()
        guard !input.isComposing else { return }
        let restoresInputFocus = isInputFocused
        isAcquiring = true
        Task {
            defer {
                isAcquiring = false
                if restoresInputFocus && isEnabled { isInputFocused = true }
            }
            do { try await operation() }
            catch { imageError = error.localizedDescription }
        }
    }

    private func importProviders(_ providers: [NSItemProvider]) {
        performImageOperation {
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
                    Text(reply.isDeleted ? String(localized: "Message deleted") : messagePreview(reply))
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
            .disabled(reply.isDeleted)
            Button {
                onCancelReply?()
                isInputFocused = true
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36, alignment: .topTrailing)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Cancel reply")
            .disabled(!isEnabled)
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

    private func submit() {
        guard canSubmit, input.prepareSubmission(allowEmptyUnfocused: editingMessage == nil && !attachments.isEmpty) else { return }
        restoresFocusAfterSend = true
        isInputFocused = true
        onSubmit()
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
