import ChahuaAPI
import SwiftUI

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
    @StateObject private var input = ComposerInputState()
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 15
    @FocusState private var isInputFocused: Bool
    @State private var restoresFocusAfterSend = false

    private var canSubmit: Bool { isEnabled && canSend && !input.isComposing }
    private var hasText: Bool { !(input.editorText ?? text).isEmpty }

    private var editorText: Binding<String> {
        Binding(
            get: { input.editorText ?? text },
            set: { input.receiveEditorText($0) }
        )
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .disabled(true)
            .accessibilityLabel("Attachments (unavailable)")
            .modifier(ChatGlassSurface(cornerRadius: 22))

            VStack(spacing: 0) {
                if let reply = replyToMessage {
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
                        .disabled(!isEnabled)
                        .focused($isInputFocused)
                        .onSubmit(submit)
                        .onKeyPress(.escape) {
                            guard !input.isComposing else { return .ignored }
                            if replyToMessage != nil {
                                onCancelReply?()
                            } else {
                                isInputFocused = false
                            }
                            return .handled
                        }
                        .background(
                            ComposerInputBridge(
                                input: input, draft: $text, isFocused: isInputFocused,
                                isEnabled: isEnabled, onCompositionChanged: onCompositionChanged
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
                Image(systemName: hasText ? "paperplane.fill" : "mic")
                    .font(.system(size: 20))
                    .foregroundStyle(hasText && canSubmit ? ChahuaTheme.accent : .secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .disabled(!hasText || !canSubmit)
            .modifier(ChatGlassSurface(cornerRadius: 22, isInteractive: hasText && canSubmit))
            .accessibilityLabel(hasText ? Text("Send message") : Text("Voice message (unavailable)"))
            .modifier(ComposerSendFocus())
        }
        .buttonStyle(.plain)
        .padding(12)
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

    private func submit() {
        guard canSubmit, input.prepareSubmission() else { return }
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
