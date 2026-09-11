import SwiftUI

/// A bubble's visual surface only. Row placement and interaction live outside it.
struct MessageBubbleSurface: ViewModifier {
    let isOutgoing: Bool
    let hasTail: Bool
    var isFilled = true
    var cornerRadius: CGFloat = 18
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .clipShape(BubbleShape(isOutgoing: isOutgoing, hasTail: hasTail, drawsTail: false, cornerRadius: cornerRadius))
            .background {
                if isFilled {
                    BubbleShape(isOutgoing: isOutgoing, hasTail: hasTail, cornerRadius: cornerRadius)
                        .fill(isOutgoing ? ChahuaTheme.ChatBubble.outgoingBackground : ChahuaTheme.ChatBubble.incomingBackground(for: colorScheme))
                }
            }
    }
}

struct BubbleShape: Shape {
    let isOutgoing: Bool
    let hasTail: Bool
    var drawsTail = true
    var cornerRadius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let smallCorner: CGFloat = hasTail ? 0 : 4
        var path = Path(roundedRect: rect, cornerRadii: .init(
            topLeading: cornerRadius, bottomLeading: isOutgoing ? cornerRadius : min(smallCorner, cornerRadius),
            bottomTrailing: isOutgoing ? min(smallCorner, cornerRadius) : cornerRadius, topTrailing: cornerRadius
        ), style: .circular)
        guard hasTail && drawsTail else { return path }
        // Exact received SCSS droplet; the sent path is its x=4 reflection.
        var tail = Path()
        tail.move(to: CGPoint(x: 1, y: 17))
        tail.addLine(to: CGPoint(x: 8, y: 17))
        tail.addLine(to: CGPoint(x: 8, y: 0))
        tail.addCurve(to: CGPoint(x: 5.9, y: 8.8), control1: CGPoint(x: 7.8, y: 2.84), control2: CGPoint(x: 7.1, y: 5.8))
        tail.addCurve(to: CGPoint(x: 1.3, y: 15.3), control1: CGPoint(x: 5, y: 11.1), control2: CGPoint(x: 3.5, y: 13.3))
        let halfChord: CGFloat = sqrt(2.98) / 2
        let offset = sqrt(1 - halfChord * halfChord) / (halfChord * 2)
        let center = CGPoint(x: 1.15 + 1.7 * offset, y: 16.15 + 0.3 * offset)
        tail.addArc(center: center, radius: 1,
                    startAngle: .radians(atan2(15.3 - center.y, 1.3 - center.x)),
                    endAngle: .radians(atan2(17 - center.y, 1 - center.x)), clockwise: true)
        tail.closeSubpath()
        let transform = isOutgoing
            ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.maxX + 8, ty: rect.maxY - 17)
            : CGAffineTransform(translationX: rect.minX - 8, y: rect.maxY - 17)
        path.addPath(tail, transform: transform)
        return path
    }
}
