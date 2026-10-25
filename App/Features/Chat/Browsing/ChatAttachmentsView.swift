import ChahuaAPI
import Kingfisher
import SwiftUI

/// Each mounted browser owns its cursor; media kinds never share a page.
struct ChatAttachmentsView: View {
    @ObservedObject var store: ChatStore
    let chatID: String
    let kind: ChatAttachmentKind
    let onOpenMessage: (MessageResponse) -> Void
    var embedded = false
    var isActive = true
    @Environment(\.imageDetailPresenter) private var imagePresenter
    @Environment(\.colorScheme) private var colorScheme
    @State private var items: [ChatAttachmentResponse] = []
    @State private var cursor: MessageID?
    @State private var loaded = false
    @State private var loading = false
    @State private var failed = false
    @State private var locating: String?
    @State private var sourceError = false

    private var title: String {
        switch kind {
        case .image: AppLanguage.localized("Images")
        case .video: AppLanguage.localized("Videos")
        case .other: AppLanguage.localized("Files")
        }
    }

    var body: some View {
        Group {
            if embedded {
                LazyVStack(alignment: .leading, spacing: 12) { rows }
            } else {
                if kind == .other {
                    List { rows }
                        .navigationTitle(title)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) { rows }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                    .navigationTitle(title)
                }
            }
        }
        .task { if isActive && !loaded { await load() } }
        .onChange(of: isActive) { _, active in
            // A section change must not cancel and restart an in-flight page.
            if active && !loaded { Task { await load() } }
        }
        .alert("Couldn’t open source message", isPresented: $sourceError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The message may no longer be accessible. Your attachment list has been kept.")
        }
    }

    @ViewBuilder
    private var rows: some View {
        Text("Attachments from the whole chat, including its threads.")
            .font(.footnote).foregroundStyle(.secondary)
        if kind == .other {
            ForEach(items, id: \.id) { item in
                fileRow(item)
            }
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 3)],
                spacing: 3
            ) {
                ForEach(items, id: \.id) { item in
                    ChatAttachmentMediaTile(
                        item: item, isVideo: kind == .video, isActive: isActive,
                        isLocating: locating != nil,
                        onOpen: { openMedia(item) },
                        onLocate: { Task { await locate(item) } }
                    )
                }
            }
        }
        if loading {
            ProgressView("Loading attachments…")
        } else if failed {
            Button("Couldn’t load attachments. Retry") { Task { await load() } }
        } else if loaded && items.isEmpty {
            Text("No attachments in this section").foregroundStyle(.secondary)
        }
        if loaded && cursor != nil && !loading && !failed {
            Button("Load Older Attachments") { Task { await load() } }
        } else if loaded && cursor == nil && !items.isEmpty {
            Text("All attachments loaded").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func fileRow(_ item: ChatAttachmentResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MessageFileAttachmentView(
                url: URL(string: item.url), fileName: item.fileName,
                contentType: item.kind, byteCount: item.size)
            Text(
                "\(item.sender.name ?? "User \(item.sender.uid)") · \(item.size.formatted(.byteCount(style: .file)))"
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(item.messageCreatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show Message") { Task { await locate(item) } }
                    .font(.caption).disabled(locating != nil)
            }
        }
        .padding(.vertical, embedded ? 12 : 4)
        .padding(.horizontal, embedded ? 16 : 0)
        .background {
            if embedded {
                RoundedRectangle(cornerRadius: 18)
                    .fill(ChahuaTheme.ChatBubble.incomingBackground(for: colorScheme))
            }
        }
    }

    private func load() async {
        guard isActive, !loading, !loaded || cursor != nil else { return }
        loading = true
        failed = false
        defer { loading = false }
        do {
            let page = try await store.chatAttachments(chatID: chatID, kind: kind, before: cursor)
            try Task.checkCancellation()
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.attachments.filter { !known.contains($0.id) })
            cursor = page.olderCursor
            loaded = true
        } catch is CancellationError {
        } catch { failed = true }
    }

    private func openMedia(_ item: ChatAttachmentResponse) {
        // The attachment projection contains everything the existing native viewer needs.
        // Opening it does not require continued access to the source message.
        let media = MessageImageItem(
            id: item.id, url: URL(string: item.url), contentType: item.kind,
            fileName: item.fileName, width: item.width.map(Int.init),
            height: item.height.map(Int.init))
        guard
            let gallery = MessageImageGallery(
                messageID: item.messageId.description, items: [media], selectedID: item.id,
                sentAt: item.messageCreatedAt)
        else { return }
        imagePresenter?.present(gallery)
    }

    private func locate(_ item: ChatAttachmentResponse) async {
        guard locating == nil else { return }
        locating = item.id
        defer { locating = nil }
        do {
            let message = try await store.forwardSourceMessage(
                chatID: chatID, messageID: item.messageId)
            try Task.checkCancellation()
            onOpenMessage(message)
        } catch is CancellationError {
        } catch { sourceError = true }
    }
}

private struct ChatAttachmentMediaTile: View {
    let item: ChatAttachmentResponse
    let isVideo: Bool
    let isActive: Bool
    let isLocating: Bool
    let onOpen: () -> Void
    let onLocate: () -> Void
    @State private var thumbnailFailed = false
    @State private var thumbnailAttempt = 0

    // A stable pixel budget also keeps cache entries reusable across layout changes.
    private let thumbnailPixelSize = CGSize(width: 512, height: 512)

    var body: some View {
        Button(action: onOpen) {
            GeometryReader { geometry in
                ZStack {
                    Color.secondary.opacity(0.12)
                    if isActive {
                        thumbnail
                            .id(thumbnailAttempt)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                    if isVideo {
                        Image(systemName: "play.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.black.opacity(0.55), in: Circle())
                            .frame(
                                maxWidth: .infinity, maxHeight: .infinity,
                                alignment: .bottomTrailing
                            )
                            .padding(8)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Locate Message", systemImage: "text.bubble", action: onLocate)
                .disabled(isLocating)
            if thumbnailFailed {
                Button("Retry Thumbnail", systemImage: "arrow.clockwise") {
                    thumbnailFailed = false
                    thumbnailAttempt += 1
                }
            }
        }
        .accessibilityLabel(
            (isVideo ? Text("Video") : Text("Image")) + Text(verbatim: ": \(item.fileName)")
        )
        .accessibilityValue(
            thumbnailFailed
                ? Text("Thumbnail unavailable")
                : Text(item.messageCreatedAt, style: .date)
        )
        .accessibilityActions {
            Button("Locate Message") {
                if !isLocating { onLocate() }
            }
            if thumbnailFailed {
                Button("Retry Thumbnail") {
                    thumbnailFailed = false
                    thumbnailAttempt += 1
                }
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if URL(string: item.url) == nil {
            thumbnailContent(.failure)
        } else if isVideo {
            ChatAttachmentVideoThumbnail(
                url: URL(string: item.url), pixelSize: thumbnailPixelSize,
                content: thumbnailContent)
        } else {
            CachedImageView(
                url: URL(string: item.url), thumbnailPixelSize: thumbnailPixelSize,
                cancelOnDisappear: true, content: thumbnailContent)
        }
    }

    @ViewBuilder
    private func thumbnailContent(_ phase: RemoteImagePhase) -> some View {
        switch phase {
        case .empty:
            ProgressView()
        case .success(let image):
            image.resizable().scaledToFill()
                .onAppear { thumbnailFailed = false }
        case .failure:
            VStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                Text("Thumbnail unavailable").font(.caption)
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(8)
            .onAppear { thumbnailFailed = true }
        }
    }
}

/// Kingfisher stores the generated JPEG in the account's existing image cache;
/// AVFoundation handles remote extraction without another video download/cache layer.
private struct ChatAttachmentVideoThumbnail<Content: View>: View {
    let url: URL?
    let pixelSize: CGSize
    @ViewBuilder var content: (RemoteImagePhase) -> Content
    @Environment(\.mediaContext) private var mediaContext
    @State private var provider: VideoPoster?

    var body: some View {
        Group {
            if let provider {
                KFImage.dataProvider(provider)
                    .setProcessor(DownsamplingImageProcessor(size: pixelSize))
                    .scaleFactor(1)
                    .targetCache(mediaContext?.cache ?? .default)
                    .cacheOriginalImage()
                    .cancelOnDisappear(true)
                    .placeholder { content(.empty) }
                    .onFailureView { content(.failure) }
                    .contentConfigure { image, isLoaded in
                        if isLoaded { content(.success(image)) }
                    }
            } else if url == nil {
                content(.failure)
            } else {
                content(.empty)
            }
        }
        .task(id: url) {
            guard let url else { return }
            provider = VideoPoster(url: url)
        }
        .onDisappear {
            // Cancel queued starts as well as frame generation already in flight.
            provider?.cancel()
            provider = nil
        }
    }
}
