import AVFoundation
import AVKit
import ImageIO
import SwiftUI

/// The unified share sheet keeps the shared items visible while a destination is chosen.
/// Video playback remains available from the compact gallery without adding a navigation step.
struct ShareSharedContentPreview: View {
    let media: [ShareMedia]
    let message: String

    var body: some View {
        Group {
            if media.isEmpty {
                ShareTextPreview(message: message)
            } else {
                ShareMediaPreviewGallery(media: media)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ShareTextPreview: View {
    let message: String

    var body: some View {
        ScrollView {
            Text(message.isEmpty ? "No message was included." : message)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(16)
        }
        .background(Color.secondary.opacity(0.08))
        .accessibilityLabel("Shared message preview")
    }
}

private struct ShareMediaPreviewGallery: View {
    let media: [ShareMedia]

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let viewportHeight = max(1, geometry.size.height)
            ScrollView {
                if media.count == 1, let item = media.first {
                    let aspectRatio = CGFloat(max(1, item.width)) / CGFloat(max(1, item.height))
                    let height = min(viewportHeight, width / aspectRatio)
                    ShareMediaPreviewTile(media: item)
                        .frame(width: min(width, height * aspectRatio), height: height)
                        .frame(maxWidth: .infinity)
                } else {
                    let cellWidth = max(1, (width - 4) / 2)
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4),
                        ],
                        spacing: 4
                    ) {
                        ForEach(media) { item in
                            ShareMediaPreviewTile(media: item)
                                .frame(height: cellWidth)
                        }
                    }
                    .frame(width: width)
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(minHeight: viewportHeight)
        }
        .padding(.horizontal, 12)
    }
}

private struct ShareMediaPreviewTile: View {
    let media: ShareMedia
    @State private var showsPlayer = false

    var body: some View {
        Group {
            if media.isVideo {
                Button {
                    showsPlayer = true
                } label: {
                    thumbnail
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play \(media.fileName)")
            } else {
                thumbnail
                    .accessibilityLabel(media.fileName)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $showsPlayer) {
            ShareVideoPlayer(url: media.url)
        }
    }

    private var thumbnail: some View {
        ShareMediaThumbnail(media: media)
            .overlay {
                if media.isVideo {
                    Image(systemName: "play.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(.black.opacity(0.35), in: Circle())
                        .accessibilityHidden(true)
                }
            }
    }
}

private struct ShareMediaThumbnail: View {
    let media: ShareMedia
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
            }
        }
        .clipped()
        .task(id: media.id) {
            image = nil
            let preview = await ShareMediaThumbnailLoader.load(media: media)
            guard !Task.isCancelled else { return }
            image = preview
        }
    }
}

private struct ShareVideoPlayer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Close") {
                    player.pause()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            VideoPlayer(player: player)
                .onAppear { player.play() }
        }
        .frame(minWidth: 320, minHeight: 240)
        .onDisappear { player.pause() }
    }
}

extension ShareMedia {
    fileprivate var isVideo: Bool { contentType.lowercased().hasPrefix("video/") }
}

private enum ShareMediaThumbnailLoader {
    nonisolated static func load(media: ShareMedia, maximumPixelSize: Int = 1_024) async -> CGImage?
    {
        let task = Task.detached(priority: .utility) {
            if media.contentType.lowercased().hasPrefix("video/") {
                return await videoThumbnail(for: media.url, maximumPixelSize: maximumPixelSize)
            }
            return imageThumbnail(for: media.url, maximumPixelSize: maximumPixelSize)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func imageThumbnail(for url: URL, maximumPixelSize: Int) -> CGImage?
    {
        guard !Task.isCancelled,
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            ] as CFDictionary)
    }

    nonisolated private static func videoThumbnail(for url: URL, maximumPixelSize: Int) async
        -> CGImage?
    {
        guard !Task.isCancelled else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
        do {
            return try await withTaskCancellationHandler {
                guard !Task.isCancelled else { return nil }
                return try await generator.image(at: .zero).image
            } onCancel: {
                generator.cancelAllCGImageGeneration()
            }
        } catch {
            return nil
        }
    }
}
