#if os(iOS)
import SwiftUI

private struct TimelineSectionIDKey: LayoutValueKey {
    static let defaultValue: TimelineSectionID? = nil
}

extension View {
    func timelineSection(_ id: TimelineSectionID) -> some View {
        layoutValue(key: TimelineSectionIDKey.self, value: id)
    }
}

struct TimelineSectionLayout: Layout {
    let size: CGSize
    let frames: [TimelineSectionID: CGRect]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize { size }

    // Cached absolute placement has no descendant-propagated alignment guides.
    // Layout's default implementation would traverse and measure the children.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGFloat? { nil }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        for subview in subviews {
            guard let id = subview[TimelineSectionIDKey.self], let frame = frames[id] else { continue }
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading, proposal: .init(width: frame.width, height: frame.height))
        }
    }
}

/// Ordered gallery/reaction/title items already have their final frames.
struct TimelineItemLayout: Layout {
    let size: CGSize
    let frames: [CGRect]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize { size }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGFloat? { nil }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        for (view, frame) in zip(subviews, frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading, proposal: .init(frame.size))
        }
    }
}


#endif
