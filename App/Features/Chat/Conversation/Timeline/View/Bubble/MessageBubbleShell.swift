import SwiftUI

struct MessageBubbleShell<Content: View>: View {
    let row: TimelineMessageRow
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            if row.isOutgoing { Spacer(minLength: 48) }
            content()
                .padding(.horizontal, ChahuaTheme.Spacing.medium)
                .padding(.vertical, ChahuaTheme.Spacing.small)
                .foregroundStyle(row.isOutgoing ? .white : ChahuaTheme.primaryText)
                .background(row.isOutgoing ? ChahuaTheme.accent : ChahuaTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: ChahuaTheme.Radius.large, style: .continuous))
            if !row.isOutgoing { Spacer(minLength: 48) }
        }
        .padding(.horizontal, ChahuaTheme.Spacing.large)
        .padding(.top, row.groupPosition == .first || row.groupPosition == .single ? ChahuaTheme.Spacing.small : 2)
    }
}
