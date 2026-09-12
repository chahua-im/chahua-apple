import ChahuaAPI
import SwiftUI

struct BubbleMedia: View {
    let messageID: String
    let attachments: [AttachmentResponse]
    let viewport: CGSize
    let availableWidth: CGFloat
    let isMeasuring: Bool
    let action: ((String, [AttachmentResponse], String) -> Void)?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        BubbleMediaContent(attachments: attachments, viewport: viewport, availableWidth: availableWidth) { attachment, size, gallery, overflowCount in
            tile(attachment, size: size, gallery: gallery, overflowCount: overflowCount)
        }
    }

    @ViewBuilder private func tile(_ attachment: AttachmentResponse, size: CGSize, gallery: Bool, overflowCount: Int = 0) -> some View {
        let isVideo = attachment.kind.hasPrefix("video/")
        let content = Group {
            if isMeasuring {
                Color.clear
            } else if isVideo {
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

        if let action, !isMeasuring, !isVideo {
            MessageRowActionButton { action(messageID, attachments, attachment.id) } label: { content }
                .accessibilityLabel("Open image")
        } else { content }
    }
}

/// Pending and delivered attachments share placement and tile chrome, not storage records.
struct BubbleMediaContent<Attachment: BubbleMediaAttachment, Tile: View>: View {
    let attachments: [Attachment]
    let viewport: CGSize
    let availableWidth: CGFloat
    @ViewBuilder let tile: (Attachment, CGSize, Bool, Int) -> Tile

    var body: some View {
        if attachments.count == 1, let attachment = attachments.first,
           let size = BubbleMediaLayout.singleSize(for: attachment, viewport: viewport, availableWidth: availableWidth) {
            tile(attachment, size, false, 0)
        } else if let gallery = BubbleMediaLayout.gallery(for: attachments, viewport: viewport, availableWidth: availableWidth) {
            ZStack(alignment: .topLeading) {
                ForEach(gallery.cells, id: \.attachment.id) { cell in
                    tile(cell.attachment, cell.frame.size, true, cell.overflowCount)
                        .offset(x: cell.frame.minX, y: cell.frame.minY)
                }
            }
            .frame(width: gallery.size.width, height: gallery.size.height, alignment: .topLeading)
            .clipped()
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
