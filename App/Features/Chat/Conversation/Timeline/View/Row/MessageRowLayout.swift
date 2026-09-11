import SwiftUI

enum BubbleMetrics {
    static let rowHorizontalInset: CGFloat = 12
    static let rowVerticalInset: CGFloat = 4
    static let textHorizontalInset: CGFloat = 12
    static let textVerticalInset: CGFloat = 8
    static let avatarSize: CGFloat = 36
    static let avatarGap: CGFloat = 8
    static let widthFraction: CGFloat = 0.75

    static func maximumBubbleWidth(rowWidth: CGFloat, avatarSize: CGFloat = avatarSize) -> CGFloat {
        max(0, rowWidth - 2 * rowHorizontalInset - avatarSize - avatarGap) * widthFraction
    }

    static func textOnlyHeight(layout: MessageTextLayout, rowWidth: CGFloat) -> CGFloat {
        let width = max(1, min(layout.idealSize.width, maximumBubbleWidth(rowWidth: rowWidth) - 2 * textHorizontalInset))
        return max(avatarSize, layout.geometry(for: width).size.height + 2 * textVerticalInset) + 2 * rowVerticalInset
    }
}

/// The bubble, avatar, and accessory column are independent layout subviews.
struct MessageRowLayout: Layout {
    let isOutgoing: Bool
    let avatarSize: CGFloat

    func makeCache(subviews: Subviews) -> CGFloat {
        guard subviews.count >= 2 else { return 0 }
        let bubbleWidth = subviews[0].sizeThatFits(.unspecified).width
        let accessoryWidth = subviews.count > 2 ? subviews[2].sizeThatFits(.unspecified).width : 0
        return max(bubbleWidth, accessoryWidth)
    }

    private func dimensions(width: CGFloat?, idealWidth: CGFloat, subviews: Subviews) -> (row: CGSize, bubble: CGSize, accessories: CGSize) {
        guard subviews.count >= 2 else { return (.zero, .zero, .zero) }
        let avatarLane = avatarSize + BubbleMetrics.avatarGap
        let available = max(0, width ?? (idealWidth / BubbleMetrics.widthFraction + avatarLane))
        let cap = BubbleMetrics.maximumBubbleWidth(rowWidth: available + 2 * BubbleMetrics.rowHorizontalInset, avatarSize: avatarSize)
        let columnProposal = ProposedViewSize(width: min(idealWidth, cap), height: nil)
        let bubble = subviews[0].sizeThatFits(columnProposal)
        let accessories = subviews.count > 2 ? subviews[2].sizeThatFits(columnProposal) : .zero
        return (CGSize(width: available, height: max(avatarSize, bubble.height) + accessories.height), bubble, accessories)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CGFloat) -> CGSize {
        dimensions(width: proposal.width, idealWidth: cache, subviews: subviews).row
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CGFloat) {
        guard subviews.count >= 2 else { return }
        let sizes = dimensions(width: bounds.width, idealWidth: cache, subviews: subviews)
        let avatarLane = avatarSize + BubbleMetrics.avatarGap
        let bubbleBottom = bounds.minY + max(avatarSize, sizes.bubble.height)
        subviews[0].place(
            at: CGPoint(x: isOutgoing ? bounds.maxX - avatarLane - sizes.bubble.width : bounds.minX + avatarLane, y: bubbleBottom - sizes.bubble.height),
            anchor: .topLeading, proposal: .init(width: sizes.bubble.width, height: sizes.bubble.height)
        )
        subviews[1].place(
            at: CGPoint(x: isOutgoing ? bounds.maxX - avatarSize : bounds.minX, y: bubbleBottom - avatarSize),
            anchor: .topLeading, proposal: .init(width: avatarSize, height: avatarSize)
        )
        if subviews.count > 2 {
            subviews[2].place(
                at: CGPoint(x: isOutgoing ? bounds.maxX - avatarLane - sizes.accessories.width : bounds.minX + avatarLane, y: bubbleBottom),
                anchor: .topLeading, proposal: .init(width: sizes.accessories.width, height: sizes.accessories.height)
            )
        }
    }
}
