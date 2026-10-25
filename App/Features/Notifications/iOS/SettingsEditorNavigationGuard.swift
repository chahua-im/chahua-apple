#if os(iOS)
    import SwiftUI
    import UIKit

    // SwiftUI cannot veto a NavigationStack pop. Preserve UIKit's actual Back item and
    // interactive transitions, intercepting only attempts to leave a dirty/saving editor.
    struct SettingsEditorNavigationGuard: UIViewControllerRepresentable {
        let blocksBack: Bool
        let onBackAttempt: () -> Void

        func makeUIViewController(context: Context) -> Controller { Controller() }

        func updateUIViewController(_ controller: Controller, context: Context) {
            controller.blocksBack = blocksBack
            controller.onBackAttempt = onBackAttempt
            controller.install()
        }

        static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
            controller.uninstall()
        }

        final class Controller: UIViewController {
            var blocksBack = false
            var onBackAttempt: () -> Void = {}
            private weak var host: UIViewController?
            private var previousBackAction: UIAction?
            private var gestures: [PopDelegate] = []
            private lazy var guardedAction = UIAction { [weak self] _ in self?.onBackAttempt() }

            override func loadView() {
                view = UIView()
                view.isUserInteractionEnabled = false
            }

            override func viewDidAppear(_ animated: Bool) {
                super.viewDidAppear(animated)
                install()
            }

            override func viewDidLayoutSubviews() {
                super.viewDidLayoutSubviews()
                install()
            }

            override func viewDidDisappear(_ animated: Bool) {
                super.viewDidDisappear(animated)
                uninstall()
            }

            func install() {
                guard viewIfLoaded?.window != nil else { return }
                var ancestor = parent
                while let candidate = ancestor {
                    if let navigation = candidate.navigationController,
                        navigation.topViewController === candidate
                    {
                        if host !== candidate {
                            uninstall()
                            host = candidate
                            previousBackAction = candidate.navigationItem.backAction
                            var recognizers = [navigation.interactivePopGestureRecognizer]
                            if #available(iOS 26, *) {
                                recognizers.append(
                                    navigation.interactiveContentPopGestureRecognizer)
                            }
                            gestures = recognizers.compactMap { recognizer in
                                recognizer.map { PopDelegate(gesture: $0, owner: self) }
                            }
                        }
                        for gesture in gestures { gesture.install() }
                        let item = candidate.navigationItem
                        if blocksBack {
                            // UINavigationItem copies UIAction; ownership survives by identifier,
                            // not object identity. Otherwise a layout pass captures our own action.
                            if item.backAction?.identifier != guardedAction.identifier {
                                previousBackAction = item.backAction
                                item.backAction = guardedAction
                            }
                        } else if item.backAction?.identifier == guardedAction.identifier {
                            item.backAction = previousBackAction
                        }
                        return
                    }
                    ancestor = candidate.parent
                }
            }

            func uninstall() {
                if let item = host?.navigationItem,
                    item.backAction?.identifier == guardedAction.identifier
                {
                    item.backAction = previousBackAction
                }
                for gesture in gestures { gesture.uninstall() }
                gestures.removeAll()
                previousBackAction = nil
                host = nil
            }

            fileprivate func permitsSwipe() -> Bool {
                guard let host, host.navigationController?.topViewController === host else {
                    return true
                }
                guard blocksBack else { return true }
                onBackAttempt()
                return false
            }
        }

        // Forward UIKit's direction, transition, and gesture-coordination decisions rather
        // than replacing the system delegate with nil or forcing gestures to be enabled.
        private final class PopDelegate: NSObject, UIGestureRecognizerDelegate {
            private weak var gesture: UIGestureRecognizer?
            private weak var original: (any UIGestureRecognizerDelegate)?
            private weak var owner: Controller?

            init(gesture: UIGestureRecognizer, owner: Controller) {
                self.gesture = gesture
                self.owner = owner
            }

            func install() {
                guard let gesture, gesture.delegate !== self else { return }
                original = gesture.delegate
                gesture.delegate = self
            }

            func uninstall() {
                if let gesture, gesture.delegate === self { gesture.delegate = original }
            }

            func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
                guard original?.gestureRecognizerShouldBegin?(gestureRecognizer) ?? true else {
                    return false
                }
                return owner?.permitsSwipe() ?? true
            }

            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
            ) -> Bool {
                original?.gestureRecognizer?(
                    gestureRecognizer, shouldRecognizeSimultaneouslyWith: other) ?? false
            }

            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldRequireFailureOf other: UIGestureRecognizer
            ) -> Bool {
                original?.gestureRecognizer?(gestureRecognizer, shouldRequireFailureOf: other)
                    ?? false
            }

            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldBeRequiredToFailBy other: UIGestureRecognizer
            ) -> Bool {
                original?.gestureRecognizer?(gestureRecognizer, shouldBeRequiredToFailBy: other)
                    ?? false
            }

            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
            ) -> Bool {
                original?.gestureRecognizer?(gestureRecognizer, shouldReceive: touch) ?? true
            }

            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress
            ) -> Bool {
                original?.gestureRecognizer?(gestureRecognizer, shouldReceive: press) ?? true
            }

            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent
            ) -> Bool {
                original?.gestureRecognizer?(gestureRecognizer, shouldReceive: event) ?? true
            }
        }
    }
#endif
