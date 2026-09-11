import ChahuaAPI
import SwiftUI

struct BubbleLocalMedia: View {
    let attachments: [LocalOutgoingAttachment]
    let width: CGFloat
    let progress: [String: Double]
    let isMeasuring: Bool

    var body: some View {
        let columns = attachments.count == 1 ? 1 : 2
        let cellWidth = (width - CGFloat(columns - 1) * 4) / CGFloat(columns)
        VStack(spacing: 4) {
            ForEach(0..<((attachments.count + columns - 1) / columns), id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = row * columns + column
                        if index < attachments.count {
                            let attachment = attachments[index]
                            LocalOutgoingImagePreview(path: attachment.previewPath, isMeasuring: isMeasuring)
                                .frame(width: cellWidth, height: imageHeight(attachment, width: cellWidth, single: columns == 1))
                                .overlay(alignment: .bottomLeading) {
                                    OutgoingImageStatus(attachment: attachment, progress: progress[attachment.id])
                                        .foregroundStyle(.white)
                                        .padding(6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(.black.opacity(0.6))
                                }
                                .clipped()
                                .accessibilityLabel(attachment.fileName)
                        } else {
                            Color.clear.frame(width: cellWidth, height: cellWidth)
                        }
                    }
                }
            }
        }
        .frame(width: width)
    }

    private func imageHeight(_ attachment: LocalOutgoingAttachment, width: CGFloat, single: Bool) -> CGFloat {
        guard single else { return width }
        return min(width * 1.4, max(width * 0.55, width * CGFloat(max(1, attachment.height)) / CGFloat(max(1, attachment.width))))
    }
}
