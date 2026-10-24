import SwiftUI

/// Replaces the quick reactions/actions while the Unicode keyboard is open.
struct ReactionPickerPlaceholder: View {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(systemName: "face.smiling")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
                .background(.regularMaterial, in: Circle())
            Circle().fill(.regularMaterial)
                .frame(width: 14, height: 14)
                .offset(x: 49, y: 56)
            Circle().fill(.regularMaterial)
                .frame(width: 6, height: 6)
                .offset(x: 64, y: 70)
        }
        .frame(width: 76, height: 76)
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 28, height: 28)
                    .background(.regularMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close emoji picker"))
            .accessibilityIdentifier("reaction-emoji-close")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Choose a reaction"))
        .accessibilityIdentifier("reaction-emoji-placeholder")
    }
}
