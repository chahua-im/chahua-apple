import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

enum ComposerInputSnapshot {
    case marked
    case committed(String)
    case unavailable
}

@MainActor
protocol ComposerNativeInput: AnyObject {
    func snapshot() -> ComposerInputSnapshot
    func insertNewline() -> Bool
}

struct ComposerSendFocus: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
            // Send must not take keyboard focus from the editor on mouse clicks.
            content.focusable(false)
        #else
            content
        #endif
    }
}

// SwiftUI exposes no marked-text API. Observe its editor without replacing its
// delegate or editing model. On macOS intercept submission before AppKit's
// field-editor Return command ends editing and subsequent focus selects all.
#if os(macOS)
    struct ComposerInputBridge: NSViewRepresentable {
        let input: ComposerInputState
        let draft: Binding<String>
        let isFocused: Bool
        let isEnabled: Bool
        let onCompositionChanged: ((Bool) -> Void)?
        var onSubmit: (() -> Void)? = nil

        func makeNSView(context: Context) -> ComposerInputMarker {
            let marker = ComposerInputMarker()
            updateNSView(marker, context: context)
            return marker
        }

        func updateNSView(_ marker: ComposerInputMarker, context: Context) {
            marker.connect(
                input: input, draft: draft, isFocused: isFocused, isEnabled: isEnabled,
                onCompositionChanged: onCompositionChanged, onSubmit: onSubmit)
        }

        static func dismantleNSView(_ marker: ComposerInputMarker, coordinator: ()) { marker.disconnect() }
    }

    typealias ComposerMarkerView = NSView
#else
    struct ComposerInputBridge: UIViewRepresentable {
        let input: ComposerInputState
        let draft: Binding<String>
        let isFocused: Bool
        let isEnabled: Bool
        let onCompositionChanged: ((Bool) -> Void)?
        var onSubmit: (() -> Void)? = nil

        func makeUIView(context: Context) -> ComposerInputMarker {
            let marker = ComposerInputMarker()
            updateUIView(marker, context: context)
            return marker
        }

        func updateUIView(_ marker: ComposerInputMarker, context: Context) {
            marker.connect(
                input: input, draft: draft, isFocused: isFocused, isEnabled: isEnabled,
                onCompositionChanged: onCompositionChanged, onSubmit: onSubmit)
        }

        static func dismantleUIView(_ marker: ComposerInputMarker, coordinator: ()) { marker.disconnect() }
    }

    typealias ComposerMarkerView = UIView
#endif

final class ComposerInputMarker: ComposerMarkerView, ComposerNativeInput {
    private var input: ComposerInputState?
    private var isComposerFocused = false
    private var isComposerEnabled = false
    private var onSubmit: (() -> Void)?
    #if os(macOS)
        private weak var editor: NSTextView?
        private weak var editorOwner: AnyObject?
        private var keyMonitor: Any?
    #else
        private weak var editor: UIView?
    #endif

    func connect(
        input: ComposerInputState, draft: Binding<String>, isFocused: Bool, isEnabled: Bool,
        onCompositionChanged: ((Bool) -> Void)?, onSubmit: (() -> Void)? = nil
    ) {
        self.input = input
        self.isComposerFocused = isFocused
        self.isComposerEnabled = isEnabled
        self.onSubmit = onSubmit
        input.configure(draft: draft, onCompositionChanged: onCompositionChanged)
        input.nativeInput = self
    }

    func disconnect() {
        input?.detachAfterViewUpdate(finalSnapshot: snapshot())
        stopMonitoring()
        input?.nativeInput = nil
        input = nil
        onSubmit = nil
    }

    private func stopMonitoring() {
        NotificationCenter.default.removeObserver(self)
        editor = nil
        #if os(macOS)
            editorOwner = nil
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        #endif
    }

    private func observeUndo() {
        // Native undo may bypass SwiftUI's binding and text-change notification.
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(nativeUndoChanged(_:)), name: name, object: nil)
        }
    }

    @objc private func nativeUndoChanged(_ notification: Notification) {
        guard let manager = notification.object as? UndoManager,
            manager === resolveEditor()?.undoManager
        else { return }
        input?.nativeInputChanged(isEdit: true)
    }

    #if os(macOS)
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if window != nil, newWindow !== window {
                input?.detachAfterViewUpdate(finalSnapshot: snapshot())
                stopMonitoring()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else {
                input?.detachAfterViewUpdate()
                return
            }
            observeUndo()
            for name in [
                NSText.didBeginEditingNotification, NSText.didChangeNotification,
                NSText.didEndEditingNotification, NSTextView.didChangeSelectionNotification,
            ] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(nativeChanged(_:)), name: name, object: nil)
            }
            // SwiftUI onSubmit runs after AppKit ends field editing. Consume
            // ordinary Return here instead, preserving the editing session and
            // selection. Shift-Return uses native insertion outside SwiftUI's
            // update so selection replacement and undo remain native.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isComposerFocused, self.isComposerEnabled,
                    event.window === self.window,
                    event.keyCode == 36 || event.keyCode == 76,
                    let editor = self.resolveEditor(), self.window?.firstResponder === editor
                else { return event }
                // Inspect before native dispatch: candidate confirmation can
                // unmark and invoke SwiftUI onSubmit in the very same event.
                // macOS submission belongs only to this monitor, not onSubmit.
                if editor.hasMarkedText() {
                    self.input?.nativeInputChanged()
                    return event
                }
                let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
                if modifiers == .shift { return self.insertNewline() ? nil : event }
                guard modifiers.isEmpty, let onSubmit = self.onSubmit else { return event }
                onSubmit()
                return nil
            }
        }

        private func resolveEditor() -> NSTextView? {
            guard let window else { return nil }
            if let editor {
                // A cached editor remains ours after focus loss, until AppKit
                // changes its owner or moves it outside the composer's surface.
                return owns(editor) && scopes(editor) ? editor : nil
            }
            guard isComposerFocused, let candidate = window.firstResponder as? NSTextView, scopes(candidate) else {
                return nil
            }
            editor = candidate
            editorOwner = candidate.delegate as AnyObject?
            return candidate
        }

        private func owns(_ candidate: NSTextView) -> Bool {
            guard candidate === editor else { return false }
            // AppKit can reuse a window's field editor for a different control.
            // Its delegate identifies that owner; never read after it changes.
            return !candidate.isFieldEditor
                || (editorOwner != nil && candidate.delegate as AnyObject? === editorOwner)
        }

        private func scopes(_ candidate: NSTextView) -> Bool {
            candidate.isEditable && candidate.window === window
                && convert(bounds, to: nil).intersects(candidate.convert(candidate.bounds, to: nil))
        }

        func snapshot() -> ComposerInputSnapshot {
            guard let editor = resolveEditor() else { return .unavailable }
            return snapshot(of: editor)
        }

        private func snapshot(of editor: NSTextView) -> ComposerInputSnapshot {
            editor.hasMarkedText() ? .marked : .committed(editor.string)
        }

        func insertNewline() -> Bool {
            guard let editor = resolveEditor(), !editor.hasMarkedText() else { return false }
            editor.insertNewlineIgnoringFieldEditor(nil)
            return true
        }

        @objc private func nativeChanged(_ notification: Notification) {
            if notification.name == NSText.didEndEditingNotification,
                let ended = notification.object as? NSTextView, owns(ended)
            {
                // Copy before AppKit releases/reuses the shared editor. The queued
                // settlement can finish after firstResponder has changed.
                input?.nativeEditingEnded(snapshot(of: ended))
                editor = nil
                editorOwner = nil
                return
            }
            guard let editor = resolveEditor(), notification.object as? NSTextView === editor else { return }
            input?.nativeInputChanged()
        }
    #else
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        override func willMove(toWindow newWindow: UIWindow?) {
            if window != nil, newWindow !== window {
                input?.detachAfterViewUpdate(finalSnapshot: snapshot())
                stopMonitoring()
            }
            super.willMove(toWindow: newWindow)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            stopMonitoring()
            guard window != nil else {
                input?.detachAfterViewUpdate()
                return
            }
            observeUndo()
            for name in [
                UITextField.textDidBeginEditingNotification, UITextField.textDidChangeNotification,
                UITextField.textDidEndEditingNotification, UITextView.textDidBeginEditingNotification,
                UITextView.textDidChangeNotification, UITextView.textDidEndEditingNotification,
            ] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(nativeChanged(_:)), name: name, object: nil)
            }
        }

        private func resolveEditor() -> UIView? {
            guard let window else { return nil }
            if let editor { return scopes(editor) ? editor : nil }
            guard isComposerFocused, let candidate = firstInput(in: window), scopes(candidate) else { return nil }
            editor = candidate
            return candidate
        }

        private func firstInput(in view: UIView) -> UIView? {
            if view.isFirstResponder, view is any UITextInput { return view }
            for child in view.subviews {
                if let input = firstInput(in: child) { return input }
            }
            return nil
        }

        private func scopes(_ candidate: UIView) -> Bool {
            if let textView = candidate as? UITextView, !textView.isEditable { return false }
            return candidate.window === window
                && convert(bounds, to: nil).intersects(candidate.convert(candidate.bounds, to: nil))
        }

        func snapshot() -> ComposerInputSnapshot {
            guard let view = resolveEditor() else { return .unavailable }
            return snapshot(of: view)
        }

        private func snapshot(of view: UIView) -> ComposerInputSnapshot {
            guard let editor = view as? any UITextInput else { return .unavailable }
            guard editor.markedTextRange == nil else { return .marked }
            guard let range = editor.textRange(from: editor.beginningOfDocument, to: editor.endOfDocument),
                let text = editor.text(in: range)
            else { return .unavailable }
            return .committed(text)
        }

        // Preserve UIKit's native behavior until hardware dispatch is verified.
        func insertNewline() -> Bool { false }

        @objc private func nativeChanged(_ notification: Notification) {
            if notification.name == UITextField.textDidEndEditingNotification
                || notification.name == UITextView.textDidEndEditingNotification,
                let ended = notification.object as? UIView, ended === editor
            {
                input?.nativeEditingEnded(snapshot(of: ended))
                editor = nil
                return
            }
            guard let editor = resolveEditor(), notification.object as? UIView === editor else { return }
            input?.nativeInputChanged()
        }
    #endif
}
