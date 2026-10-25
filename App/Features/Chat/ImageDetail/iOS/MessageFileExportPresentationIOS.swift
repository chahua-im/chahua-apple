#if os(iOS)
    import SwiftUI
    import UIKit

    struct MessageFileExportPresentation: ViewModifier {
        @Binding var url: URL?
        let onError: (String) -> Void

        func body(content: Content) -> some View {
            content.sheet(isPresented: Binding(get: { url != nil }, set: { if !$0 { url = nil } }))
            {
                if let url { MessageFileDocumentExporter(url: url) }
            }
        }
    }

    // SwiftUI fileExporter requires a FileDocument snapshot; the native document picker exports
    // a file URL directly, preserving arbitrary large files without a second in-memory byte copy.
    private struct MessageFileDocumentExporter: UIViewControllerRepresentable {
        let url: URL
        @Environment(\.dismiss) private var dismiss

        func makeCoordinator() -> Coordinator { Coordinator(onDismiss: { dismiss() }) }
        func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            picker.delegate = context.coordinator
            return picker
        }
        func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context)
        {}

        final class Coordinator: NSObject, UIDocumentPickerDelegate {
            let onDismiss: () -> Void
            init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }
            func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
                onDismiss()
            }
            func documentPicker(
                _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
            ) {
                onDismiss()
            }
        }
    }
#endif
