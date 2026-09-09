import ChahuaAPI
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

    static func textOnlyHeight(layout: BubbleTextLayout, rowWidth: CGFloat) -> CGFloat {
        let width = max(1, min(layout.idealSize.width, maximumBubbleWidth(rowWidth: rowWidth) - 2 * textHorizontalInset))
        return max(avatarSize, layout.geometry(for: width).size.height + 2 * textVerticalInset) + 2 * rowVerticalInset
    }
}

struct ChatMessageBubble: View {
    let row: TimelineMessageRow
    let context: TimelineRowContext
    let actions: TimelineBubbleActions
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption) private var metadataSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var overlayMetadataSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption) private var senderSize: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = BubbleMetrics.avatarSize

    private var message: MessageResponse? { row.entry.remoteMessage }
    private var isSticker: Bool { row.entry.messageType == .sticker }
    private var showsSender: Bool { row.showsSenderName && !isSticker }
    private var attachments: [AttachmentResponse] { message?.attachments ?? [] }
    private var bodyText: String { row.entry.text ?? "" }
    private var hasBody: Bool { !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var mediaOnly: Bool { !attachments.isEmpty && !hasBody }
    private var replyPreview: MessagePreview? {
        guard let preview = message?.replyToMessage, !preview.isDeleted else { return nil }
        return preview
    }
    private var threadCount: Int64? { context.isThreadTimeline ? nil : message?.threadInfo?.replyCount }
    private var hasBackground: Bool { !isSticker && (!mediaOnly || showsSender || replyPreview != nil || threadCount != nil) }
    private var hasTail: Bool { !isSticker && !mediaOnly && (row.groupPosition == .single || row.groupPosition == .last) }
    private var foreground: Color { row.isOutgoing && hasBackground ? ChahuaTheme.ChatBubble.outgoingForeground : ChahuaTheme.ChatBubble.incomingForeground(for: colorScheme) }
    private var background: Color { row.isOutgoing ? ChahuaTheme.ChatBubble.outgoingBackground : ChahuaTheme.ChatBubble.incomingBackground(for: colorScheme) }

    // Context carries the actual row width, not screen/window width. This is the
    // same post-avatar cap used by BubbleRowLayout's final layout proposal.
    private var availableMediaWidth: CGFloat { BubbleMetrics.maximumBubbleWidth(rowWidth: context.viewportSize.width, avatarSize: avatarSize) }
    private var mediaSize: CGSize? {
        guard let first = attachments.first else { return nil }
        if attachments.count == 1 {
            return BubbleMediaLayout.singleSize(for: first, viewport: context.viewportSize, availableWidth: availableMediaWidth)
        }
        return BubbleMediaLayout.gallery(for: attachments, viewport: context.viewportSize, availableWidth: availableMediaWidth)?.size
    }

    var body: some View {
        let mediaSize = mediaSize
        MessageBubbleShell(row: row, context: context, styled: false) {
            bubble(mediaSize: mediaSize)
        }
    }

    private func bubble(mediaSize: CGSize?) -> some View {
        BubbleColumnLayout {
            if showsSender {
                sender
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
            if let preview = replyPreview {
                reply(preview)
                    .padding(.horizontal, isSticker ? 0 : 12)
                    .padding(.top, showsSender || isSticker ? 0 : 8)
                    .padding(.bottom, 6)
            }
            if isSticker {
                BubbleSticker(sticker: message?.sticker, viewport: context.viewportSize, availableWidth: availableMediaWidth, isMeasuring: context.isMeasuring)
                    .overlay(alignment: .bottomTrailing) {
                        textContent(text: "", overlay: true)
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                            .padding(4)
                    }
            }
            if !isSticker, let mediaSize, mediaSize.width > 0, mediaSize.height > 0 {
                BubbleMedia(
                    messageID: message?.id ?? "", attachments: attachments,
                    viewport: context.viewportSize, availableWidth: availableMediaWidth,
                    isMeasuring: context.isMeasuring, action: actions.openMedia
                )
                .overlay(alignment: .bottomTrailing) {
                    if mediaOnly {
                        textContent(text: "", overlay: true)
                            .frame(maxWidth: max(1, mediaSize.width - 24))
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                            .padding(6)
                    }
                }
                .padding(.top, row.showsSenderName || replyPreview != nil ? 4 : 0)
            }
            if !isSticker && !mediaOnly {
                textContent(text: hasBody ? bodyText : "", overlay: false)
                    .padding(.horizontal, BubbleMetrics.textHorizontalInset)
                    .padding(.top, !attachments.isEmpty ? 4 : (row.showsSenderName || replyPreview != nil ? 0 : BubbleMetrics.textVerticalInset))
                    .padding(.bottom, threadCount == nil ? BubbleMetrics.textVerticalInset : 0)
            }
            if let count = threadCount {
                threadIndicator(count)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: isSticker ? min(200, max(1, availableMediaWidth)) : mediaSize?.width)
        .foregroundStyle(foreground)
        // Clip the content, never the background droplet extending outside it.
        .clipShape(BubbleShape(isOutgoing: row.isOutgoing, hasTail: hasTail, drawsTail: false, cornerRadius: isSticker ? 0 : 18))
        .background {
            if hasBackground {
                BubbleShape(isOutgoing: row.isOutgoing, hasTail: hasTail)
                    .fill(background)
            }
        }
    }

    private var failureAction: (() -> Void)? {
        guard row.isOutgoing, case .pending(let pending) = row.entry, pending.state == .failed,
              let openFailedMessage = actions.openFailedMessage else { return nil }
        return { openFailedMessage(pending.clientGeneratedID) }
    }

    private func textContent(text: String, overlay: Bool) -> some View {
        BubbleTextContent(
            text: text, mentions: message?.mentions ?? [], currentUserID: context.currentUserID,
            isOutgoing: row.isOutgoing, action: actions.openLink, mentionAction: actions.openMention,
            metadata: BubbleMetadata(
                row: row, isOverlay: overlay,
                fontSize: overlay ? overlayMetadataSize : metadataSize
            ),
            failureAction: failureAction
        )
    }


    private var sender: some View {
        HStack(spacing: 8) {
            Text(senderName)
                .font(.system(size: senderSize, weight: .semibold))
                .foregroundStyle(row.isOutgoing && hasBackground ? .white : bubbleColorForUser(name: senderName, dark: colorScheme == .dark))
                .opacity(0.85)
                .lineLimit(1)
            if let group = message?.sender.userGroup, let name = group.name, !name.isEmpty {
                Text(name)
                    .font(.system(size: senderSize * 10 / 12))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .background(groupColor(group), in: RoundedRectangle(cornerRadius: 2))
                    .opacity(0.85)
            }
            if let gender = message?.sender.gender, gender == 1 || gender == 2 {
                Text(gender == 1 ? "♂" : "♀")
                    .font(.system(size: senderSize))
                    .foregroundStyle(bubbleColor(hex: gender == 1 ? "3cb4f0" : "ff8080") ?? .primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func groupColor(_ group: UserGroupTagInfo) -> Color {
        let darkOverride = group.chatGroupColorDark.flatMap { $0.isEmpty ? nil : $0 }
        let hex = colorScheme == .dark ? (darkOverride ?? group.chatGroupColor) : group.chatGroupColor
        return hex.flatMap(bubbleColor(hex:)) ?? Color.gray.opacity(0.44)
    }

    @ViewBuilder private func reply(_ preview: MessagePreview) -> some View {
        let name = preview.sender.name.flatMap { $0.isEmpty ? nil : $0 } ?? "User \(preview.sender.uid)"
        let color = row.isOutgoing && hasBackground ? Color.white : bubbleColorForUser(name: name, dark: colorScheme == .dark)
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.system(size: senderSize * 11 / 12, weight: .semibold)).opacity(0.85).lineLimit(1)
            Text(messagePreview(preview)).font(.system(size: senderSize)).opacity(0.7).lineLimit(1).truncationMode(.tail)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .background(row.isOutgoing && hasBackground ? Color.black.opacity(0.1) : color.opacity(0.1))
        .overlay(alignment: .leading) { Rectangle().fill(color.opacity(row.isOutgoing ? 0.5 : 1)).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        if let action = actions.openReply {
            Button { action(preview.id) } label: { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    @ViewBuilder private func threadIndicator(_ count: Int64) -> some View {
        let content = HStack(spacing: 4) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
            if count == 1 { Text("1 reply") } else { Text("\(count) replies") }
        }
        .font(.system(size: senderSize, weight: .semibold))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: row.isOutgoing ? .trailing : .leading)
        .padding(.top, mediaOnly || isSticker ? 0 : 5)
        .overlay(alignment: .top) {
            if !mediaOnly && !isSticker {
                Rectangle().fill(row.isOutgoing ? Color.white.opacity(0.2) : Color.black.opacity(0.08)).frame(height: 1)
            }
        }
        .opacity(0.8)
        if let action = actions.openThread, let id = message?.id {
            Button { action(id) } label: { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private var senderName: String {
        message?.sender.name.flatMap { $0.isEmpty ? nil : $0 } ?? "User \(row.entry.senderID)"
    }
}

struct BubbleRowLayout: Layout {
    let isOutgoing: Bool
    let avatarSize: CGFloat

    func makeCache(subviews: Subviews) -> CGFloat {
        guard subviews.count == 2 else { return 0 }
        return subviews[0].sizeThatFits(.unspecified).width
    }

    private func dimensions(width: CGFloat?, idealWidth: CGFloat, subviews: Subviews) -> (row: CGSize, bubble: CGSize) {
        guard subviews.count == 2 else { return (.zero, .zero) }
        let avatarLane = avatarSize + BubbleMetrics.avatarGap
        let available = max(0, width ?? (idealWidth / BubbleMetrics.widthFraction + avatarLane))
        let cap = BubbleMetrics.maximumBubbleWidth(rowWidth: available + 2 * BubbleMetrics.rowHorizontalInset, avatarSize: avatarSize)
        let bubble = subviews[0].sizeThatFits(.init(width: min(idealWidth, cap), height: nil))
        return (CGSize(width: available, height: max(avatarSize, bubble.height)), bubble)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CGFloat) -> CGSize {
        dimensions(width: proposal.width, idealWidth: cache, subviews: subviews).row
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CGFloat) {
        guard subviews.count == 2 else { return }
        let bubble = dimensions(width: bounds.width, idealWidth: cache, subviews: subviews).bubble
        let avatarLane = avatarSize + BubbleMetrics.avatarGap
        subviews[0].place(
            at: CGPoint(x: isOutgoing ? bounds.maxX - avatarLane - bubble.width : bounds.minX + avatarLane, y: bounds.maxY - bubble.height),
            anchor: .topLeading, proposal: .init(width: bubble.width, height: bubble.height)
        )
        subviews[1].place(
            at: CGPoint(x: isOutgoing ? bounds.maxX - avatarSize : bounds.minX, y: bounds.maxY - avatarSize),
            anchor: .topLeading, proposal: .init(width: avatarSize, height: avatarSize)
        )
    }
}

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

func bubbleColorForUser(name: String, dark: Bool) -> Color {
    let light = ["CA5650", "D87B29", "9B66DC", "50B232", "379EB8", "4E92CC", "CF5C95"]
    let darkPalette = ["D45246", "F68136", "6C61DF", "46BA43", "5CAFFA", "408ACF", "D95574"]
    var hash: Int32 = 0
    // JavaScript iterates code points but charCodeAt(0) takes the first UTF-16 unit.
    for scalar in name.unicodeScalars {
        let unit = scalar.value > 0xffff ? 0xd800 + ((scalar.value - 0x10000) >> 10) : scalar.value
        hash = (hash &* 31) &+ Int32(unit)
    }
    let palette = dark ? darkPalette : light
    return bubbleColor(hex: palette[Int(abs(Int64(hash)) % Int64(palette.count))]) ?? .primary
}

private func bubbleColor(hex: String) -> Color? {
    let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard value.count == 6 || value.count == 8, let number = UInt64(value, radix: 16) else { return nil }
    let rgb = value.count == 8 ? number >> 8 : number
    return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                 green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255,
                 opacity: value.count == 8 ? Double(number & 255) / 255 : 1)
}
