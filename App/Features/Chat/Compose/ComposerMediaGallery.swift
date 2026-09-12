import Combine
import ChahuaAPI
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Local media is intentionally separate from server attachments: an allocated ID is
/// not evidence of a successful upload, and its server thumbnail may not exist yet.
struct LocalOutgoingImagePreview: View {
    let path: String
    var isMeasuring = false
    var contentMode: ContentMode = .fill
    var showsBlurredBackdrop = false
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            if let image {
                let preview = Image(decorative: image, scale: 1)
                preview.resizable().aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if showsBlurredBackdrop {
                            #if os(macOS)
                            // Match RemoteImageView: constrain AppKit's blurred backdrop
                            // explicitly so its fill size cannot expand the foreground.
                            GeometryReader { geometry in
                                ZStack {
                                    Color.black
                                    preview.resizable().aspectRatio(contentMode: .fill)
                                        .frame(width: geometry.size.width + 40, height: geometry.size.height + 40)
                                        .blur(radius: 20).opacity(0.8)
                                    Color.black.opacity(0.2)
                                }
                                .frame(width: geometry.size.width, height: geometry.size.height)
                            }
                            #else
                            ZStack {
                                preview.resizable().aspectRatio(contentMode: .fill)
                                    .blur(radius: 20).scaleEffect(1.1).opacity(0.8)
                                Color.black.opacity(0.2)
                            }
                            #endif
                        }
                    }
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

struct ComposerMediaGallery: View {
    static let slotDragType = UTType(exportedAs: "app.chahua.chat.composer-media-slot")

    let attachments: [LocalOutgoingAttachment]
    let progress: [String: Double]
    let isEnabled: Bool
    let onRemove: (String) -> Void
    let onRetry: (String) -> Void
    let onReorder: ([String]) -> Void
    @StateObject private var drag = ComposerGalleryDragState()

    private var attachmentIDs: [String] { attachments.map(\.id) }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        // An odd selection starts with a full-width preview, followed by pairs.
                        // Unlike timeline galleries, composition must expose every selected item.
                        let leadingCount = attachments.count.isMultiple(of: 2) ? 0 : 1
                        if leadingCount == 1, let first = attachments.first {
                            tile(first, index: 0, viewport: geometry.frame(in: .global))
                                .frame(width: geometry.size.width,
                                       height: attachments.count == 1 ? geometry.size.height :
                                        (attachments.count == 3 ? geometry.size.height * 0.66 : geometry.size.width * 0.66))
                                .id(first.id)
                        }
                        let cellWidth = max(0, (geometry.size.width - 4) / 2)
                        ForEach(0..<((attachments.count - leadingCount) / 2), id: \.self) { row in
                            HStack(spacing: 4) {
                                ForEach(0..<2, id: \.self) { column in
                                    let index = leadingCount + row * 2 + column
                                    tile(attachments[index], index: index, viewport: geometry.frame(in: .global))
                                        .frame(width: cellWidth, height: attachments.count == 2 ? geometry.size.height :
                                            (attachments.count == 3 ? geometry.size.height * 0.34 - 4 : cellWidth))
                                        .id(attachments[index].id)
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: drag.scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scroll.scrollTo(target.id, anchor: target.after ? .bottom : .top)
                    }
                }
            }
        }
        .onAppear { drag.update(ids: attachmentIDs, isEnabled: isEnabled) }
        .onChange(of: attachmentIDs) { _, ids in drag.update(ids: ids, isEnabled: isEnabled) }
        .onChange(of: isEnabled) { _, enabled in drag.update(ids: attachmentIDs, isEnabled: enabled) }
        .onDisappear { drag.update(ids: [], isEnabled: false) }
    }

    private func tile(_ attachment: LocalOutgoingAttachment, index: Int, viewport: CGRect) -> some View {
        GeometryReader { geometry in
            draggableTile(attachment, index: index)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .onDrop(of: [Self.slotDragType], delegate: ComposerGalleryDropDelegate(
                    drag: drag, targetID: attachment.id, size: geometry.size,
                    frame: geometry.frame(in: .global), viewport: viewport,
                    usesVerticalInsertion: index == 0 && !attachments.count.isMultiple(of: 2),
                    onReorder: onReorder
                ))
                .overlay {
                    if let target = drag.target, target.id == attachment.id {
                        let vertical = index == 0 && !attachments.count.isMultiple(of: 2)
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
                            .allowsHitTesting(false)
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: vertical ? nil : 4, height: vertical ? 4 : nil)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: vertical ? (target.after ? .bottom : .top) : (target.after ? .trailing : .leading))
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    @ViewBuilder private func draggableTile(_ attachment: LocalOutgoingAttachment, index: Int) -> some View {
        if isEnabled && attachments.count > 1 {
            tileContent(attachment, index: index)
                .onDrag { drag.provider(for: attachment.id) }
        } else {
            tileContent(attachment, index: index)
        }
    }

    private func tileContent(_ attachment: LocalOutgoingAttachment, index: Int) -> some View {
        LocalOutgoingImagePreview(path: attachment.previewPath, contentMode: .fit)
            .overlay {
                if attachment.mimeType.hasPrefix("video/") {
                    Image(systemName: "play.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(.black.opacity(0.35), in: Circle())
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if attachment.error != nil || progress[attachment.id] != nil {
                    OutgoingImageStatus(attachment: attachment, progress: progress[attachment.id])
                        .padding(8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(8)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Menu {
                    if let error = attachment.error {
                        Text(error)
                        Button("Retry") { onRetry(attachment.id) }
                    }
                    Button("Move earlier") { move(index, by: -1) }.disabled(index == 0)
                    Button("Move later") { move(index, by: 1) }.disabled(index == attachments.count - 1)
                    Button("Remove", role: .destructive) { onRemove(attachment.id) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
                .menuIndicator(.hidden)
                .disabled(!isEnabled)
                .accessibilityLabel("Options for \(attachment.fileName)")
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(attachment.fileName)
    }

    private func move(_ index: Int, by offset: Int) {
        guard isEnabled, attachments.indices.contains(index + offset) else { return }
        var ids = attachments.map(\.id)
        ids.swapAt(index, index + offset)
        onReorder(ids)
    }
}

private struct ComposerGalleryDragPayload: Codable, Equatable {
    let galleryID: UUID
    let sessionID: UUID
    let slotID: String
}

private struct ComposerGalleryDropTarget: Equatable {
    let id: String
    let after: Bool
}

/// Hover only updates presentation. The queue receives one complete order after
/// an accepted, validated local drop; cancellation never mutates attachment state.
@MainActor
private final class ComposerGalleryDragState: ObservableObject {
    @Published var target: ComposerGalleryDropTarget?
    @Published private(set) var scrollTarget: ComposerGalleryDropTarget?
    private let galleryID = UUID()
    private var ids: [String] = []
    private var isEnabled = false
    private var payload: ComposerGalleryDragPayload?
    private var originalIDs: [String] = []
    private var scrollTask: Task<Void, Never>?
    private var scrollDirection = 0

    var canDrop: Bool {
        isEnabled && payload != nil && ids == originalIDs
    }

    func matches(_ providers: [NSItemProvider]) -> Bool {
        canDrop && providers.count == 1
            && providers.first?.hasItemConformingToTypeIdentifier(ComposerMediaGallery.slotDragType.identifier) == true
    }

    func update(ids: [String], isEnabled: Bool) {
        self.ids = ids
        self.isEnabled = isEnabled
        if !canDrop {
            payload = nil
            target = nil
            stopScrolling()
        }
    }

    func provider(for id: String) -> NSItemProvider {
        guard isEnabled, ids.count > 1, ids.contains(id) else { return NSItemProvider() }
        let value = ComposerGalleryDragPayload(galleryID: galleryID, sessionID: UUID(), slotID: id)
        guard let data = try? JSONEncoder().encode(value) else { return NSItemProvider() }
        payload = value
        originalIDs = ids
        target = nil
        stopScrolling()
        let provider = NSItemProvider()
        // No image/file URL representation: caption and chat media importers
        // must never mistake an internal move for a new attachment.
        provider.registerDataRepresentation(
            forTypeIdentifier: ComposerMediaGallery.slotDragType.identifier, visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    func accept(_ provider: NSItemProvider, target: ComposerGalleryDropTarget, onReorder: @escaping ([String]) -> Void) {
        self.target = nil
        stopScrolling()
        provider.loadDataRepresentation(forTypeIdentifier: ComposerMediaGallery.slotDragType.identifier) { data, _ in
            Task { @MainActor in
                guard let data,
                      let value = try? JSONDecoder().decode(ComposerGalleryDragPayload.self, from: data),
                      self.canDrop, value == self.payload, value.galleryID == self.galleryID,
                      self.ids.contains(target.id), self.ids.contains(value.slotID) else { return }
                self.payload = nil
                guard value.slotID != target.id else { return }
                var reordered = self.ids
                reordered.removeAll { $0 == value.slotID }
                guard let destination = reordered.firstIndex(of: target.id) else { return }
                reordered.insert(value.slotID, at: destination + (target.after ? 1 : 0))
                guard reordered != self.ids else { return }
                onReorder(reordered)
            }
        }
    }

    func hover(_ target: ComposerGalleryDropTarget, pointerY: CGFloat, viewport: CGRect) {
        if self.target != target { self.target = target }
        let direction = pointerY < viewport.minY + 36 ? -1 : (pointerY > viewport.maxY - 36 ? 1 : 0)
        guard direction != scrollDirection else { return }
        stopScrolling()
        guard direction != 0, let start = ids.firstIndex(of: target.id) else { return }
        scrollDirection = direction
        // Scroll by slots while hovering at a viewport edge, without reordering
        // anything. Drop callbacks update the insertion target as new tiles enter.
        scrollTask = Task { @MainActor [weak self] in
            var index = start
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(450)) }
                catch { return }
                guard let self, self.canDrop else { return }
                index += direction
                guard self.ids.indices.contains(index) else { return }
                self.scrollTarget = ComposerGalleryDropTarget(id: self.ids[index], after: direction > 0)
            }
        }
    }

    func leave(_ id: String) {
        guard target?.id == id else { return }
        target = nil
        stopScrolling()
    }

    private func stopScrolling() {
        scrollTask?.cancel()
        scrollTask = nil
        scrollDirection = 0
        scrollTarget = nil
    }
}

private struct ComposerGalleryDropDelegate: DropDelegate {
    let drag: ComposerGalleryDragState
    let targetID: String
    let size: CGSize
    let frame: CGRect
    let viewport: CGRect
    let usesVerticalInsertion: Bool
    let onReorder: ([String]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        drag.matches(info.itemProviders(for: [ComposerMediaGallery.slotDragType]))
    }

    func dropEntered(info: DropInfo) {
        if validateDrop(info: info) { hover(info) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        hover(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        drag.leave(targetID)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        let providers = info.itemProviders(for: [ComposerMediaGallery.slotDragType])
        guard providers.count == 1, let provider = providers.first else { return false }
        drag.accept(provider, target: target(for: info), onReorder: onReorder)
        return true
    }

    private func hover(_ info: DropInfo) {
        drag.hover(target(for: info), pointerY: frame.minY + info.location.y, viewport: viewport)
    }

    private func target(for info: DropInfo) -> ComposerGalleryDropTarget {
        ComposerGalleryDropTarget(
            id: targetID,
            after: usesVerticalInsertion ? info.location.y > size.height / 2 : info.location.x > size.width / 2
        )
    }
}
