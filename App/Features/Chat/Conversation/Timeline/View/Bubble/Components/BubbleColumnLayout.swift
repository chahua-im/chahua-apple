import SwiftUI

/// Measure natural widths before proposing a bounded common column. Expanding
/// alignment frames in a reply/thread must never choose the row's maximum width.
struct BubbleColumnLayout: Layout {
    var alignment: HorizontalAlignment = .leading
    // SwiftUI refreshes this cache when subviews change. Re-probing natural widths
    // for each bounded proposal would repeatedly switch TextKit away from its wrapped layout.
    func makeCache(subviews: Subviews) -> CGFloat {
        subviews.reduce(CGFloat.zero) { max($0, $1.sizeThatFits(.unspecified).width) }
    }

    private func dimensions(proposal: ProposedViewSize, idealWidth: CGFloat, subviews: Subviews) -> CGSize {
        let width = min(idealWidth, max(0, proposal.width ?? idealWidth))
        let height = subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.init(width: width, height: nil)).height }
        return CGSize(width: width, height: height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CGFloat) -> CGSize {
        dimensions(proposal: proposal, idealWidth: cache, subviews: subviews)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CGFloat) {
        var y = bounds.minY
        for subview in subviews {
            let size = subview.sizeThatFits(.init(width: bounds.width, height: nil))
            let x = alignment == .trailing ? bounds.maxX - size.width : bounds.minX
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .init(width: size.width, height: size.height))
            y += size.height
        }
    }
}
