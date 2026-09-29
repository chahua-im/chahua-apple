import SwiftUI

/// Shared attachment-caption chrome. Callers retain their editor's native input,
/// mention handling, and focus lifecycle rather than replacing it with a second editor.
struct AttachmentCaptionBar<Editor: View>: View {
    let canSend: Bool
    let onSend: () -> Void
    private let editor: Editor

    init(canSend: Bool, onSend: @escaping () -> Void, @ViewBuilder editor: () -> Editor) {
        self.canSend = canSend
        self.onSend = onSend
        self.editor = editor()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            editor
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 24))
            Button(action: onSend) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: sendSymbolSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: sendButtonSize, height: sendButtonSize)
                    .background(canSend ? Color.accentColor : Color.secondary, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
            .modifier(ComposerSendFocus())
        }
        .padding(12)
        .background(.regularMaterial)
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
}
