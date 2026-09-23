#if os(iOS)
    import Combine
    import SwiftUI
    import UIKit

    @MainActor
    final class MessageInteractionAnimation: ObservableObject {
        @Published var isPresented = false
        @Published var previewScale: CGFloat = 1
        @Published var previewOpacity: CGFloat = 1
        @Published var safeAreaInsets: UIEdgeInsets = .zero
    }

    /// The reaction strip and action grid cannot be expressed by UIContextMenuInteraction.
    /// A timeline SwiftUI overlay also stops below navigation/composer chrome. Mount one
    /// native hosting view directly in the originating window instead, without creating
    /// another key window or borrowing a view from a reusable message cell.
    struct MessageInteractionWindowPresenter: UIViewRepresentable {
        let isPresented: Bool
        let reduceMotion: Bool
        let pressFeedback: MessageBubblePressFeedback?
        let onClose: () -> Void
        let overlay: (MessageInteractionAnimation) -> AnyView

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeUIView(context: Context) -> MessageInteractionWindowAnchor {
            let anchor = MessageInteractionWindowAnchor()
            anchor.isUserInteractionEnabled = false
            anchor.windowChanged = { [weak coordinator = context.coordinator] window in
                coordinator?.attach(to: window)
            }
            return anchor
        }

        func updateUIView(_ view: MessageInteractionWindowAnchor, context: Context) {
            let coordinator = context.coordinator
            coordinator.isPresented = isPresented
            coordinator.reduceMotion = reduceMotion
            coordinator.pressFeedback = pressFeedback
            coordinator.onClose = onClose
            coordinator.overlay = overlay
            coordinator.attach(to: view.window)
        }

        static func dismantleUIView(
            _ view: MessageInteractionWindowAnchor, coordinator: Coordinator
        ) {
            view.windowChanged = nil
            coordinator.remove()
        }

        @MainActor
        final class Coordinator {
            var isPresented = false
            var reduceMotion = false
            var pressFeedback: MessageBubblePressFeedback?
            var onClose: (() -> Void)?
            var overlay: ((MessageInteractionAnimation) -> AnyView)?
            private weak var window: UIWindow?
            private var controller: MessageInteractionHostingController?
            private var animation = MessageInteractionAnimation()
            private var dismissal: Task<Void, Never>?
            private var lift: Task<Void, Never>?
            private var activePressFeedback: MessageBubblePressFeedback?

            func attach(to window: UIWindow?) {
                guard let window else {
                    remove()
                    return
                }
                if self.window != nil, self.window !== window { remove() }
                self.window = window
                guard isPresented else {
                    dismiss()
                    return
                }
                guard let overlay else { return }
                if let controller {
                    guard dismissal == nil else { return }
                    controller.rootView = overlay(animation)
                    controller.onClose = onClose
                    return
                }
                animation = MessageInteractionAnimation()
                activePressFeedback = pressFeedback
                animation.previewScale = reduceMotion ? 1 : pressFeedback?.scale ?? 1
                animation.previewOpacity = pressFeedback?.opacity ?? (reduceMotion ? 0 : 1)
                animation.safeAreaInsets = window.safeAreaInsets
                let controller = MessageInteractionHostingController(rootView: overlay(animation))
                controller.onClose = onClose
                controller.onSafeAreaChange = { [weak animation = animation] insets in
                    guard let animation, animation.safeAreaInsets != insets else { return }
                    animation.safeAreaInsets = insets
                }
                controller.view.backgroundColor = .clear
                controller.view.frame = window.bounds
                controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                controller.view.accessibilityViewIsModal = true
                // The view is a sibling of the root controller's view, not its
                // descendant. Retain an unparented controller and drive appearance
                // explicitly; assigning the root as parent violates UIKit containment.
                controller.beginAppearanceTransition(true, animated: false)
                window.addSubview(controller.view)
                controller.endAppearanceTransition()
                self.controller = controller
                controller.view.layoutIfNeeded()
                activePressFeedback?.handOff()
                controller.becomeFirstResponder()
                // Mount at the source's frozen press scale before hiding that bubble.
                // Only this preview lifts; the source never pops or resets on screen.
                lift = Task { @MainActor [weak self, weak controller] in
                    await Task.yield()
                    guard let self, let controller, self.controller === controller,
                        self.isPresented, !Task.isCancelled
                    else { return }
                    let entry: Animation =
                        self.reduceMotion
                        ? .easeOut(duration: 0.16) : .spring(response: 0.38, dampingFraction: 0.82)
                    withAnimation(entry) {
                        self.animation.isPresented = true
                        self.animation.previewScale = self.reduceMotion ? 1 : 1.035
                        self.animation.previewOpacity = 1
                    }
                    UIAccessibility.post(notification: .screenChanged, argument: controller.view)
                    if !self.reduceMotion {
                        try? await Task.sleep(for: .milliseconds(120))
                        guard !Task.isCancelled, self.controller === controller else { return }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            self.animation.previewScale = 1
                        }
                    }
                }
            }

            private func dismiss() {
                guard controller != nil, dismissal == nil else { return }
                lift?.cancel()
                dismissal = Task { @MainActor [weak self] in
                    // attach(to:) is called by updateUIView. Publish only after
                    // that SwiftUI update has finished, as with the entry animation.
                    await Task.yield()
                    guard let self, !Task.isCancelled else { return }
                    withAnimation(
                        self.reduceMotion
                            ? .easeOut(duration: 0.15)
                            : .spring(response: 0.28, dampingFraction: 0.92)
                    ) {
                        self.animation.isPresented = false
                        self.animation.previewScale = 1
                        self.animation.previewOpacity = self.reduceMotion ? 0 : 1
                    }
                    try? await Task.sleep(for: .milliseconds(self.reduceMotion ? 150 : 280))
                    guard !Task.isCancelled else { return }
                    self.remove()
                    UIAccessibility.post(notification: .screenChanged, argument: nil)
                }
            }

            func remove() {
                lift?.cancel()
                lift = nil
                dismissal?.cancel()
                dismissal = nil
                controller?.beginAppearanceTransition(false, animated: false)
                controller?.view.removeFromSuperview()
                controller?.endAppearanceTransition()
                controller = nil
                activePressFeedback?.restore()
                activePressFeedback = nil
                pressFeedback?.restore()
                pressFeedback = nil
                window = nil
            }
        }
    }

    final class MessageInteractionWindowAnchor: UIView {
        var windowChanged: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            windowChanged?(window)
        }
    }

    private final class MessageInteractionHostingController: UIHostingController<AnyView> {
        var onClose: (() -> Void)?
        var onSafeAreaChange: ((UIEdgeInsets) -> Void)?
        override func viewSafeAreaInsetsDidChange() {
            super.viewSafeAreaInsetsDidChange()
            // UIKit owns the full-window safe area even though the SwiftUI backdrop
            // intentionally ignores it; publish outside the hosting layout pass.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onSafeAreaChange?(self.view.safeAreaInsets)
            }
        }
        override var canBecomeFirstResponder: Bool { true }
        override var keyCommands: [UIKeyCommand]? {
            [
                UIKeyCommand(
                    input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close))
            ]
        }
        override func accessibilityPerformEscape() -> Bool {
            onClose?()
            return true
        }
        @objc private func close() { onClose?() }
    }
#endif
