#if os(iOS)
    import SwiftUI
    import UIKit
    import os

    /// Restores swipe-back on screens that hide the system navigation bar to draw
    /// the app header. Archived lists allow only edge swipes so horizontal row
    /// actions do not compete with iOS 26's full-screen pop recognizer.
    ///
    /// Requirement: native interactive back navigation must work with the bar hidden.
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
        var allowsContentSwipeBack = true

        func makeUIViewController(context: Context) -> Controller {
            let controller = Controller()
            controller.allowsContentSwipeBack = allowsContentSwipeBack
            return controller
        }

        func updateUIViewController(_ controller: Controller, context: Context) {
            controller.allowsContentSwipeBack = allowsContentSwipeBack
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
                /// Strong: the recognizer's `delegate` is weak, so while replaced nothing else
                /// may retain UIKit's delegate. Losing it restores `nil`, which lets the edge
                /// pop begin on the root controller and freezes navigation.
                var originalDelegate: UIGestureRecognizerDelegate?
                let wasEnabled: Bool
            }

            private var replacements: [ObjectIdentifier: Replacement] = [:]
            private var isVisible = false
            var allowsContentSwipeBack = true

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
            /// remembering UIKit's latest delegate so `restore()` hands back the current one.
            func install() {
                guard isVisible else { return }
                guard let navigationController else {
                    Self.logger.debug("install skipped: no navigation controller")
                    return
                }
                var gestures: [(UIGestureRecognizer, Bool)] = []
                if let edge = navigationController.interactivePopGestureRecognizer {
                    gestures.append((edge, true))
                }
                if #available(iOS 26, *),
                    let content = navigationController.interactiveContentPopGestureRecognizer
                {
                    gestures.append((content, allowsContentSwipeBack))
                }
                for (gesture, enabled) in gestures
                where gesture.delegate !== self || gesture.isEnabled != enabled {
                    let key = ObjectIdentifier(gesture)
                    if replacements[key] == nil {
                        replacements[key] = Replacement(
                            gesture: gesture, originalDelegate: gesture.delegate,
                            wasEnabled: gesture.isEnabled)
                        Self.logger.debug(
                            "took over \(type(of: gesture), privacy: .public); stack \(navigationController.viewControllers.count)"
                        )
                    } else {
                        // UIKit installed a new delegate; the one remembered earlier is stale.
                        if let current = gesture.delegate, current !== self {
                            replacements[key]?.originalDelegate = current
                        }
                        Self.logger.debug(
                            "re-took \(type(of: gesture), privacy: .public) after delegate reset")
                    }
                    gesture.delegate = self
                    gesture.isEnabled = enabled
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
