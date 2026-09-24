import ChahuaAPI
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    import UIKit
#endif

/// The caller supplies a modal-local caption draft and transfers it on dismissal.
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
    let onCancel: () async throws -> Void
    nonisolated var onSearchMembers: ComposerMemberSearch? = nil

    @Environment(\.dismiss) private var dismiss
    @StateObject private var input = ComposerInputState()
    @FocusState private var isCaptionFocused: Bool
    #if os(macOS)
        @FocusState private var isHeaderFocused: Bool
    #endif
    @State private var isSubmitting = false
    @State private var isCancelling = false
    @State private var cancellationError: String?
    @State private var sendFailed = false
    @State private var isMediaDropTargeted = false
    #if os(iOS)
        @State private var keyboardOverlap: CGFloat = 0
    #endif

    private var canInteract: Bool { isEnabled && !isAcquiring && !isSubmitting && !isCancelling }
    private var canEditCaption: Bool { isEnabled && !isSubmitting && !isCancelling }
    private var canSubmit: Bool { canInteract && canSend && !attachments.isEmpty }
    private var editorText: Binding<String> {
        Binding(get: { input.editorText ?? text }, set: { input.receiveEditorText($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { geometry in
                Group {
                    if attachments.isEmpty {
                        ContentUnavailableView(
                            "No attachments", systemImage: "photo.on.rectangle",
                            description: Text(
                                "Drop media here or close to choose more. Your caption will be kept."
                            ))
                    } else {
                        ComposerMediaGallery(
                            attachments: attachments, progress: progress, isEnabled: canInteract,
                            onRemove: { id in changeAttachments { onRemove(id) } },
                            onRetry: { id in changeAttachments { onRetry(id) } },
                            onReorder: { ids in changeAttachments { onReorder(ids) } }
                        )
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
            .padding(.horizontal, 12)
            // Reserve the caption, suggestions and Send at their ideal height;
            // the media viewport gives up space as the keyboard or IME grows.
            VStack(spacing: 4) {
                if isAcquiring {
                    ProgressView("Updating attachments…").controlSize(.small)
                }
                if sendFailed {
                    Text(
                        "Couldn’t send. Your caption and attachments are still here. Retry when local storage is available."
                    )
                    .font(.callout).foregroundStyle(.red)
                    .lineLimit(2)
                }
                if let attachmentError {
                    Text(attachmentError).font(.callout).foregroundStyle(.red)
                        .lineLimit(2)
                }
                ComposerMentionSuggestions(
                    input: input, wireText: text, isEnabled: canEditCaption,
                    search: onSearchMembers
                )
                captionBar
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            .background(.regularMaterial)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
            .padding(.bottom, keyboardOverlap)
            // Measure outside the padding so reserving overlap cannot move the probe
            // and feed the same keyboard space back into the next layout pass.
            .background {
                ComposerKeyboardAvoidance { keyboardOverlap = $0 }
            }
        #endif
        .buttonStyle(.plain)
        .background(.regularMaterial)
        #if os(macOS)
            .frame(width: 440, height: attachments.count > 1 ? 560 : 540)
            // Give initial keyboard focus to the inert title, not Cancel or the
            // caption; neither an accidental discard nor a visible ring belongs here.
            .defaultFocus($isHeaderFocused, true)
        #endif
        .contentShape(Rectangle())
        .onDrop(
            of: [.image, .movie, .fileURL], isTargeted: $isMediaDropTargeted, perform: importDrop
        )
        #if os(macOS)
            .onPasteCommand(of: [.image, .movie, .fileURL]) { _ = importDrop($0) }
        #endif
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
        .interactiveDismissDisabled()
        .alert(
            "Couldn’t discard attachments",
            isPresented: Binding(
                get: { cancellationError != nil },
                set: { if !$0 { cancellationError = nil } }
            )
        ) {
            Button("OK") { cancellationError = nil }
        } message: {
            Text("Your caption and attachments are still here. \(cancellationError ?? "")")
        }
        .onAppear {
            input.receiveExternalText(text)
        }
        .onChange(of: text) { _, value in input.receiveExternalText(value) }
        .onDisappear { input.settleNativeInput() }
    }

    private var header: some View {
        HStack {
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(headerIconFont)
                    .frame(width: headerButtonSize, height: headerButtonSize)
                    .background(.background.opacity(0.8), in: Circle())
            }
            .accessibilityLabel("Cancel")
            .disabled(isAcquiring || isSubmitting || isCancelling)
            Spacer()
            Text("\(attachments.count) Media")
                .font(.headline)
                .accessibilityLabel("\(attachments.count) attachments")
                #if os(macOS)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($isHeaderFocused)
                #endif
            Spacer()
            #if os(iOS)
                if isCaptionFocused {
                    Button(action: dismissKeyboard) {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .background(.background.opacity(0.8), in: Circle())
                    }
                    .disabled(isSubmitting || isCancelling)
                    .accessibilityLabel("Hide keyboard")
                }
            #endif
            Menu {
                if attachments.contains(where: { $0.mimeType.hasPrefix("image/") }) {
                    Toggle(
                        "Compress images",
                        isOn: Binding(
                            get: { compressionEnabled },
                            set: { enabled in changeAttachments { onCompressionChanged(enabled) } }
                        ))
                }
                if attachments.contains(where: { $0.mimeType.hasPrefix("video/") }) {
                    Text("Videos are sent in original quality.")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(headerIconFont.weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: headerButtonSize, height: headerButtonSize)
            .background(.background.opacity(0.8), in: Circle())
            .disabled(!canInteract || attachments.isEmpty)
            .accessibilityLabel("Media options")
        }
        .padding(12)
    }

    private var headerButtonSize: CGFloat {
        #if os(macOS)
            32
        #else
            44
        #endif
    }

    private var headerIconFont: Font {
        #if os(macOS)
            .system(size: 15)
        #else
            .title3
        #endif
    }

    private var captionBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            captionEditor
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 24))
            Button(action: submit) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: sendSymbolSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: sendButtonSize, height: sendButtonSize)
                    .background(canSubmit ? Color.accentColor : Color.secondary, in: Circle())
            }
            .disabled(!canSubmit)
            .accessibilityLabel("Send")
            .modifier(ComposerSendFocus())
        }
        .padding(12)
    }

    private var sendButtonSize: CGFloat {
        #if os(macOS)
            40
        #else
            48
        #endif
    }

    private var sendSymbolSize: CGFloat {
        #if os(macOS)
            19
        #else
            23
        #endif
    }

    @ViewBuilder
    private var captionEditor: some View {
        #if os(macOS)
            ComposerTextInput(
                input: input, draft: $text, isEnabled: canEditCaption,
                onCompositionChanged: onCompositionChanged, onSubmit: keyboardSubmit,
                onPasteMedia: canInteract ? { _ = importDrop($0) } : nil
            )
            .overlay(alignment: .topLeading) {
                if (input.editorText ?? text).isEmpty {
                    Text("Add a caption…")
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        #else
            TextField("Add a caption…", text: editorText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .disabled(!canEditCaption)
                .focused($isCaptionFocused)
                .onSubmit(keyboardSubmit)
                .onKeyPress(keys: [.return]) { press in
                    guard press.modifiers.isEmpty, !input.isComposing,
                        case .committed = input.nativeInput?.snapshot()
                    else { return .ignored }
                    keyboardSubmit()
                    return .handled
                }
                .onKeyPress(.upArrow) { mentionKey(.up) }
                .onKeyPress(.downArrow) { mentionKey(.down) }
                .onKeyPress(.escape) { mentionKey(.dismiss) }
                .background(
                    ComposerInputBridge(
                        input: input, draft: $text, isFocused: isCaptionFocused,
                        isEnabled: canEditCaption,
                        onCompositionChanged: onCompositionChanged, onSubmit: keyboardSubmit,
                        onPasteImages: canInteract ? { _ = importDrop($0) } : nil
                    )
                    .accessibilityHidden(true)
                )
                .accessibilityLabel("Caption")
        #endif
    }

    private func changeAttachments(_ operation: () -> Void) {
        guard canInteract else { return }
        input.settleNativeInput()
        guard !input.isComposing else { return }
        operation()
    }

    private func importDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canInteract else { return false }
        let mediaProviders = providers.filter { provider in
            !provider.hasItemConformingToTypeIdentifier(
                ComposerMediaGallery.slotDragType.identifier)
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

    #if os(iOS)
        private func dismissKeyboard() {
            input.settleNativeInput()
            // FocusState applies on the next view update. Native resignation is
            // synchronous, so IME commits reach the draft before an awaited abort.
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            isCaptionFocused = false
            input.settleNativeInput()
        }
    #endif

    private func cancel() {
        guard !isAcquiring, !isSubmitting, !isCancelling else { return }
        #if os(iOS)
            dismissKeyboard()
        #else
            input.settleNativeInput()
        #endif
        guard !input.isComposing else { return }
        isCancelling = true
        cancellationError = nil
        Task {
            do {
                try await onCancel()
                dismiss()
            } catch {
                cancellationError = error.localizedDescription
            }
            isCancelling = false
        }
    }

    private func mentionKey(_ key: ComposerMentionKey) -> KeyPress.Result {
        guard !input.isComposing else { return .ignored }
        return input.onMentionKey?(key) == true ? .handled : .ignored
    }

    private func keyboardSubmit() {
        guard !input.isComposing else { return }
        if input.onMentionKey?(.accept) == true { return }
        guard canSubmit, input.prepareSubmission(allowEmptyUnfocused: true) else { return }
        sendCommittedCaption()
    }

    private func submit() {
        guard canSubmit, input.prepareExplicitSubmission(allowEmptyUnfocused: true) else { return }
        sendCommittedCaption()
    }

    private func sendCommittedCaption() {
        _ = input.onMentionKey?(.dismiss)
        isSubmitting = true
        sendFailed = false
        Task {
            let sent = await onSubmit()
            isSubmitting = false
            if sent {
                dismiss()
            } else {
                sendFailed = true
                isCaptionFocused = true
            }
        }
    }
}
