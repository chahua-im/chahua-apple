#if os(macOS)
    import AppKit
    import SwiftUI

    /// A SwiftUI shortcut runs before ordinary focused controls. A window-scoped
    /// AppKit fallback can leave Space with the editor, menus and native controls.
    struct MacVoicePlaybackShortcut: NSViewRepresentable {
        func makeNSView(context: Context) -> Marker { Marker() }
        func updateNSView(_ view: Marker, context: Context) {}

        static func dismantleNSView(_ view: Marker, coordinator: ()) {
            view.stopMonitoring()
        }

        final class Marker: NSView {
            private var monitor: Any?
            private static let focusedElementSelector = NSSelectorFromString(
                "accessibilityFocusedUIElement")
            private static let roleSelector = NSSelectorFromString("accessibilityRole")
            private static let passiveRoles: Set<String> = [
                "AXApplication", "AXWindow", "AXGroup", "AXScrollArea", "AXTable", "AXList",
                "AXRow", "AXCell", "AXStaticText", "AXUnknown",
            ]

            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                stopMonitoring()
                guard window != nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                    [weak self] event in
                    let consumed = MainActor.assumeIsolated { self?.route(event) ?? false }
                    return consumed ? nil : event
                }
            }

            func stopMonitoring() {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }

            private func route(_ event: NSEvent) -> Bool {
                guard event.keyCode == 49,
                    event.modifierFlags.intersection([
                        .shift, .control, .option, .command, .function,
                    ]).isEmpty,
                    let window, let keyWindow = event.window, keyWindow.isKeyWindow,
                    owns(keyWindow, in: window),
                    let controller = VoicePlaybackSession.shared.controller,
                    canUseSpace(in: keyWindow)
                else { return false }
                if !event.isARepeat { controller.toggle() }
                return true
            }

            private func owns(_ candidate: NSWindow, in root: NSWindow) -> Bool {
                var candidate: NSWindow? = candidate
                while let current = candidate {
                    if current === root { return true }
                    candidate = current.sheetParent
                }
                return false
            }

            private func canUseSpace(in window: NSWindow) -> Bool {
                guard let responder = window.firstResponder else { return false }
                if responder === window { return true }
                guard let view = responder as? NSView,
                    !(view is NSControl), !(view is NSText), !(view is NSTextInputClient)
                else { return false }
                // A SwiftUI button can share its hosting view's AppKit responder.
                // Keep its keyboard action if AppKit reports a focused control there.
                if NSApp.responds(to: Self.focusedElementSelector),
                    let focused = NSApp.perform(Self.focusedElementSelector)?.takeUnretainedValue()
                        as? NSObject,
                    focused.responds(to: Self.roleSelector),
                    let role = focused.perform(Self.roleSelector)?.takeUnretainedValue() as? String,
                    !Self.passiveRoles.contains(role)
                {
                    return false
                }
                if view === window.contentView { return true }
                // Only take the fallback from the shell's hosting ancestors;
                // other native views can own key handling without being controls.
                return isDescendant(of: view)
            }
        }
    }
#endif
