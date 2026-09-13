import SwiftUI

struct DateSeparatorBubble: View {
    let text: String
    let fontSize: CGFloat

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: fontSize))
            .foregroundStyle(ChahuaTheme.secondaryText)
            .padding(.horizontal, ChahuaTheme.Spacing.medium)
            .padding(.vertical, ChahuaTheme.Spacing.xSmall)
            .background(ChahuaTheme.secondaryBackground, in: Capsule())
    }
}
