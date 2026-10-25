import ChahuaAPI
import Foundation
import UniformTypeIdentifiers

/// Explicit Files never passes through image codecs, even when its MIME type is an image.
nonisolated struct OutgoingFileImporter: Sendable {
    let directory: URL

    func importFile(from url: URL, position: Int) async throws -> LocalOutgoingAttachment {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .contentTypeKey,
            ])
            guard url.isFileURL, values.isRegularFile == true, let size = values.fileSize, size > 0
            else {
                throw LocalStorageError.invalidAttachments
            }
            let root = try OutgoingImageFiles.root(directory)
            let outbox = root.appendingPathComponent("Outbox", isDirectory: true)
            try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
            try OutgoingImageFiles.checkOutbox(outbox, root: root)
            let id = UUID().uuidString
            let staging = outbox.appendingPathComponent(".\(id).import", isDirectory: true)
            let installed = outbox.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: staging) }
            let source = staging.appendingPathComponent("source")
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            guard FileManager.default.createFile(atPath: source.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let output = try FileHandle(forWritingTo: source)
            defer { try? output.close() }
            var byteCount: Int64 = 0
            while true {
                try Task.checkCancellation()
                guard let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty else {
                    break
                }
                try output.write(contentsOf: bytes)
                byteCount += Int64(bytes.count)
            }
            try output.synchronize()
            try Task.checkCancellation()
            guard byteCount > 0 else { throw LocalStorageError.invalidAttachments }
            try FileManager.default.moveItem(at: staging, to: installed)
            let path = installed.appendingPathComponent("source").path
            let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
            return LocalOutgoingAttachment(
                id: id, generation: UUID().uuidString, position: position,
                sourcePath: path, preparedPath: path, previewPath: path,
                fileName: url.lastPathComponent,
                mimeType: type?.preferredMIMEType ?? "application/octet-stream",
                width: 0, height: 0, byteCount: byteCount, preservesOriginal: true)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
