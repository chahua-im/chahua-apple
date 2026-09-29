import Foundation
import UniformTypeIdentifiers

#if os(iOS)
    import Photos
#elseif os(macOS)
    import AppKit
#endif

@MainActor
enum ImageDetailSave {
    static func save(_ item: MessageImageItem) async throws -> Bool {
        guard item.contentType.lowercased().hasPrefix("image/") else {
            throw ImageDetailSaveError.unavailable
        }

        #if os(iOS)
            let status = await photoLibraryAuthorization()
            guard status == .authorized || status == .limited else {
                throw ImageDetailSaveError.photoLibraryAccessDenied
            }
            try Task.checkCancellation()
            let original = try await ImageDetailOriginal.prepare(from: item)
            defer { original.removeTemporaryFile() }
            try await saveToPhotoLibrary(original)
            return true
        #elseif os(macOS)
            try Task.checkCancellation()
            let original = try await ImageDetailOriginal.prepare(from: item)
            defer { original.removeTemporaryFile() }
            return try await saveWithPanel(original, item: item)
        #else
            throw ImageDetailSaveError.unavailable
        #endif
    }

    #if os(iOS)
        private static func saveToPhotoLibrary(_ original: ImageDetailOriginal) async throws {
            try Task.checkCancellation()
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, fileURL: original.url, options: nil)
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw ImageDetailSaveError.couldNotSave
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
                throw ImageDetailSaveError.couldNotSave
            }
            return true
        }

        private static func suggestedFileName(for item: MessageImageItem, originalURL: URL)
            -> String
        {
            var name = (item.fileName as NSString).lastPathComponent
            if name.isEmpty || name == "." || name == ".." {
                name = "Image"
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
        guard let source = item.url else { throw ImageDetailSaveError.unavailable }
        if source.isFileURL {
            guard FileManager.default.isReadableFile(atPath: source.path) else {
                throw ImageDetailSaveError.unavailable
            }
            return Self(url: source, temporaryDirectory: nil)
        }

        guard ["http", "https"].contains(source.scheme?.lowercased() ?? ""), source.host != nil
        else {
            throw ImageDetailSaveError.unavailable
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chahua-image-save-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let (downloaded, response) = try await URLSession.shared.download(from: source)
            defer { try? FileManager.default.removeItem(at: downloaded) }

            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else {
                throw ImageDetailSaveError.downloadFailed
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
            throw ImageDetailSaveError.downloadFailed
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
        return source.pathExtension.isEmpty ? "image" : source.pathExtension
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
    case unavailable
    case downloadFailed
    case photoLibraryAccessDenied
    case couldNotSave

    var errorDescription: String? {
        switch self {
        case .unavailable:
            AppLanguage.localized("This image is no longer available.")
        case .downloadFailed:
            AppLanguage.localized("The image couldn’t be downloaded. Please try again.")
        case .photoLibraryAccessDenied:
            AppLanguage.localized("Allow Chahua to add photos in Settings before saving images.")
        case .couldNotSave:
            AppLanguage.localized("The image couldn’t be saved. Please try again.")
        }
    }
}
