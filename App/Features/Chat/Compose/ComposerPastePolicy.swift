import Foundation
import UniformTypeIdentifiers

/// Representation selection shared by native paste, drop and attachment acquisition.
/// Keep classification here; platform adapters handle insertion and acquisition owns file lifetimes.
enum ComposerPastePolicy {
    static func supports(_ provider: NSItemProvider) -> Bool {
        attachmentTypeIdentifier(for: provider) != nil
    }

    static func attachmentTypeIdentifier(for provider: NSItemProvider) -> String? {
        // A copied file may also offer text and image previews. Import the original file first.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return UTType.fileURL.identifier
        }
        return provider.registeredTypeIdentifiers.first(where: isAttachmentDataType)
    }

    nonisolated static func isAttachmentDataType(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else { return false }
        return type.conforms(to: .data) && !type.conforms(to: .text)
            && !type.conforms(to: .url)
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
