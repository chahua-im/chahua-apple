#if os(iOS)
import ChahuaAPI
import SwiftUI

struct BubbleLocalMedia: View {
    let attachments: [LocalOutgoingAttachment]
    let size: CGSize
    let itemFrames: [CGRect]

    var body: some View {
        BubbleMediaContent(attachments: attachments, size: size, itemFrames: itemFrames) { attachment, size, gallery, overflowCount in
            let isVideo = attachment.mimeType.hasPrefix("video/")
            LocalOutgoingImagePreview(
                path: attachment.previewPath,
                contentMode: gallery ? .fill : .fit,
                showsBlurredBackdrop: !gallery
            )
            .overlay {
                if isVideo {
                    Image(systemName: "play.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.5), in: Circle())
                }
            }
            .modifier(BubbleMediaTileSurface(size: size, gallery: gallery, isVideo: isVideo, overflowCount: overflowCount))
            .accessibilityLabel(attachment.fileName)
        }
    }
}


#endif
