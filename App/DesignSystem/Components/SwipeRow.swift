import SwiftUI

struct SwipeRowAction: Equatable {
    let action: String
    let title: String
    let symbol: String
    let tint: Color
}

/// Native adapters own touch/trackpad arbitration; callers share actions and styling.
struct SwipeRow<ID: Hashable, Content: View>: View {
    let id: ID
    @Binding var revealedID: ID?
    let leadingAction: SwipeRowAction?
    let trailingActions: [SwipeRowAction]
    var isBusy = false
    let onAction: (String) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(iOS)
        SwipeRowUIKit(
            id: AnyHashable(id), isRevealed: revealedID == id,
            leadingAction: leadingAction, trailingActions: trailingActions,
            isBusy: isBusy, onRevealChanged: setRevealed, onAction: onAction, content: content)
        #else
        SwipeRowAppKit(
            id: AnyHashable(id), isRevealed: revealedID == id,
            leadingAction: leadingAction, trailingActions: trailingActions,
            isBusy: isBusy, onRevealChanged: setRevealed, onAction: onAction, content: content)
        #endif
    }

    private func setRevealed(_ revealed: Bool) {
        if revealed { revealedID = id }
        else if revealedID == id { revealedID = nil }
    }
}

enum SwipeRowMetrics {
    static let diameter: CGFloat = 44
    static let edgeInset: CGFloat = 12
    static let spacing: CGFloat = 8
    static let leadingReveal = diameter + edgeInset * 2
    static let symbolSize: CGFloat = 20
    static let animationDuration: TimeInterval = 0.22

    static func trailingReveal(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * diameter + CGFloat(count - 1) * spacing + edgeInset * 2
    }

    static func commitBoundary(width: CGFloat) -> CGFloat {
        min(max(leadingReveal + 64, width * 0.56), width - edgeInset * 2)
    }

    static func dragOffset(proposed: CGFloat, width: CGFloat, hasLeading: Bool, trailingCount: Int) -> CGFloat {
        if proposed > 0, hasLeading {
            return min(proposed, max(leadingReveal, width - edgeInset))
        }
        if proposed < 0, trailingCount > 0 {
            let reveal = trailingReveal(count: trailingCount)
            let excess = max(0, -proposed - reveal)
            return max(proposed, -reveal) - min(18, excess * 0.15)
        }
        return 0
    }

    static func restingOffset(offset: CGFloat, trailingCount: Int) -> CGFloat {
        if offset > 0 { return offset >= leadingReveal / 2 ? leadingReveal : 0 }
        let reveal = trailingReveal(count: trailingCount)
        return -offset >= reveal / 2 ? -reveal : 0
    }
}
