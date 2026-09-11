import ChahuaAPI
import SwiftUI

/// Compact navigation to a replied-to message, independent of the current message kind.
/// The containing bubble owns placement, width, and surrounding padding.
struct MessageReplyBanner: View {
    let preview: MessagePreview
    let isOutgoing: Bool
    let hasFilledBackground: Bool
    var openReply: ((String) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption) private var fontSize: CGFloat = 12

    private var color: Color {
        isOutgoing && hasFilledBackground ? .white : bubbleColorForUser(uid: preview.sender.uid, dark: colorScheme == .dark)
    }

    var body: some View {
        if let openReply {
            MessageRowActionButton { openReply(preview.id) } label: { content }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(preview.sender.name.flatMap { $0.isEmpty ? nil : $0 } ?? "User \(preview.sender.uid)")
                .font(.system(size: fontSize * 11 / 12, weight: .semibold)).opacity(0.85).lineLimit(1)
            Text(messagePreview(preview))
                .font(.system(size: fontSize)).opacity(0.7).lineLimit(1).truncationMode(.tail)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .background(isOutgoing && hasFilledBackground ? Color.black.opacity(0.1) : color.opacity(0.1))
        .overlay(alignment: .leading) { Rectangle().fill(color.opacity(isOutgoing ? 0.5 : 1)).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
