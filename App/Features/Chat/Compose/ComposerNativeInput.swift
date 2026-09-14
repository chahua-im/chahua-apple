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
        var focusOnEntry = false

        func makeNSView(context: Context) -> ComposerInputMarker {
            let marker = ComposerInputMarker()
            updateNSView(marker, context: context)
            return marker
        }

        func updateNSView(_ marker: ComposerInputMarker, context: Context) {
            marker.connect(
                input: input, draft: draft, isFocused: isFocused, isEnabled: isEnabled,
                onCompositionChanged: onCompositionChanged, onSubmit: onSubmit,
                focusOnEntry: focusOnEntry)
        }

        static func dismantleNSView(_ marker: ComposerInputMarker, coordinator: ()) { marker.disconnect() }
    }

    // A multiline SwiftUI TextField bounds its height but does not provide a
    // scrolling caption viewport on macOS. Keep a native scrolling text view
    // here, with the same committed-draft/IME bridge as the main composer. The
    // dialog and gallery do not scroll in response to caption wheel gestures.
    struct ComposerCaptionInput: NSViewRepresentable {
        let input: ComposerInputState
        let draft: Binding<String>
        let isEnabled: Bool
        let onCompositionChanged: ((Bool) -> Void)?
        let onSubmit: () -> Void

        func makeNSView(context: Context) -> ComposerCaptionScrollView {
            let view = ComposerCaptionScrollView()
            updateNSView(view, context: context)
            return view
        }

        func updateNSView(_ view: ComposerCaptionScrollView, context: Context) {
            view.configure(
                input: input, draft: draft, isEnabled: isEnabled,
                onCompositionChanged: onCompositionChanged, onSubmit: onSubmit)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerCaptionScrollView, context: Context) -> CGSize? {
            guard let width = proposal.width, width.isFinite else { return nil }
            return CGSize(width: width, height: nsView.captionHeight(for: width))
        }

        static func dismantleNSView(_ view: ComposerCaptionScrollView, coordinator: ()) { view.disconnect() }
    }

    final class ComposerCaptionScrollView: NSScrollView, NSTextViewDelegate {
        private let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
        private let marker = ComposerInputMarker()
        private weak var input: ComposerInputState?

        init() {
            super.init(frame: .zero)
            drawsBackground = false
            borderType = .noBorder
            hasVerticalScroller = true
            hasHorizontalScroller = false
            autohidesScrollers = true
            scrollerStyle = .overlay
            editor.drawsBackground = false
            editor.isRichText = false
            editor.importsGraphics = false
            editor.allowsUndo = true
            editor.font = .preferredFont(forTextStyle: .body)
            editor.textColor = .labelColor
            editor.insertionPointColor = .labelColor
            editor.textContainerInset = .zero
            editor.textContainer?.lineFragmentPadding = 0
            editor.textContainer?.widthTracksTextView = true
            editor.textContainer?.heightTracksTextView = false
            editor.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
            editor.isHorizontallyResizable = false
            editor.isVerticallyResizable = true
            editor.minSize = .zero
            editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            editor.autoresizingMask = [.width]
            editor.delegate = self
            editor.setAccessibilityLabel("Caption")
            documentView = editor
            addSubview(marker)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(
            input: ComposerInputState, draft: Binding<String>, isEnabled: Bool,
            onCompositionChanged: ((Bool) -> Void)?, onSubmit: @escaping () -> Void
        ) {
            self.input = input
            let text = input.editorText ?? draft.wrappedValue
            if editor.string != text, !editor.hasMarkedText() {
                let selection = editor.selectedRange()
                editor.string = text
                let length = (text as NSString).length
                let start = min(selection.location, length)
                editor.setSelectedRange(NSRange(location: start, length: min(selection.length, length - start)))
                invalidateIntrinsicContentSize()
            }
            editor.isEditable = isEnabled
            marker.connect(
                input: input, draft: draft, isFocused: true, isEnabled: isEnabled,
                onCompositionChanged: onCompositionChanged, onSubmit: onSubmit, focusOnEntry: true)
        }

        func captionHeight(for width: CGFloat) -> CGFloat {
            guard let container = editor.textContainer, let layout = editor.layoutManager, let font = editor.font else { return 20 }
            let width = max(1, width)
            if editor.frame.width != width {
                editor.setFrameSize(NSSize(width: width, height: editor.frame.height))
            }
            layout.ensureLayout(for: container)
            let lineHeight = layout.defaultLineHeight(for: font)
            let textHeight = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
            let documentHeight = ceil(max(lineHeight, max(textHeight, contentSize.height)))
            if editor.frame.height != documentHeight {
                editor.setFrameSize(NSSize(width: width, height: documentHeight))
            }
            return ceil(min(lineHeight * 6, max(lineHeight, textHeight)))
        }

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: captionHeight(for: max(1, contentSize.width)))
        }

        override func layout() {
            super.layout()
            marker.frame = bounds
        }

        func textDidChange(_ notification: Notification) {
            input?.receiveEditorText(editor.string)
            invalidateIntrinsicContentSize()
        }

        func disconnect() {
            marker.disconnect()
            editor.delegate = nil
            input = nil
        }
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
        // Desktop entry focus must not raise the software keyboard on iOS.
        var focusOnEntry = false

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
        private var entryFocusRequested = false
        private var entryFocusPending = false
        private var entryFocusScheduled = false
    #else
        private weak var editor: UIView?
    #endif

    func connect(
        input: ComposerInputState, draft: Binding<String>, isFocused: Bool, isEnabled: Bool,
        onCompositionChanged: ((Bool) -> Void)?, onSubmit: (() -> Void)? = nil,
        focusOnEntry: Bool = false
    ) {
        self.input = input
        self.isComposerFocused = isFocused
        self.isComposerEnabled = isEnabled
        self.onSubmit = onSubmit
        input.configure(draft: draft, onCompositionChanged: onCompositionChanged)
        input.nativeInput = self
        #if os(macOS)
            if focusOnEntry, !entryFocusRequested {
                entryFocusRequested = true
                entryFocusPending = true
            }
            scheduleEntryFocus()
        #endif
    }

    func disconnect() {
        input?.detachAfterViewUpdate(finalSnapshot: snapshot())
        stopMonitoring()
        #if os(macOS)
            entryFocusPending = false
        #endif
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
            entryFocusScheduled = false
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

        override func layout() {
            super.layout()
            scheduleEntryFocus()
        }

        // SwiftUI's initial field-editor focus selects the entire restored draft.
        // Acquire focus once, when mounted and permitted, and put the caret at its
        // end in that same native transaction. Later updates never change a user's
        // selection, undo stack, or marked range.
        private func scheduleEntryFocus() {
            guard entryFocusPending, !entryFocusScheduled, isComposerEnabled, window != nil else { return }
            entryFocusScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.entryFocusScheduled = false
                guard self.entryFocusPending, self.isComposerEnabled,
                    let window = self.window, window.attachedSheet == nil,
                    let control = self.entryControl()
                else { return }
                self.entryFocusPending = false
                if let current = window.firstResponder as? NSTextView,
                    self.scopes(current), current.hasMarkedText() { return }
                // Set this window's editing target without activating the window
                // or application; a later activation must not replay entry focus.
                guard window.makeFirstResponder(control),
                    let editor = window.firstResponder as? NSTextView, self.scopes(editor)
                else { return }
                self.isComposerFocused = true
                self.editor = editor
                self.editorOwner = editor.delegate as AnyObject?
                guard !editor.hasMarkedText() else { return }
                let end = NSRange(location: (editor.string as NSString).length, length: 0)
                editor.setSelectedRange(end)
                editor.scrollRangeToVisible(end)
            }
        }

        private func entryControl() -> NSView? {
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            let surface = convert(bounds, to: nil)
            func editableControl(in view: NSView) -> NSView? {
                guard !view.isHidden else { return nil }
                if let field = view as? NSTextField, field.isEditable, field.isEnabled,
                    surface.intersects(field.convert(field.bounds, to: nil)) { return field }
                if let text = view as? NSTextView, text.isEditable,
                    surface.intersects(text.convert(text.bounds, to: nil)) { return text }
                for child in view.subviews {
                    if let control = editableControl(in: child) { return control }
                }
                return nil
            }
            var ancestor = superview
            while let view = ancestor {
                if let control = editableControl(in: view) { return control }
                ancestor = view.superview
            }
            return nil
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if window != nil, newWindow !== window {
                input?.detachAfterViewUpdate(finalSnapshot: snapshot())
                entryFocusPending = false
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
            scheduleEntryFocus()
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
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self else { return event }
                // A user action after entry supersedes delayed permission focus.
                // Do not take focus back from navigation, a dialog, or a selection.
                if event.window === self.window { self.entryFocusPending = false }
                guard event.type == .keyDown, self.isComposerFocused, self.isComposerEnabled,
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

#if os(iOS)
/// A window observer includes navigation and empty timeline space. SwiftUI's
/// ancestor tap gestures cannot exclude the composer's bounds without competing
/// with native row gestures, so this recognizer observes without preventing them.
struct ComposerOutsideTapObserver: UIViewRepresentable {
    var isFocused: Bool
    var dismiss: () -> Void

    func makeUIView(context: Context) -> ComposerOutsideTapView { ComposerOutsideTapView() }
    func updateUIView(_ view: ComposerOutsideTapView, context: Context) {
        view.isComposerFocused = isFocused
        view.dismiss = dismiss
    }
    static func dismantleUIView(_ view: ComposerOutsideTapView, coordinator: ()) {
        view.detach()
    }
}

final class ComposerOutsideTapView: UIView, UIGestureRecognizerDelegate {
    var isComposerFocused = false
    var dismiss: (() -> Void)?
    private lazy var tap: UITapGestureRecognizer = {
        let tap = ComposerOutsideTapRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        return tap
    }()

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    override func willMove(toWindow newWindow: UIWindow?) {
        detach()
        super.willMove(toWindow: newWindow)
        newWindow?.addGestureRecognizer(tap)
    }
    func detach() { tap.view?.removeGestureRecognizer(tap) }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        isComposerFocused && !bounds.contains(touch.location(in: self))
    }
    @objc private func tapped() {
        guard isComposerFocused else { return }
        dismiss?()
    }
}

private final class ComposerOutsideTapRecognizer: UITapGestureRecognizer {
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
#endif
