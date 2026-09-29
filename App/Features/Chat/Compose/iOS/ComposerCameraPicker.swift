#if os(iOS)
    import SwiftUI
    import UIKit

    /// iOS-only camera capture: SwiftUI has no camera source picker, so UIKit is required
    /// to take a new photo. macOS retains its supported Photos and Files acquisition controls.
    struct ComposerCameraPicker: UIViewControllerRepresentable {
        let onCapture: (URL) -> Void
        let onCancel: () -> Void
        let onError: (Error) -> Void

        func makeUIViewController(context: Context) -> UIImagePickerController {
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.cameraCaptureMode = .photo
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

        func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

        final class Coordinator: NSObject, UINavigationControllerDelegate,
            UIImagePickerControllerDelegate
        {
            private let parent: ComposerCameraPicker

            init(parent: ComposerCameraPicker) {
                self.parent = parent
            }

            func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
                parent.onCancel()
            }

            func imagePickerController(
                _ picker: UIImagePickerController,
                didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
            ) {
                do {
                    guard let image = info[.originalImage] as? UIImage else {
                        throw ComposerCameraPickerError.unavailable
                    }
                    parent.onCapture(try ComposerImageAcquisition.writeCapturedPhoto(image))
                } catch {
                    parent.onError(error)
                }
            }
        }

        private enum ComposerCameraPickerError: LocalizedError {
            case unavailable

            var errorDescription: String? {
                "The captured photo couldn’t be read. Please try again."
            }
        }
    }
#endif
