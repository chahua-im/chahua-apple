#if os(macOS)
import ChahuaAPI
import ChahuaMediaCache
import SwiftUI

struct MacBubbleMedia: View {
    let messageID: String
    let attachments: [AttachmentResponse]
    let viewport: CGSize
    let availableWidth: CGFloat
    let isMeasuring: Bool
    let action: ((String, [AttachmentResponse], String) -> Void)?

    var body: some View {
        if attachments.count == 1, let attachment = attachments.first,
           let size = MacBubbleMediaLayout.singleSize(for: attachment, viewport: viewport, availableWidth: availableWidth) {
            tile(attachment, size: size, gallery: false)
        } else if let gallery = MacBubbleMediaLayout.gallery(for: attachments, viewport: viewport, availableWidth: availableWidth) {
            ZStack(alignment: .topLeading) {
                ForEach(gallery.cells, id: \.attachment.id) { cell in
                    tile(cell.attachment, size: cell.frame.size, gallery: true, overflowCount: cell.overflowCount)
                        .offset(x: cell.frame.minX, y: cell.frame.minY)
                }
            }
            .frame(width: gallery.size.width, height: gallery.size.height, alignment: .topLeading)
            .clipped()
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
                    animates: true,
                    showsBlurredBackdrop: !gallery,
                    tag: CacheTag(rawValue: "chatMedia")
                )
            }
        }
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

        if let action, !isMeasuring {
            Button { action(messageID, attachments, attachment.id) } label: { content }
                .buttonStyle(.plain)
                .accessibilityLabel(isVideo ? "Open video" : "Open image")
        } else { content }
    }
}

#endif
