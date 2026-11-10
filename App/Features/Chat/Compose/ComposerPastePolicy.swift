import Foundation
import UniformTypeIdentifiers

/// Representation selection shared by native paste, drop and attachment acquisition.
/// Keep classification here; platform adapters handle insertion and acquisition owns file lifetimes.
/// Original files and explicit media/document formats take precedence over text.
/// Other binary data is an attachment only when no native text/URL representation exists.
enum ComposerPastePolicy {
    static func supports(_ provider: NSItemProvider) -> Bool {
        attachmentTypeIdentifier(for: provider) != nil
    }

    static func attachmentTypeIdentifier(for provider: NSItemProvider) -> String? {
        // A copied file may also offer text and image previews. Import the original file first.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return UTType.fileURL.identifier
        }
        return attachmentDataTypeIdentifier(in: provider.registeredTypeIdentifiers)
    }

    nonisolated static func attachmentDataTypeIdentifier(
        in identifiers: some Sequence<String>
    ) -> String? {
        var fallback: String?
        var hasNativeText = false
        for identifier in identifiers {
            guard let type = UTType(identifier) else { continue }
            if type.conforms(to: .text) || type.conforms(to: .url) {
                hasNativeText = true
                continue
            }
            guard type.conforms(to: .data) else { continue }
            // Media and explicit document formats can carry a textual fallback.
            if type.conforms(to: .image) || type.conforms(to: .audiovisualContent)
                || type.conforms(to: .pdf) || type.conforms(to: .archive)
            {
                return identifier
            }
            if fallback == nil { fallback = identifier }
        }
        // Safari adds non-text data such as a URL title or web archive. That
        // metadata must not turn a native URL/text paste into a file attachment.
        return hasNativeText ? nil : fallback
    }

    static func isFile(_ provider: NSItemProvider, materializedURL: URL) -> Bool {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let type = UTType(filenameExtension: materializedURL.pathExtension)
            return type?.conforms(to: .image) != true && type?.conforms(to: .movie) != true
        }
        return !provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            && !provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
    }
}
