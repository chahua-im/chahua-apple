#if os(iOS)
import SwiftUI
import UIKit


struct MessageThreadIndicator: View {
    let label: String
    let fontSize: CGFloat
    let symbolSize: CGSize
    let labelGap: CGFloat
    var action: (() -> Void)?

    var body: some View {
        if let action {
            MessageRowActionButton(action: action) { content }
        } else { content }
    }

    private var content: some View {
        HStack(spacing: labelGap) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .resizable().scaledToFit().frame(width: symbolSize.width, height: symbolSize.height)
            Text(verbatim: label).lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: fontSize, weight: .semibold))
        .clipped()
        .opacity(0.8)
    }
}


#endif
