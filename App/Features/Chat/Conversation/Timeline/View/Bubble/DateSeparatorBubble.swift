import SwiftUI

struct DateSeparatorBubble: View {
    let row: TimelineDateSeparatorRow

    var body: some View {
        Text(row.day, format: .dateTime.month(.abbreviated).day().year())
            .font(.caption)
            .foregroundStyle(ChahuaTheme.secondaryText)
            .padding(.horizontal, ChahuaTheme.Spacing.medium)
            .padding(.vertical, ChahuaTheme.Spacing.xSmall)
            .background(ChahuaTheme.secondaryBackground, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, ChahuaTheme.Spacing.medium)
    }
}
