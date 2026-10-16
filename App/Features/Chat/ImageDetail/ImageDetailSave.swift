import Foundation
import UniformTypeIdentifiers

#if os(iOS)
    import Photos
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

/// Saves a viewer item's original bytes: to Photos on iOS, through a Save panel on macOS.
@MainActor
enum ImageDetailSave {
    static func save(_ item: MessageImageItem) async throws -> Bool {
        guard item.isImage || item.isVideo else {
            throw ImageDetailSaveError.unavailable(isVideo: false)
        }

        #if os(iOS)
            let status = await photoLibraryAuthorization()
            guard status == .authorized || status == .limited else {
                throw ImageDetailSaveError.photoLibraryAccessDenied
            }
            try Task.checkCancellation()
            let original = try await ImageDetailOriginal.prepare(from: item)
            defer { original.removeTemporaryFile() }
            try await saveToPhotoLibrary(original, isVideo: item.isVideo)
            return true
        #elseif os(macOS)
            try Task.checkCancellation()
            let original = try await ImageDetailOriginal.prepare(from: item)
            defer { original.removeTemporaryFile() }
            return try await saveWithPanel(original, item: item)
        #else
            throw ImageDetailSaveError.unavailable(isVideo: item.isVideo)
        #endif
    }

    #if os(iOS)
        private static func saveToPhotoLibrary(_ original: ImageDetailOriginal, isVideo: Bool)
            async throws
        {
            try Task.checkCancellation()
            // Photos accepts only formats Apple platforms can play (e.g. MP4/MOV with
            // H.264/HEVC); report WebM/MKV distinctly instead of a generic failure.
            if isVideo, !UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(original.url.path) {
                throw ImageDetailSaveError.videoFormatUnsupported
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(
                        with: isVideo ? .video : .photo, fileURL: original.url, options: nil)
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw ImageDetailSaveError.couldNotSave(isVideo: isVideo)
            }
        }

        private static func photoLibraryAuthorization() async -> PHAuthorizationStatus {
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            guard status == .notDetermined else { return status }
            return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
    #elseif os(macOS)
        private static func saveWithPanel(_ original: ImageDetailOriginal, item: MessageImageItem)
            async throws
            -> Bool
        {
            // NSSavePanel supplies the user-selected write scope while preserving the original file bytes.
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedFileName(for: item, originalURL: original.url)
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            if let type = suggestedContentType(for: item, originalURL: original.url) {
                panel.allowedContentTypes = [type]
            }

            let response = await withTaskCancellationHandler(
                operation: { await panel.begin() },
                onCancel: {
                    Task { @MainActor in panel.cancel(nil) }
                })
            guard !Task.isCancelled else { throw CancellationError() }
            guard response == .OK, let destination = panel.url else { return false }

            let isAccessingDestination = destination.startAccessingSecurityScopedResource()
            defer {
                if isAccessingDestination {
                    destination.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let sourceSnapshot = original.url
                let destinationSnapshot = destination
                let copy = Task.detached(priority: .userInitiated) {
                    try ImageDetailFileCopy.replace(
                        source: sourceSnapshot, destination: destinationSnapshot)
                }
                try await withTaskCancellationHandler(
                    operation: { try await copy.value },
                    onCancel: { copy.cancel() })
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw ImageDetailSaveError.couldNotSave(isVideo: item.isVideo)
            }
            return true
        }

        private static func suggestedFileName(for item: MessageImageItem, originalURL: URL)
            -> String
        {
            var name = (item.fileName as NSString).lastPathComponent
            if name.isEmpty || name == "." || name == ".." {
                name = item.isVideo ? "Video" : "Image"
            }
            if (name as NSString).pathExtension.isEmpty, !originalURL.pathExtension.isEmpty {
                name += ".\(originalURL.pathExtension)"
            }
            return name
        }

        private static func suggestedContentType(for item: MessageImageItem, originalURL: URL)
            -> UTType?
        {
            UTType(mimeType: item.contentType)
                ?? UTType(filenameExtension: (item.fileName as NSString).pathExtension)
                ?? UTType(filenameExtension: originalURL.pathExtension)
        }
    #endif
}

private struct ImageDetailOriginal {
    let url: URL
    private let temporaryDirectory: URL?

    static func prepare(from item: MessageImageItem) async throws -> Self {
        guard let source = item.url else {
            throw ImageDetailSaveError.unavailable(isVideo: item.isVideo)
        }
        if source.isFileURL {
            guard FileManager.default.isReadableFile(atPath: source.path) else {
                throw ImageDetailSaveError.unavailable(isVideo: item.isVideo)
            }
            return Self(url: source, temporaryDirectory: nil)
        }

        guard ["http", "https"].contains(source.scheme?.lowercased() ?? ""), source.host != nil
        else {
            throw ImageDetailSaveError.unavailable(isVideo: item.isVideo)
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chahua-media-save-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let (downloaded, response) = try await URLSession.shared.download(from: source)
            defer { try? FileManager.default.removeItem(at: downloaded) }

            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else {
                throw ImageDetailSaveError.downloadFailed(isVideo: item.isVideo)
            }

            let original = directory.appendingPathComponent("original").appendingPathExtension(
                suggestedExtension(for: item, source: source))
            try FileManager.default.moveItem(at: downloaded, to: original)
            return Self(url: original, temporaryDirectory: directory)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: directory)
            throw CancellationError()
        } catch let error as ImageDetailSaveError {
            try? FileManager.default.removeItem(at: directory)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if Task.isCancelled { throw CancellationError() }
            throw ImageDetailSaveError.downloadFailed(isVideo: item.isVideo)
        }
    }

    func removeTemporaryFile() {
        guard let temporaryDirectory else { return }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private static func suggestedExtension(for item: MessageImageItem, source: URL) -> String {
        if let fileExtension = UTType(mimeType: item.contentType)?.preferredFilenameExtension {
            return fileExtension
        }
        let fileNameExtension = (item.fileName as NSString).pathExtension
        if !fileNameExtension.isEmpty { return fileNameExtension }
        return source.pathExtension.isEmpty
            ? (item.isVideo ? "mp4" : "image") : source.pathExtension
    }
}

nonisolated private enum ImageDetailFileCopy {
    static func replace(source: URL, destination: URL) throws {
        try Task.checkCancellation()

        let fileManager = FileManager.default
        let replacementDirectory = try fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination,
            create: true)
        defer { try? fileManager.removeItem(at: replacementDirectory) }

        let replacement = replacementDirectory.appendingPathComponent(destination.lastPathComponent)
        try fileManager.copyItem(at: source, to: replacement)
        try Task.checkCancellation()

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination, withItemAt: replacement, backupItemName: nil)
        } else {
            try fileManager.moveItem(at: replacement, to: destination)
        }
    }
}

private enum ImageDetailSaveError: LocalizedError {
    case unavailable(isVideo: Bool)
    case downloadFailed(isVideo: Bool)
    case photoLibraryAccessDenied
    case videoFormatUnsupported
    case couldNotSave(isVideo: Bool)

    var errorDescription: String? {
        switch self {
        case .unavailable(let isVideo):
            isVideo
                ? AppLanguage.localized("This video is no longer available.")
                : AppLanguage.localized("This image is no longer available.")
        case .downloadFailed(let isVideo):
            isVideo
                ? AppLanguage.localized("The video couldn’t be downloaded. Please try again.")
                : AppLanguage.localized("The image couldn’t be downloaded. Please try again.")
        case .photoLibraryAccessDenied:
            AppLanguage.localized("Allow Chahua to add photos in Settings before saving media.")
        case .videoFormatUnsupported:
            AppLanguage.localized("Photos doesn’t support this video format.")
        case .couldNotSave(let isVideo):
            isVideo
                ? AppLanguage.localized("The video couldn’t be saved. Please try again.")
                : AppLanguage.localized("The image couldn’t be saved. Please try again.")
        }
    }
}
