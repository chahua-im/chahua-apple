import ChahuaAPI
import SwiftUI

struct TextMessageBubble: View {
    let row: TimelineMessageRow
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TextBubbleRowLayout(isOutgoing: row.isOutgoing) {
            VStack(alignment: .leading, spacing: 4) {
                if row.showsSenderName {
                    senderName
                        .font(.caption.weight(.semibold))
                        .opacity(0.85)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if (row.entry.text ?? "").isEmpty {
                    timestamp
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .bottom, spacing: 8) {
                            messageText
                            timestamp
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 0) {
                            messageText
                            timestamp.frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(row.isOutgoing ? ChahuaTheme.ChatBubble.outgoingForeground : ChahuaTheme.ChatBubble.incomingForeground(for: colorScheme))
                .background(row.isOutgoing ? ChahuaTheme.ChatBubble.outgoingBackground : ChahuaTheme.ChatBubble.incomingBackground(for: colorScheme),
                            in: TextBubbleShape(isOutgoing: row.isOutgoing))
        }
        .padding(.horizontal, 12)
        .padding(.top, row.groupPosition == .first || row.groupPosition == .single ? 8 : 2)
    }

    private var messageText: some View {
        Text(row.entry.text ?? "")
            .font(.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var timestamp: some View {
        TimestampView(date: row.entry.createdAt, style: .time)
            .font(.caption)
            .opacity(0.7)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var senderName: Text {
        if let name = row.entry.remoteMessage?.sender.name, !name.isEmpty {
            Text(name)
        } else {
            Text("User \(row.entry.senderID)")
        }
    }
}

private struct TextBubbleRowLayout: Layout {
    let isOutgoing: Bool

    private func dimensions(proposal: ProposedViewSize, subviews: Subviews) -> (row: CGSize, child: CGSize) {
        guard let child = subviews.first else { return (.zero, .zero) }
        let ideal = child.sizeThatFits(.unspecified)
        let idealWidth = ideal.width.isFinite ? max(0, ideal.width) : 0
        let availableWidth = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil }
        let width = min(idealWidth, availableWidth.map { $0 * 0.75 } ?? idealWidth)
        let measured = child.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let height = measured.height.isFinite ? max(0, measured.height) : 0
        return (CGSize(width: availableWidth ?? width, height: height), CGSize(width: width, height: height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        dimensions(proposal: proposal, subviews: subviews).row
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = dimensions(proposal: proposal, subviews: subviews).child
        subviews.first?.place(at: CGPoint(x: isOutgoing ? bounds.maxX - size.width : bounds.minX, y: bounds.minY),
                              anchor: .topLeading, proposal: ProposedViewSize(width: size.width, height: nil))
    }
}

private struct TextBubbleShape: Shape {
    let isOutgoing: Bool

    func path(in rect: CGRect) -> Path {
        let limit = max(0, min(rect.width, rect.height) / 2)
        let radius = min(18, limit)
        let bottomLeft = min(isOutgoing ? 18 : 4, limit)
        let bottomRight = min(isOutgoing ? 4 : 18, limit)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addArc(center: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY - bottomRight), radius: bottomRight, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY - bottomLeft), radius: bottomLeft, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}
