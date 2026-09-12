import ChahuaAPI
import SwiftUI
import UniformTypeIdentifiers

/// Caption edits use the conversation draft directly: cancellation never discards text.
struct ComposerAttachmentDialog: View {
    @Binding var text: String
    let attachments: [LocalOutgoingAttachment]
    let progress: [String: Double]
    let compressionEnabled: Bool
    let isEnabled: Bool
    let canSend: Bool
    let isAcquiring: Bool
    let attachmentError: String?
    let onCompositionChanged: ((Bool) -> Void)?
    let onRemove: (String) -> Void
    let onRetry: (String) -> Void
    let onCompressionChanged: (Bool) -> Void
    let onReorder: ([String]) -> Void
    let onImportProviders: ([NSItemProvider]) -> Void
    let onSubmit: () async -> Bool
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var input = ComposerInputState()
    @FocusState private var isCaptionFocused: Bool
    @State private var isSubmitting = false
    @State private var sendFailed = false
    @State private var isMediaDropTargeted = false

    private var canInteract: Bool { isEnabled && !isAcquiring && !isSubmitting }
    private var canSubmit: Bool { canInteract && canSend && !attachments.isEmpty }
    private var editorText: Binding<String> {
        Binding(get: { input.editorText ?? text }, set: { input.receiveEditorText($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if attachments.isEmpty {
                ContentUnavailableView("No attachments", systemImage: "photo.on.rectangle", description: Text("Drop media here or close to choose more. Your caption will be kept."))
            } else {
                ComposerMediaGallery(
                    attachments: attachments, progress: progress, isEnabled: canInteract,
                    onRemove: { id in changeAttachments { onRemove(id) } },
                    onRetry: { id in changeAttachments { onRetry(id) } },
                    onReorder: { ids in changeAttachments { onReorder(ids) } }
                )
                .frame(minHeight: 120, maxHeight: .infinity)
            }
            if isAcquiring {
                ProgressView("Updating attachments…").controlSize(.small)
            }
            if sendFailed {
                Text("Couldn’t send. Your caption and attachments are still here. Retry when local storage is available.")
                    .font(.callout).foregroundStyle(.red)
            }
            if let attachmentError {
                Text(attachmentError).font(.callout).foregroundStyle(.red)
            }
            captionBar
        }
        .buttonStyle(.plain)
        .background(.regularMaterial)
        #if os(macOS)
        .frame(width: 520, height: attachments.count > 1 ? 620 : 520)
        #endif
        .contentShape(Rectangle())
        .onDrop(of: [.image, .movie, .fileURL], isTargeted: $isMediaDropTargeted, perform: importDrop)
        .overlay {
            if isMediaDropTargeted && canInteract {
                RoundedRectangle(cornerRadius: 28)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
        .presentationDetents([.large])
        .presentationCornerRadius(28)
        .interactiveDismissDisabled(isSubmitting)
        .onAppear {
            input.receiveExternalText(text)
            isCaptionFocused = true
        }
        .onChange(of: text) { _, value in input.receiveExternalText(value) }
        .onDisappear { input.settleNativeInput() }
    }

    private var header: some View {
        HStack {
            Button {
                input.settleNativeInput()
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(.background.opacity(0.8), in: Circle())
            }
            .accessibilityLabel("Cancel")
            .disabled(isSubmitting)
            .modifier(ComposerSendFocus())
            Spacer()
            Text("\(attachments.count) Media")
                .font(.headline)
                .accessibilityLabel("\(attachments.count) attachments")
            Spacer()
            Menu {
                if attachments.contains(where: { $0.mimeType.hasPrefix("image/") }) {
                    Toggle("Compress images", isOn: Binding(
                        get: { compressionEnabled },
                        set: { enabled in changeAttachments { onCompressionChanged(enabled) } }
                    ))
                }
                if attachments.contains(where: { $0.mimeType.hasPrefix("video/") }) {
                    Text("Videos are sent in original quality.")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3.weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 44, height: 44)
            .background(.background.opacity(0.8), in: Circle())
            .disabled(!canInteract || attachments.isEmpty)
            .accessibilityLabel("Media options")
        }
        .padding(12)
    }

    private var captionBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Add a caption…", text: editorText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 24))
                .disabled(!isEnabled || isSubmitting)
                .focused($isCaptionFocused)
                #if !os(macOS)
                .onSubmit(submit)
                #endif
                .background(
                    ComposerInputBridge(
                        input: input, draft: $text, isFocused: isCaptionFocused,
                        isEnabled: isEnabled && !isSubmitting,
                        onCompositionChanged: onCompositionChanged, onSubmit: submit
                    )
                    .accessibilityHidden(true)
                )
                .accessibilityLabel("Caption")
            Button(action: submit) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(canSubmit ? Color.accentColor : Color.secondary, in: Circle())
            }
            .disabled(!canSubmit)
            .accessibilityLabel("Send")
            .modifier(ComposerSendFocus())
        }
        .padding(12)
    }

    private func changeAttachments(_ operation: () -> Void) {
        input.settleNativeInput()
        guard !input.isComposing else { return }
        operation()
    }

    private func importDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canInteract else { return false }
        let mediaProviders = providers.filter { provider in
            !provider.hasItemConformingToTypeIdentifier(ComposerMediaGallery.slotDragType.identifier)
                && [UTType.image, .movie, .fileURL].contains {
                    provider.hasItemConformingToTypeIdentifier($0.identifier)
                }
        }
        guard !mediaProviders.isEmpty else { return false }
        input.settleNativeInput()
        // A drop must not detach or replace the editor while it owns marked text.
        guard !input.isComposing else { return false }
        onImportProviders(mediaProviders)
        return true
    }

    private func submit() {
        guard canSubmit, input.prepareSubmission(allowEmptyUnfocused: true) else { return }
        isSubmitting = true
        sendFailed = false
        Task {
            let sent = await onSubmit()
            isSubmitting = false
            if sent { dismiss() }
            else { sendFailed = true; isCaptionFocused = true }
        }
    }
}
