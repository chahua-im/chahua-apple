import SwiftUI

struct MessageComposerView: View {
    @Binding var text: String
    let maxHeight: CGFloat
    let isEnabled: Bool
    let canSend: Bool
    let onSubmit: () -> Void

    private var canSubmit: Bool { isEnabled && canSend }

    var body: some View {
        HStack(alignment: .bottom, spacing: ChahuaTheme.Spacing.xSmall) {
            NativeComposerTextView(
                text: $text,
                maxHeight: maxHeight,
                isEnabled: isEnabled,
                onSubmit: submit
            )
            .background(surface)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(ChahuaTheme.separator, lineWidth: 1)
            }
            .padding(.vertical, 4)

            Button(action: submit) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(ChahuaTheme.accent, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .opacity(canSubmit ? 1 : 0.5)
            .accessibilityLabel("Send message")
            #if os(macOS)
            .focusable(false)
            #endif
            .frame(width: 48)
        }
        .padding(.vertical, ChahuaTheme.Spacing.small)
        .padding(.horizontal, ChahuaTheme.Spacing.medium)
        .background(surface)
    }

    private var surface: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    private func submit() {
        guard canSubmit else { return }
        onSubmit()
    }
}
