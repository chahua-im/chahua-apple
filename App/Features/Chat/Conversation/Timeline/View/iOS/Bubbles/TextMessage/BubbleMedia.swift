#if os(iOS)
import ChahuaAPI
import SwiftUI

struct BubbleMedia: View {
    let messageID: String
    let attachments: [AttachmentResponse]
    let size: CGSize
    let itemFrames: [CGRect]
    let action: ((String, [AttachmentResponse], String) -> Void)?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        BubbleMediaContent(attachments: attachments, size: size, itemFrames: itemFrames) { attachment, size, gallery, overflowCount in
            tile(attachment, size: size, gallery: gallery, overflowCount: overflowCount)
        }
    }

    @ViewBuilder private func tile(_ attachment: AttachmentResponse, size: CGSize, gallery: Bool, overflowCount: Int = 0) -> some View {
        let isVideo = attachment.kind.hasPrefix("video/")
        let content = Group {
            if isVideo {
                Label("Video preview unavailable", systemImage: "video.slash")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(8)
            } else {
                RemoteImageView(
                    url: URL(string: attachment.url),
                    contentMode: gallery ? .fill : .fit,
                    animates: RemoteImageFormat.isAnimated(contentType: attachment.kind),
                    showsBlurredBackdrop: !gallery,
                    thumbnailPixelSize: CGSize(width: size.width * displayScale, height: size.height * displayScale)
                )
            }
        }
        .modifier(BubbleMediaTileSurface(size: size, gallery: gallery, isVideo: isVideo, overflowCount: overflowCount))

        if let action, !isVideo {
            MessageRowActionButton { action(messageID, attachments, attachment.id) } label: { content }
                .accessibilityLabel("Open image")
        } else { content }
    }
}

/// Pending and delivered attachments share placement and tile chrome, not storage records.
struct BubbleMediaContent<Attachment: BubbleMediaAttachment, Tile: View>: View {
    let attachments: [Attachment]
    let size: CGSize
    let itemFrames: [CGRect]
    @ViewBuilder let tile: (Attachment, CGSize, Bool, Int) -> Tile

    var body: some View {
        if attachments.count == 1, let attachment = attachments.first {
            tile(attachment, size, false, 0)
        } else {
            BubbleMediaItemLayout(size: size, frames: itemFrames) {
                ForEach(attachments.indices.prefix(min(6, itemFrames.count)), id: \.self) { index in
                    tile(
                        attachments[index],
                        itemFrames[index].size,
                        true,
                        index == 5 && attachments.count > 6 ? attachments.count - 5 : 0
                    )
                }
            }
            .clipped()
        }
    }
}

private struct BubbleMediaItemLayout: Layout {
    let size: CGSize
    let frames: [CGRect]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize { size }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGFloat? { nil }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: .init(width: frame.width, height: frame.height)
            )
        }
    }
}

struct BubbleMediaTileSurface: ViewModifier {
    let size: CGSize
    let gallery: Bool
    let isVideo: Bool
    let overflowCount: Int

    func body(content: Content) -> some View {
        content
            .frame(width: size.width, height: size.height)
            .background(gallery && !isVideo ? Color(red: 244 / 255, green: 244 / 255, blue: 245 / 255) : .black)
            .blur(radius: overflowCount > 0 ? 2 : 0)
            .overlay {
                if overflowCount > 0 {
                    ZStack {
                        Color.black.opacity(0.4)
                        Text("+\(overflowCount)")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipped()
            .contentShape(Rectangle())
    }
}


#endif
