import AVFoundation
import ChahuaAPI
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum OutgoingImageError: LocalizedError {
    case outsideAccountDirectory
    case unsupportedImage
    case invalidImage
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .outsideAccountDirectory: "The attachment file is outside this account’s outbox."
        case .unsupportedImage: "This file is not a supported photo or video."
        case .invalidImage: "The photo or video could not be read."
        case .encodingFailed: "The photo or video could not be prepared."
        }
    }
}

/// Native codecs and file access run only in cancellable detached work, never on the UI executor.
nonisolated struct OutgoingImageProcessor: Sendable {
    let directory: URL

    func importImage(from url: URL, directory: URL, position: Int) async throws -> LocalOutgoingAttachment {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let root = try OutgoingImageFiles.root(self.directory)
            guard try OutgoingImageFiles.root(directory) == root else {
                throw OutgoingImageError.outsideAccountDirectory
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard url.isFileURL else { throw OutgoingImageError.unsupportedImage }
            let inputValues = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard inputValues.isRegularFile == true else { throw OutgoingImageError.unsupportedImage }
            let manager = FileManager.default
            let outbox = root.appendingPathComponent("Outbox", isDirectory: true)
            try manager.createDirectory(at: outbox, withIntermediateDirectories: true)
            try OutgoingImageFiles.checkOutbox(outbox, root: root)
            let id = UUID().uuidString
            let staging = outbox.appendingPathComponent(".\(id).import", isDirectory: true)
            let installed = outbox.appendingPathComponent(id, isDirectory: true)
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? manager.removeItem(at: staging) }
            var copied = staging.appendingPathComponent("source")
            try Self.copy(from: url, to: copied)
            // AVFoundation needs a container extension even when the bytes are valid.
            // Provider names are untrusted, so normalize from the file header first.
            let metadata: Metadata
            if let image = try? autoreleasepool(invoking: { try Self.imageMetadata(copied) }) {
                metadata = image
            } else {
                let type = try Self.videoType(copied)
                guard let extensionName = type.preferredFilenameExtension else {
                    throw OutgoingImageError.unsupportedImage
                }
                let video = staging.appendingPathComponent("source.\(extensionName)")
                try manager.moveItem(at: copied, to: video)
                copied = video
                metadata = try await Self.metadata(copied)
            }
            let image = try await Self.preview(metadata, maximum: 480)
            let sourceName = "source.\(metadata.extensionName)"
            let source = staging.appendingPathComponent(sourceName)
            if copied != source { try manager.moveItem(at: copied, to: source) }
            let previewType: UTType = Self.hasAlpha(image) ? .png : .jpeg
            let previewName = "preview.\(previewType.preferredFilenameExtension!)"
            try autoreleasepool {
                try Self.encode(image, type: previewType, to: staging.appendingPathComponent(previewName))
            }
            try Task.checkCancellation()
            try manager.moveItem(at: staging, to: installed)
            // The complete directory becomes visible at once; no row can reference partial files.
            return LocalOutgoingAttachment(
                id: id, generation: UUID().uuidString, position: position,
                sourcePath: installed.appendingPathComponent(sourceName).path,
                previewPath: installed.appendingPathComponent(previewName).path,
                fileName: Self.fileName(url.deletingPathExtension().lastPathComponent, extensionName: metadata.extensionName),
                mimeType: metadata.mimeType, width: metadata.width, height: metadata.height,
                byteCount: metadata.byteCount
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    func prepare(_ attachment: LocalOutgoingAttachment, compressionEnabled: Bool) async throws -> LocalOutgoingAttachment {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let source = try OutgoingImageFiles.file(URL(fileURLWithPath: attachment.sourcePath), directory: directory)
            let preview = try OutgoingImageFiles.file(URL(fileURLWithPath: attachment.previewPath), directory: directory)
            guard source.deletingLastPathComponent() == preview.deletingLastPathComponent() else {
                throw OutgoingImageError.outsideAccountDirectory
            }
            if let preparedPath = attachment.preparedPath {
                let prepared = try OutgoingImageFiles.file(URL(fileURLWithPath: preparedPath), directory: directory)
                guard prepared.deletingLastPathComponent() == source.deletingLastPathComponent() else {
                    throw OutgoingImageError.outsideAccountDirectory
                }
            }
            let metadata = try await Self.metadata(source)
            var result = attachment
            result.preparedPath = source.path
            result.fileName = Self.fileName(
                URL(fileURLWithPath: attachment.fileName).deletingPathExtension().lastPathComponent,
                extensionName: metadata.extensionName
            )
            result.mimeType = metadata.mimeType
            result.width = metadata.width
            result.height = metadata.height
            result.byteCount = metadata.byteCount
            result.attachmentID = nil
            result.error = nil
            try Task.checkCancellation()
            guard compressionEnabled else { return result }
            switch metadata.content {
            case .video:
                // Videos retain their original bytes regardless of the image compression setting.
                return result
            case .image(let imageSource):
                return try autoreleasepool {
                    try Self.prepareImage(result, source: imageSource)
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func prepareImage(_ attachment: LocalOutgoingAttachment, source: CGImageSource) throws -> LocalOutgoingAttachment {
        // Preserve every frame and its timing by sending animated/multi-image originals unchanged.
        guard CGImageSourceGetCount(source) == 1 else { return attachment }
        let image = try thumbnail(source, maximum: 1920)
        let type: UTType = hasAlpha(image) ? .png : .jpeg
        let name = UUID().uuidString
        let folder = URL(fileURLWithPath: attachment.sourcePath).deletingLastPathComponent()
        let staging = folder.appendingPathComponent(".\(name).partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        try encode(image, type: type, to: staging)
        let bytes = try fileSize(staging)
        try Task.checkCancellation()
        // The original remains authoritative unless the complete result saves at least 25%.
        guard Double(bytes) < Double(attachment.byteCount) * 0.75 else { return attachment }
        let output = folder.appendingPathComponent("prepared.\(name).\(type.preferredFilenameExtension!)")
        try FileManager.default.moveItem(at: staging, to: output)
        var result = attachment
        result.preparedPath = output.path
        result.fileName = fileName(
            URL(fileURLWithPath: attachment.fileName).deletingPathExtension().lastPathComponent,
            extensionName: type.preferredFilenameExtension!
        )
        result.mimeType = type.preferredMIMEType!
        result.width = image.width
        result.height = image.height
        result.byteCount = bytes
        return result
    }

    private struct Metadata {
        enum Content {
            case image(CGImageSource)
            case video(AVURLAsset)
        }
        let content: Content
        let mimeType: String
        let extensionName: String
        let width: Int
        let height: Int
        let byteCount: Int64
    }

    private static func imageMetadata(_ url: URL) throws -> Metadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) > 0,
            let identifier = CGImageSourceGetType(source),
            let type = UTType(identifier as String), type.conforms(to: .image),
            let mime = type.preferredMIMEType, let extensionName = type.preferredFilenameExtension,
            let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (values[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (values[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0, height > 0
        else { throw OutgoingImageError.unsupportedImage }
        let orientation = (values[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapped = (5...8).contains(orientation)
        return Metadata(
            content: .image(source), mimeType: mime, extensionName: extensionName,
            width: swapped ? height : width, height: swapped ? width : height,
            byteCount: try fileSize(url)
        )
    }

    private static func metadata(_ url: URL) async throws -> Metadata {
        try Task.checkCancellation()
        if let image = try? autoreleasepool(invoking: { try imageMetadata(url) }) { return image }
        let type = try videoType(url)
        guard let mimeType = type.preferredMIMEType, let extensionName = type.preferredFilenameExtension else {
            throw OutgoingImageError.unsupportedImage
        }
        let asset = AVURLAsset(url: url)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let playable = try await asset.load(.isPlayable)
            let duration = try await asset.load(.duration).seconds
            guard playable, duration.isFinite, duration > 0,
                let track = try await asset.loadTracks(withMediaType: .video).first
            else { throw OutgoingImageError.invalidImage }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
            guard bounds.width.isFinite, bounds.height.isFinite,
                bounds.width >= 1, bounds.height >= 1,
                bounds.width < CGFloat(Int32.max), bounds.height < CGFloat(Int32.max)
            else { throw OutgoingImageError.invalidImage }
            try Task.checkCancellation()
            return Metadata(
                content: .video(asset), mimeType: mimeType, extensionName: extensionName,
                width: Int(bounds.width.rounded()), height: Int(bounds.height.rounded()), byteCount: try fileSize(url)
            )
        } onCancel: {
            asset.cancelLoading()
        }
    }

    private static func videoType(_ url: URL) throws -> UTType {
        // Provider filenames can be absent or wrong. Identify the container from bytes, then
        // require AVFoundation to validate playable video tracks before accepting the file.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 16) ?? Data()
        guard header.count >= 12 else { throw OutgoingImageError.unsupportedImage }
        let box = String(decoding: header[4..<8], as: UTF8.self)
        if box == "ftyp" {
            let brand = String(decoding: header[8..<12], as: UTF8.self)
            if brand == "qt  " { return .quickTimeMovie }
            if brand.hasPrefix("3g2"), let type = UTType("public.3gpp2") { return type }
            if brand.hasPrefix("3g"), let type = UTType("public.3gpp") { return type }
            return .mpeg4Movie
        }
        if ["moov", "mdat", "wide", "free", "skip"].contains(box) { return .quickTimeMovie }
        if header.starts(with: [0x52, 0x49, 0x46, 0x46]),
            String(decoding: header[8..<12], as: UTF8.self) == "AVI " {
            return .avi
        }
        if header.starts(with: [0, 0, 1, 0xBA]) || header.starts(with: [0, 0, 1, 0xB3]) { return .mpeg }
        throw OutgoingImageError.unsupportedImage
    }

    private static func preview(_ metadata: Metadata, maximum: Int) async throws -> CGImage {
        try Task.checkCancellation()
        switch metadata.content {
        case .image(let source):
            return try autoreleasepool { try thumbnail(source, maximum: maximum) }
        case .video(let asset):
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maximum, height: maximum)
            let image = try await withTaskCancellationHandler {
                try await generator.image(at: .zero).image
            } onCancel: {
                generator.cancelAllCGImageGeneration()
            }
            try Task.checkCancellation()
            return image
        }
    }

    private static func thumbnail(_ source: CGImageSource, maximum: Int) throws -> CGImage {
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { throw OutgoingImageError.invalidImage }
        try Task.checkCancellation()
        return image
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: true
        default: false
        }
    }

    private static func encode(_ image: CGImage, type: UTType, to url: URL) throws {
        try Task.checkCancellation()
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw OutgoingImageError.encodingFailed
        }
        // Thumbnail transforms have already baked EXIF orientation into the pixels.
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.82,
            kCGImagePropertyOrientation: 1,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw OutgoingImageError.encodingFailed }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        try Task.checkCancellation()
    }

    private static func copy(from source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        while true {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: 1_048_576), !data.isEmpty else { break }
            try output.write(contentsOf: data)
        }
        try output.synchronize()
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0 else { throw OutgoingImageError.invalidImage }
        return Int64(size)
    }

    private static func fileName(_ stem: String, extensionName: String) -> String {
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(String((trimmed.isEmpty ? "attachment" : trimmed).prefix(200))).\(extensionName)"
    }
}

/// Shared file boundary for processors and uploads. Persisted paths are never trusted directly.
nonisolated enum OutgoingImageFiles {
    static func root(_ directory: URL) throws -> URL {
        guard directory.isFileURL else { throw OutgoingImageError.outsideAccountDirectory }
        return directory.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func checkOutbox(_ outbox: URL, root: URL) throws {
        guard outbox.standardizedFileURL == root.appendingPathComponent("Outbox", isDirectory: true),
            outbox.resolvingSymlinksInPath() == outbox.standardizedFileURL
        else { throw OutgoingImageError.outsideAccountDirectory }
    }

    static func file(_ url: URL, directory: URL) throws -> URL {
        let root = try root(directory)
        let outbox = root.appendingPathComponent("Outbox", isDirectory: true)
        try checkOutbox(outbox, root: root)
        let path = url.standardizedFileURL
        let components = path.pathComponents
        guard url.isFileURL, components.count == outbox.pathComponents.count + 2,
            Array(components.prefix(outbox.pathComponents.count)) == outbox.pathComponents,
            UUID(uuidString: path.deletingLastPathComponent().lastPathComponent) != nil,
            path.resolvingSymlinksInPath() == path
        else { throw OutgoingImageError.outsideAccountDirectory }
        let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw OutgoingImageError.outsideAccountDirectory
        }
        return path
    }
}
