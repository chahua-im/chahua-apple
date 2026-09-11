import SwiftUI

struct MessageThreadIndicator: View {
    let count: Int64
    let isOutgoing: Bool
    let showsSeparator: Bool
    var action: (() -> Void)?
    @ScaledMetric(relativeTo: .caption) private var fontSize: CGFloat = 12

    var body: some View {
        if let action {
            MessageRowActionButton(action: action) { label }
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
            if count == 1 { Text("1 reply") } else { Text("\(count) replies") }
        }
        .font(.system(size: fontSize, weight: .semibold))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
        .padding(.top, showsSeparator ? 5 : 0)
        .overlay(alignment: .top) {
            if showsSeparator {
                Rectangle()
                    .fill(isOutgoing ? Color.white.opacity(0.2) : Color.black.opacity(0.08))
                    .frame(height: 1)
            }
        }
        .opacity(0.8)
    }
}
