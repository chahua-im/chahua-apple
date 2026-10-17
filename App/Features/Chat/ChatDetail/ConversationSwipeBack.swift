#if os(iOS)
    import SwiftUI
    import UIKit
    import os

    /// Restores swipe-back on iPhone conversation screens, which hide the system
    /// navigation bar to draw the app header (back button with an unread pill,
    /// like Messages and Telegram).
    ///
    /// Requirement: edge and full-screen swipe-back must keep working with the bar hidden.
    /// SwiftUI limitation: hiding the bar leaves UIKit's pop recognizers enabled, but their
    /// UIKit delegate stops accepting touches, and SwiftUI has no API to change that.
    /// Native approach: while the screen is visible, replace that delegate outright on
    /// both the edge and (iOS 26) full-screen pop recognizers with one that only requires
    /// a screen to go back to; restore UIKit's delegate when the screen disappears.
    /// Forwarding any call to UIKit's delegate brings back its refusal, so none is forwarded.
    /// UIKit still drives the interactive transition, so tracking, cancel, and completion
    /// behave natively.
    ///
    /// UIKit resets the recognizers' delegate when the screen's bar configuration changes
    /// after it appears (e.g. a DM title or a thread's parent chat loading), so the delegate
    /// is re-asserted on every SwiftUI update and layout pass while the screen is visible.
    struct ConversationSwipeBack: UIViewControllerRepresentable {
        func makeUIViewController(context: Context) -> Controller { Controller() }

        func updateUIViewController(_ controller: Controller, context: Context) {
            controller.install()
        }

        static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
            controller.restore()
        }

        final class Controller: UIViewController, UIGestureRecognizerDelegate {
            private static let logger = Logger(
                subsystem: "app.chahua.chat", category: "swipe-back")

            private struct Replacement {
                weak var gesture: UIGestureRecognizer?
                weak var originalDelegate: UIGestureRecognizerDelegate?
                let wasEnabled: Bool
            }

            private var replacements: [ObjectIdentifier: Replacement] = [:]
            private var isVisible = false

            override func loadView() {
                view = UIView()
                view.isUserInteractionEnabled = false
            }

            override func viewDidAppear(_ animated: Bool) {
                super.viewDidAppear(animated)
                isVisible = true
                install()
            }

            override func viewDidLayoutSubviews() {
                super.viewDidLayoutSubviews()
                install()
            }

            override func viewWillDisappear(_ animated: Bool) {
                super.viewWillDisappear(animated)
                isVisible = false
                restore()
            }

            /// Idempotent: takes over each pop recognizer whose delegate is not this one,
            /// remembering UIKit's delegate only the first time.
            func install() {
                guard isVisible else { return }
                guard let navigationController else {
                    Self.logger.debug("install skipped: no navigation controller")
                    return
                }
                var gestures: [UIGestureRecognizer] = []
                if let edge = navigationController.interactivePopGestureRecognizer {
                    gestures.append(edge)
                }
                if #available(iOS 26, *),
                    let content = navigationController.interactiveContentPopGestureRecognizer
                {
                    gestures.append(content)
                }
                for gesture in gestures where gesture.delegate !== self {
                    let key = ObjectIdentifier(gesture)
                    if replacements[key] == nil {
                        replacements[key] = Replacement(
                            gesture: gesture, originalDelegate: gesture.delegate,
                            wasEnabled: gesture.isEnabled)
                        Self.logger.debug(
                            "took over \(type(of: gesture), privacy: .public); stack \(navigationController.viewControllers.count)"
                        )
                    } else {
                        Self.logger.debug(
                            "re-took \(type(of: gesture), privacy: .public) after delegate reset")
                    }
                    gesture.delegate = self
                    gesture.isEnabled = true
                }
            }

            fileprivate func restore() {
                for replacement in replacements.values {
                    guard let gesture = replacement.gesture, gesture.delegate === self else {
                        continue
                    }
                    gesture.delegate = replacement.originalDelegate
                    gesture.isEnabled = replacement.wasEnabled
                }
                replacements.removeAll()
            }

            func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
                guard let navigationController else { return false }
                let begins =
                    navigationController.viewControllers.count > 1
                    && navigationController.transitionCoordinator == nil
                Self.logger.debug(
                    "shouldBegin \(type(of: gestureRecognizer), privacy: .public): \(begins)")
                return begins
            }
        }
    }
#endif
