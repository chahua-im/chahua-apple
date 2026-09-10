import SwiftUI

struct MessageComposerView: View {
    @Binding var text: String
    let maxHeight: CGFloat
    let isEnabled: Bool
    let canSend: Bool
    let onSubmit: () -> Void
    var onCompositionChanged: ((Bool) -> Void)? = nil
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
        .onChange(of: isEnabled) { _, enabled in
            guard enabled, restoresFocusAfterSend else { return }
            restoresFocusAfterSend = false
            isInputFocused = true
        }
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
