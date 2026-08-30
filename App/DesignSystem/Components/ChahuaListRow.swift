import SwiftUI

struct ChahuaListRow<Leading: View, Content: View, Trailing: View>: View {
    let leading: Leading
    let content: Content
    let trailing: Trailing

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: ChahuaTheme.Spacing.medium) {
            leading
            content.frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
    }
}
