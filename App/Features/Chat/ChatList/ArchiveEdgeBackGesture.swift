#if os(iOS)
import SwiftUI
import UIKit

/// Keep horizontal row actions separate from iOS 26's full-content back gesture.
/// The native screen-edge recognizer and its delegate remain untouched.
struct ArchiveEdgeBackGesture: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restore()
    }

    final class Controller: UIViewController {
        private weak var contentPopGesture: UIGestureRecognizer?
        private var wasEnabled: Bool?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // Waiting until completion avoids cancelling a content-pop gesture
            // that is returning from a conversation to this archive screen.
            restrictToEdge()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            restore()
        }

        private func restrictToEdge() {
            guard #available(iOS 26, *),
                  let gesture = navigationController?.interactiveContentPopGestureRecognizer else { return }
            if contentPopGesture !== gesture {
                restore()
                contentPopGesture = gesture
                wasEnabled = gesture.isEnabled
            }
            gesture.isEnabled = false
        }

        fileprivate func restore() {
            if let contentPopGesture, let wasEnabled {
                contentPopGesture.isEnabled = wasEnabled
            }
            contentPopGesture = nil
            wasEnabled = nil
        }
    }
}
#endif
