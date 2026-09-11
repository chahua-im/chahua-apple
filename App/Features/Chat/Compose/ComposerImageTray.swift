import ChahuaAPI
import ImageIO
import SwiftUI

/// Local media is intentionally separate from server attachments: an allocated ID is
/// not evidence of a successful upload, and its server thumbnail may not exist yet.
struct LocalOutgoingImagePreview: View {
    let path: String
    var isMeasuring = false
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: isMeasuring ? "" : path) {
            guard !isMeasuring else { return }
            image = nil
            let sourcePath = path
            let decoded = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: sourcePath) as CFURL, nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 640,
                ] as CFDictionary)
            }.value
            guard !Task.isCancelled else { return }
            image = decoded
        }
    }
}

struct OutgoingImageStatus: View {
    let attachment: LocalOutgoingAttachment
    var progress: Double?

    var body: some View {
        HStack(spacing: 4) {
            if attachment.error != nil {
                Image(systemName: "exclamationmark.circle.fill")
                Text("Failed")
            } else if attachment.attachmentID != nil {
                Image(systemName: "checkmark.circle.fill")
                Text("Ready")
            } else if let progress {
                ProgressView(value: progress).frame(width: 32)
                Text(progress, format: .percent.precision(.fractionLength(0)))
            } else {
                ProgressView().controlSize(.mini)
                Text(attachment.preparedPath == nil ? "Processing" : "Waiting to upload")
            }
        }
        .font(.caption2)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityHint(attachment.error ?? "")
    }
}

struct ComposerImageTray: View {
    let attachments: [LocalOutgoingAttachment]
    let progress: [String: Double]
    let isEnabled: Bool
    let compressionEnabled: Bool
    let onRemove: (String) -> Void
    let onRetry: (String) -> Void
    let onCompressionChanged: (Bool) -> Void
    let onReorder: ([String]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                        VStack(alignment: .leading, spacing: 4) {
                            LocalOutgoingImagePreview(path: attachment.previewPath)
                                .frame(width: 112, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(alignment: .topTrailing) {
                                    Button { onRemove(attachment.id) } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.65))
                                            .padding(4)
                                    }
                                    .accessibilityLabel("Remove \(attachment.fileName)")
                                }
                            OutgoingImageStatus(attachment: attachment, progress: progress[attachment.id])
                                .frame(width: 112, height: 18, alignment: .leading)
                            Menu {
                                if let error = attachment.error {
                                    Text(error)
                                    Button("Retry") { onRetry(attachment.id) }
                                }
                                Button("Move earlier") { move(index, by: -1) }.disabled(index == 0)
                                Button("Move later") { move(index, by: 1) }.disabled(index == attachments.count - 1)
                                Button("Remove", role: .destructive) { onRemove(attachment.id) }
                            } label: {
                                Text(attachment.fileName).font(.caption2).lineLimit(1).frame(width: 112, alignment: .leading)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            Toggle("Compress images", isOn: Binding(get: { compressionEnabled }, set: onCompressionChanged))
                .font(.caption)
                .toggleStyle(.switch)
                .fixedSize()
        }
        .disabled(!isEnabled)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 12)
    }

    private func move(_ index: Int, by offset: Int) {
        var ids = attachments.map(\.id)
        ids.swapAt(index, index + offset)
        onReorder(ids)
    }
}
