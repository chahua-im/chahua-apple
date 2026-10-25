#if os(macOS)
    import AppKit
    import SwiftUI

    struct MessageFileExportPresentation: ViewModifier {
        @Binding var url: URL?
        let onError: (String) -> Void

        func body(content: Content) -> some View {
            content.task(id: url) {
                guard let source = url else { return }
                defer { url = nil }
                // A native Save panel grants the write scope and copies from disk, unlike a
                // SwiftUI FileDocument snapshot which would materialize the whole attachment.
                let panel = NSSavePanel()
                panel.nameFieldStringValue = source.lastPathComponent
                panel.canCreateDirectories = true
                panel.isExtensionHidden = false
                let response = await withTaskCancellationHandler {
                    await panel.begin()
                } onCancel: {
                    Task { @MainActor in panel.cancel(nil) }
                }
                guard !Task.isCancelled, response == .OK, let destination = panel.url else {
                    return
                }
                let scoped = destination.startAccessingSecurityScopedResource()
                defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
                do {
                    let copy = Task.detached(priority: .utility) {
                        try Task.checkCancellation()
                        let manager = FileManager.default
                        let staging = try manager.url(
                            for: .itemReplacementDirectory, in: .userDomainMask,
                            appropriateFor: destination, create: true)
                        defer { try? manager.removeItem(at: staging) }
                        let replacement = staging.appendingPathComponent(
                            destination.lastPathComponent)
                        try manager.copyItem(at: source, to: replacement)
                        try Task.checkCancellation()
                        if manager.fileExists(atPath: destination.path) {
                            _ = try manager.replaceItemAt(destination, withItemAt: replacement)
                        } else {
                            try manager.moveItem(at: replacement, to: destination)
                        }
                    }
                    try await withTaskCancellationHandler {
                        try await copy.value
                    } onCancel: {
                        copy.cancel()
                    }
                } catch {
                    if !Task.isCancelled { onError(error.localizedDescription) }
                }
            }
        }
    }
#endif
