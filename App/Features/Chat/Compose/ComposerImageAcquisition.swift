import Combine
import CoreTransferable
import Foundation
import PhotosUI
import UniformTypeIdentifiers

/// One acquisition transaction is shared by the pane, inline composer and caption sheet.
@MainActor
final class ComposerAttachmentState: ObservableObject {
    struct DropRequest {
        let id = UUID()
        let providers: [NSItemProvider]
    }

    @Published var isAcquiring = false
    @Published var error: String?
    @Published private(set) var dropRequest: DropRequest?

    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isAcquiring, dropRequest == nil, !providers.isEmpty else { return false }
        dropRequest = DropRequest(providers: providers)
        return true
    }

    func takeDrop() -> [NSItemProvider]? {
        defer { dropRequest = nil }
        return dropRequest?.providers
    }
}

/// Picker/provider URLs expire when their callback returns. Materialize a private temporary
/// copy here; the outbox imports it durably before the caller removes this copy.
struct ComposerImportedImage: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            Self(url: try ComposerImageAcquisition.copyTemporary(received.file))
        }
        FileRepresentation(importedContentType: .movie) { received in
            Self(url: try ComposerImageAcquisition.copyTemporary(received.file))
        }
    }
}

enum ComposerImageAcquisition {
    nonisolated static func copyTemporary(_ url: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("composer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    nonisolated static func removeTemporary(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    static func materialize(_ provider: NSItemProvider) async throws -> URL {
        try Task.checkCancellation()
        if let type = provider.registeredTypeIdentifiers.first(where: {
            guard let type = UTType($0) else { return false }
            return type.conforms(to: .image) || type.conforms(to: .movie)
        }) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    do {
                        guard let url else { throw error ?? AcquisitionError.unavailable }
                        continuation.resume(returning: try copyTemporary(url))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                do {
                    let url: URL?
                    if let value = item as? URL { url = value }
                    else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else { url = nil }
                    guard let url else { throw error ?? AcquisitionError.unavailable }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    continuation.resume(returning: try copyTemporary(url))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    enum AcquisitionError: LocalizedError {
        case unavailable
        var errorDescription: String? { "This photo or video couldn’t be read. Try choosing it from Files or Photos again." }
    }
}
