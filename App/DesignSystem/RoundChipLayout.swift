import SwiftUI

/// A single glyph gets a true circle; longer labels can only extend horizontally.
struct RoundChipLayout: Layout {
    var isCircular: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(.unspecified)
        let width = max(size.width, size.height)
        return CGSize(width: width, height: isCircular ? width : size.height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews.first?.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
            proposal: .unspecified)
    }
}
