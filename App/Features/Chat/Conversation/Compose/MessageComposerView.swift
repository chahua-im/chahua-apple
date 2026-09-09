import SwiftUI

struct MessageComposerView: View {
    @Binding var text: String
    let maxHeight: CGFloat
    let isEnabled: Bool
    let canSend: Bool
    let onSubmit: () -> Void

    private var canSubmit: Bool { isEnabled && canSend }
    private var hasText: Bool { !text.isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {} label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .disabled(true)
            .accessibilityLabel("Attachments (unavailable)")
            .modifier(ChatGlassSurface(cornerRadius: 22))

            HStack(alignment: .bottom, spacing: 0) {
                NativeComposerTextView(
                    text: $text,
                    maxHeight: max(36, maxHeight - 8),
                    isEnabled: isEnabled,
                    onSubmit: submit
                )
                .padding(.vertical, 4)

                Button {} label: {
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
            #if os(macOS)
            .focusable(false)
            #endif
        }
        .buttonStyle(.plain)
        .padding(12)
    }

    private func submit() {
        guard canSubmit else { return }
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
                                .onChange(of: geometry.size.height) { composerHeight = $0 }
                        }
                    }
            }
    }
}
