import SwiftUI

struct SystemMessageBubble: View {
    let row: TimelineMessageRow

    var body: some View {
        Text(row.entry.text ?? "")
            .font(.caption)
            .foregroundStyle(ChahuaTheme.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, ChahuaTheme.Spacing.small)
    }
}
