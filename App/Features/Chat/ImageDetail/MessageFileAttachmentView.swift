import Foundation
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Files share one original-byte download across preview and export. Neither action decodes media.
struct MessageFileAttachmentView: View {
    let url: URL?
    let fileName: String
    let contentType: String
    var byteCount: Int64? = nil

    @State private var original: URL?
    @State private var preview: URL?
    @State private var export: URL?
    @State private var directory: URL?
    @State private var operation: Task<Void, Never>?
    @State private var isDownloading = false
    @State private var error: String?

    private var safeName: String {
        let name = (fileName as NSString).lastPathComponent
        return name.isEmpty || name == "." || name == ".." ? "Attachment" : name
    }
    private var typeLabel: String {
        UTType(mimeType: contentType)?.localizedDescription ?? contentType
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(safeName).font(.callout.weight(.medium)).lineLimit(2)
                    Text(typeLabel).font(.caption).foregroundStyle(.secondary)
                    if let byteCount {
                        Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if isDownloading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Downloading…").font(.caption)
                    Button("Cancel") { cancel() }
                }
            } else {
                HStack {
                    Button("Open", systemImage: "doc.text.magnifyingglass") {
                        prepare(exporting: false)
                    }
                    Button("Save File", systemImage: "square.and.arrow.down") {
                        prepare(exporting: true)
                    }
                }
                .font(.callout)
                .disabled(url == nil)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .quickLookPreview($preview)
        .modifier(MessageFileExportPresentation(url: $export, onError: { error = $0 }))
        .onDisappear {
            cancel()
            if let directory { try? FileManager.default.removeItem(at: directory) }
            directory = nil
            original = nil
        }
    }

    private func cancel() {
        operation?.cancel()
    }

    private func prepare(exporting: Bool) {
        guard operation == nil, let url else { return }
        error = nil
        if let original {
            if exporting { export = original } else { preview = original }
            return
        }
        isDownloading = true
        operation = Task {
            defer {
                operation = nil
                isDownloading = false
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
                "chahua-file-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true)
                let destination = folder.appendingPathComponent(safeName)
                if url.isFileURL {
                    let copy = Task.detached(priority: .utility) {
                        try Task.checkCancellation()
                        try FileManager.default.copyItem(at: url, to: destination)
                        try Task.checkCancellation()
                    }
                    try await withTaskCancellationHandler {
                        try await copy.value
                    } onCancel: {
                        copy.cancel()
                    }
                } else {
                    guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                        url.host != nil
                    else {
                        throw URLError(.badURL)
                    }
                    let (downloaded, response) = try await URLSession.shared.download(from: url)
                    defer { try? FileManager.default.removeItem(at: downloaded) }
                    guard let response = response as? HTTPURLResponse,
                        (200..<300).contains(response.statusCode)
                    else { throw URLError(.badServerResponse) }
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: downloaded, to: destination)
                }
                try Task.checkCancellation()
                directory = folder
                original = destination
                if exporting { export = destination } else { preview = destination }
            } catch {
                try? FileManager.default.removeItem(at: folder)
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
