import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
    import UniformTypeIdentifiers
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
    var attributedText: NSAttributedString? { get }
    var selection: NSRange? { get }
    var canHydrateMentionLabels: Bool { get }
    func installMentionText(_ text: NSAttributedString)
    func replaceMention(in range: NSRange, with text: NSAttributedString) -> Bool
    func commitMarkedText() -> ComposerInputSnapshot
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

// Native exception: SwiftUI's String binding has no mention identity, marked
// text, or selection API. Keep its visual TextField and delegate, track UID
// spans alongside its plain text storage, and use native replacement/undo.
// Never infer identity from a visible name or replace the text delegate.
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
                onCompositionChanged: onCompositionChanged, onSubmit: onSubmit)
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
        var onPasteImages: (([NSItemProvider]) -> Void)? = nil
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
            marker.onPasteImages = onPasteImages
            marker.updateImagePasteSupport()
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
    private weak var mentionStorage: NSTextStorage?
    private weak var mentionUndoManager: UndoManager?
    private var trackedSpans: [(ComposerMentionSpan, NSRange)] = []
    private var trackedText = ""
    private struct MentionUndoState {
        let text: String
        let spans: [(ComposerMentionSpan, NSRange)]
    }
    private var pendingMentionUndo: MentionUndoState?
    private var changingMentionStorage = false
    #if os(macOS)
        private weak var editor: NSTextView?
        private weak var editorOwner: AnyObject?
        private var keyMonitor: Any?
        private var entryFocusRequested = false
        private var entryFocusPending = false
        private var entryFocusScheduled = false
    #else
        private weak var editor: UIView?
        var onPasteImages: (([NSItemProvider]) -> Void)?
        private weak var pasteEditor: (any UITextPasteConfigurationSupporting)?
        private weak var previousPasteDelegate: (any UITextPasteDelegate)?
        private var previousPasteConfiguration: UIPasteConfiguration?
        private var pendingPastedImages: [NSItemProvider] = []
        private var selectionObserver: CFRunLoopObserver?
        private var lastSelection: NSRange?
        private var lastMarkedRange: NSRange?
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
        #else
            onPasteImages = nil
            pendingPastedImages.removeAll()
        #endif
        input?.nativeInput = nil
        input = nil
        onSubmit = nil
    }

    private func stopMonitoring() {
        NotificationCenter.default.removeObserver(self)
        mentionStorage = nil
        trackedSpans = []
        #if os(iOS)
            restoreImagePasteSupport()
            if let selectionObserver { CFRunLoopObserverInvalidate(selectionObserver) }
            selectionObserver = nil
            lastSelection = nil
            lastMarkedRange = nil
        #endif
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
        if let mentionStorage {
            if let pending = pendingMentionUndo, pending.text == mentionStorage.string {
                trackedSpans = pending.spans
                for (span, _) in trackedSpans { span.isValid = true }
            }
            pendingMentionUndo = nil
            trackedText = mentionStorage.string
        }
        #if os(macOS)
            // Undo can skip the field delegate's edit callback. Update it before
            // publishing so SwiftUI does not replay the binding as another edit,
            // which would discard the native redo transaction.
            if let editor = resolveEditor() {
                editor.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: editor))
            }
        #endif
        input?.nativeInputChanged(isEdit: true)
        input?.settleNativeInput()
    }

    var attributedText: NSAttributedString? {
        #if os(macOS)
            guard let text = resolveEditor()?.string else { return nil }
        #else
            guard let text = (resolveEditor() as? UITextView)?.text else { return nil }
        #endif
        return mentionSnapshot(text)
    }

    private func mentionSnapshot(_ string: String) -> NSAttributedString {
        // SwiftUI reconciles its field as plain text. Putting identity attributes
        // on that storage makes it rewrite identical text and discard native
        // redo. Keep spans alongside the editor and annotate owned snapshots only.
        let text = NSMutableAttributedString(string: string)
        for (span, range) in trackedSpans where span.isValid && NSMaxRange(range) <= text.length {
            text.addAttribute(ComposerMentionText.attribute, value: span, range: range)
        }
        return text
    }

    var selection: NSRange? {
        #if os(macOS)
            resolveEditor()?.selectedRange()
        #else
            (resolveEditor() as? UITextView)?.selectedRange
        #endif
    }

    var canHydrateMentionLabels: Bool {
        // Renaming underneath a live undo stack changes the ranges stored by
        // native undo. Defer that cosmetic refresh until a fresh editing session.
        guard case .marked = snapshot() else {
            return (resolveEditor()?.undoManager ?? mentionUndoManager)?.canUndo != true
        }
        return false
    }

    private func observeMentionStorage(_ storage: NSTextStorage?) {
        guard let storage, storage !== mentionStorage else { return }
        if let mentionStorage {
            NotificationCenter.default.removeObserver(self, name: NSTextStorage.willProcessEditingNotification, object: mentionStorage)
        }
        mentionStorage = storage
        mentionUndoManager = resolveEditor()?.undoManager
        NotificationCenter.default.addObserver(
            self, selector: #selector(mentionStorageChanged(_:)),
            name: NSTextStorage.willProcessEditingNotification, object: storage)
        if let input, storage.string == input.editorText
            || storage.string == ComposerMentionText.wireText(input.mentionText) {
            installMentionText(input.mentionText)
        } else {
            trackedSpans = []
        }
        trackedText = storage.string
    }

    func installMentionText(_ text: NSAttributedString) {
        guard !changingMentionStorage, let editor = resolveEditor(),
              case .committed = snapshot(), let storage = mentionStorage else { return }
        let oldText = mentionSnapshot(storage.string)
        let oldSelection = selection
        let textChanged = storage.string != text.string
        changingMentionStorage = true
        storage.beginEditing()
        if textChanged {
            #if os(macOS)
                // This replacement bypasses the SwiftUI TextField's attributed
                // update. Match the font it already chose for normal typing so a
                // restored edit does not fall back to NSTextStorage's default.
                let font = (editor.typingAttributes[.font] as? NSFont) ?? editor.font
                let replacement = font.map {
                    NSAttributedString(string: text.string, attributes: [.font: $0])
                } ?? NSAttributedString(string: text.string)
                storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: replacement)
            #else
                storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text.string)
            #endif
        }
        storage.endEditing()
        trackedSpans = ComposerMentionText.spans(in: text)
        trackedText = storage.string
        if let oldSelection {
            setSelection(mappedSelection(oldSelection, from: oldText, to: text))
        }
        #if os(macOS)
            // Direct storage replacement bypasses NSTextView's change callback.
            // Notify the existing SwiftUI field so its multiline height updates,
            // without replacing the control or interrupting keyboard focus.
            if textChanged { editor.didChangeText() }
        #endif
        changingMentionStorage = false
    }

    private func mappedSelection(_ selection: NSRange, from old: NSAttributedString, to new: NSAttributedString) -> NSRange {
        let oldSpans = ComposerMentionText.spans(in: old)
        let newSpans = ComposerMentionText.spans(in: new)
        func offset(_ position: Int) -> Int {
            guard oldSpans.map({ $0.0.uid }) == newSpans.map({ $0.0.uid }) else { return min(position, new.length) }
            var change = 0
            for ((_, before), (_, after)) in zip(oldSpans, newSpans) {
                if position < before.location { break }
                if position <= NSMaxRange(before) {
                    return min(new.length, after.location + min(position - before.location, after.length))
                }
                change += after.length - before.length
            }
            return min(new.length, max(0, position + change))
        }
        let start = offset(selection.location)
        return NSRange(location: start, length: max(0, offset(NSMaxRange(selection)) - start))
    }

    private func setSelection(_ range: NSRange) {
        #if os(macOS)
            resolveEditor()?.setSelectedRange(range)
        #else
            (resolveEditor() as? UITextView)?.selectedRange = range
        #endif
    }

    @objc private func mentionStorageChanged(_ notification: Notification) {
        guard !changingMentionStorage, let storage = notification.object as? NSTextStorage,
              storage === mentionStorage, storage.editedMask.contains(.editedCharacters) else { return }
        // A field editor can outlive its control and be reused. Only its
        // current composer may update mention identities.
        guard input?.nativeInput === self else { return }
        #if os(macOS)
            guard resolveEditor()?.textStorage === storage else { return }
        #else
            guard (resolveEditor() as? UITextView)?.textStorage === storage else { return }
        #endif
        let currentText = storage.string
        guard currentText != trackedText else { return }
        guard !trackedSpans.isEmpty else {
            trackedText = currentText
            return
        }
        let before = MentionUndoState(text: trackedText, spans: trackedSpans)
        let previous = trackedText as NSString
        let current = currentText as NSString
        // SwiftUI can merge a character edit with paragraph-wide attribute
        // changes. NSTextStorage.editedRange then overstates what was typed.
        var start = 0
        while start < min(previous.length, current.length),
              previous.character(at: start) == current.character(at: start) { start += 1 }
        var suffix = 0
        while suffix < min(previous.length, current.length) - start,
              previous.character(at: previous.length - suffix - 1)
                == current.character(at: current.length - suffix - 1) { suffix += 1 }
        let replaced = NSRange(location: start, length: previous.length - start - suffix)
        let delta = current.length - previous.length
        trackedSpans = trackedSpans.compactMap { span, range in
            let touches = replaced.length == 0
                ? start > range.location && start < NSMaxRange(range)
                : NSIntersectionRange(replaced, range).length > 0
            if touches {
                span.isValid = false
                return nil
            }
            let location = range.location >= NSMaxRange(replaced) ? range.location + delta : range.location
            return (span, NSRange(location: location, length: range.length))
        }
        trackedText = currentText
        let manager = resolveEditor()?.undoManager
        if manager?.isUndoing != true, manager?.isRedoing != true,
           !before.spans.isEmpty || !trackedSpans.isEmpty {
            let after = MentionUndoState(text: trackedText, spans: trackedSpans)
            manager?.registerUndo(withTarget: self) { marker in
                marker.restoreMentionUndo(before, inverse: after)
            }
        }
    }

    // A plain-text native editor does not retain custom attributes in its undo
    // payload. Restore metadata only after the native text transaction finishes.
    private func restoreMentionUndo(_ state: MentionUndoState, inverse: MentionUndoState) {
        resolveEditor()?.undoManager?.registerUndo(withTarget: self) { marker in
            marker.restoreMentionUndo(inverse, inverse: state)
        }
        pendingMentionUndo = state
    }

    func replaceMention(in range: NSRange, with text: NSAttributedString) -> Bool {
        guard case .committed = snapshot(), let selection,
              selection.length == 0, selection.location == NSMaxRange(range),
              let editor = resolveEditor(), let storage = mentionStorage,
              NSMaxRange(range) <= storage.length else { return false }
        let before = MentionUndoState(text: trackedText, spans: trackedSpans)
        changingMentionStorage = true
        #if os(macOS)
            editor.breakUndoCoalescing()
            editor.insertText(text.string, replacementRange: range)
        #else
            guard let textView = editor as? UITextView else {
                changingMentionStorage = false
                return false
            }
            textView.selectedRange = range
            textView.insertText(text.string)
        #endif
        // Let the editor own text replacement, selection and undo. Changing its
        // storage directly leaves SwiftUI's field coordinator out of sync.
        let delta = text.length - range.length
        trackedSpans = before.spans.map { span, previous in
            (span, NSRange(location: previous.location >= NSMaxRange(range)
                ? previous.location + delta : previous.location, length: previous.length))
        }
        trackedSpans.append(contentsOf: ComposerMentionText.spans(in: text).map { span, inserted in
            (span, NSRange(location: range.location + inserted.location, length: inserted.length))
        })
        trackedSpans.sort { $0.1.location < $1.1.location }
        trackedText = storage.string
        let after = MentionUndoState(text: trackedText, spans: trackedSpans)
        editor.undoManager?.registerUndo(withTarget: self) { marker in
            marker.restoreMentionUndo(before, inverse: after)
        }
        #if os(macOS)
            editor.breakUndoCoalescing()
        #endif
        changingMentionStorage = false
        input?.receiveEditorText(storage.string)
        return true
    }

    func commitMarkedText() -> ComposerInputSnapshot {
        guard let editor = resolveEditor() else { return .unavailable }
        #if os(macOS)
            if editor.hasMarkedText() {
                editor.unmarkText()
                editor.inputContext?.discardMarkedText()
            }
        #else
            (editor as? any UITextInput)?.unmarkText()
        #endif
        return snapshot()
    }

    #if os(iOS)
        private func observeUIKitSelection() {
            guard let editor = resolveEditor() as? UITextView, editor.isFirstResponder else { return }
            let selection = editor.selectedRange
            let marked = editor.markedTextRange.map {
                NSRange(location: editor.offset(from: editor.beginningOfDocument, to: $0.start),
                    length: editor.offset(from: $0.start, to: $0.end))
            }
            guard selection != lastSelection || marked != lastMarkedRange else { return }
            lastSelection = selection
            lastMarkedRange = marked
            input?.nativeInputChanged()
        }
    #endif

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
                self.observeMentionStorage(editor.textStorage)
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
                    [36, 76, 125, 126, 53].contains(event.keyCode),
                    let editor = self.resolveEditor(), self.window?.firstResponder === editor
                else { return event }
                // Inspect before native dispatch: candidate confirmation can
                // unmark and invoke SwiftUI onSubmit in the very same event.
                // macOS submission belongs only to this monitor, not onSubmit.
                if editor.hasMarkedText() {
                    self.input?.nativeInputChanged()
                    return event
                }
                if self.input?.isComposing == true { return event }
                let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
                if modifiers.isEmpty {
                    let key: ComposerMentionKey
                    switch event.keyCode {
                    case 125: key = .down
                    case 126: key = .up
                    case 53: key = .dismiss
                    default: key = .accept
                    }
                    self.input?.refreshMentionQuery()
                    if self.input?.onMentionKey?(key) == true { return nil }
                }
                guard event.keyCode == 36 || event.keyCode == 76 else { return event }
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
            observeMentionStorage(candidate.textStorage)
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
            editor.hasMarkedText() ? .marked : .committed(ComposerMentionText.wireText(mentionSnapshot(editor.string)))
        }

        func insertNewline() -> Bool {
            guard let editor = resolveEditor(), !editor.hasMarkedText() else { return false }
            editor.insertNewlineIgnoringFieldEditor(nil)
            return true
        }

        @objc private func nativeChanged(_ notification: Notification) {
            guard !changingMentionStorage else { return }
            if notification.name == NSText.didEndEditingNotification,
                let ended = notification.object as? NSTextView, owns(ended)
            {
                // Copy before AppKit releases/reuses the shared editor. The queued
                // settlement can finish after firstResponder has changed.
                input?.nativeEditingEnded(snapshot(of: ended), visibleText: mentionSnapshot(ended.string))
                if let mentionStorage {
                    NotificationCenter.default.removeObserver(self, name: NSTextStorage.willProcessEditingNotification, object: mentionStorage)
                }
                mentionStorage = nil
                trackedSpans = []
                editor = nil
                editorOwner = nil
                return
            }
            guard let editor = resolveEditor(), notification.object as? NSTextView === editor else { return }
            observeMentionStorage(editor.textStorage)
            input?.nativeInputChanged(isEdit: notification.name == NSText.didChangeNotification)
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
            // UIKit exposes selection changes only through its text delegate,
            // which belongs to SwiftUI. Observe the native selection at run-loop
            // boundaries instead; this also catches selection-only caret moves.
            selectionObserver = CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 0
            ) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.observeUIKitSelection() }
            }
            if let selectionObserver { CFRunLoopAddObserver(CFRunLoopGetMain(), selectionObserver, .commonModes) }
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
            observeMentionStorage((candidate as? UITextView)?.textStorage)
            updateImagePasteSupport(for: candidate)
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
            return .committed(ComposerMentionText.wireText(mentionSnapshot(text)))
        }

        // Preserve UIKit's native behavior until hardware dispatch is verified.
        func insertNewline() -> Bool { false }

        // SwiftUI's image paste command requires iOS 27. Extend the existing
        // editor's paste configuration on older systems without replacing its
        // text delegate, selection, undo handling or IME editing model.
        func updateImagePasteSupport() {
            if let editor = resolveEditor() { updateImagePasteSupport(for: editor) }
        }

        private func updateImagePasteSupport(for view: UIView) {
            guard onPasteImages != nil, isComposerEnabled,
                  let target = view as? any UITextPasteConfigurationSupporting else {
                restoreImagePasteSupport()
                return
            }
            guard pasteEditor !== target else { return }
            restoreImagePasteSupport()
            pasteEditor = target
            previousPasteDelegate = target.pasteDelegate
            previousPasteConfiguration = target.pasteConfiguration
            let types = target.pasteConfiguration?.acceptableTypeIdentifiers ?? [UTType.text.identifier]
            target.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: types + [UTType.image.identifier])
            target.pasteDelegate = self
        }

        private func restoreImagePasteSupport() {
            if let target = pasteEditor, target.pasteDelegate === self {
                target.pasteDelegate = previousPasteDelegate
                target.pasteConfiguration = previousPasteConfiguration
            }
            pasteEditor = nil
            previousPasteDelegate = nil
            previousPasteConfiguration = nil
        }

        @objc private func nativeChanged(_ notification: Notification) {
            guard !changingMentionStorage else { return }
            if notification.name == UITextField.textDidEndEditingNotification
                || notification.name == UITextView.textDidEndEditingNotification,
                let ended = notification.object as? UIView, ended === editor
            {
                input?.nativeEditingEnded(snapshot(of: ended),
                    visibleText: (ended as? UITextView).map { mentionSnapshot($0.text) })
                if let mentionStorage {
                    NotificationCenter.default.removeObserver(self, name: NSTextStorage.willProcessEditingNotification, object: mentionStorage)
                }
                mentionStorage = nil
                trackedSpans = []
                restoreImagePasteSupport()
                editor = nil
                return
            }
            guard let editor = resolveEditor(), notification.object as? UIView === editor else { return }
            observeMentionStorage((editor as? UITextView)?.textStorage)
            input?.nativeInputChanged(isEdit: notification.name == UITextView.textDidChangeNotification
                || notification.name == UITextField.textDidChangeNotification)
        }
    #endif
}

#if os(iOS)
extension ComposerInputMarker: UITextPasteDelegate {
    func textPasteConfigurationSupporting(_ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting, transform item: any UITextPasteItem) {
        guard item.itemProvider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            if previousPasteDelegate?.textPasteConfigurationSupporting?(textPasteConfigurationSupporting, transform: item) == nil {
                item.setDefaultResult()
            }
            return
        }
        item.setNoResult()
        guard isComposerEnabled, onPasteImages != nil else { return }
        pendingPastedImages.append(item.itemProvider)
        guard pendingPastedImages.count == 1 else { return }
        // Batch images from one paste before opening the attachment dialog.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let providers = self.pendingPastedImages
            self.pendingPastedImages.removeAll()
            guard self.isComposerEnabled, !providers.isEmpty else { return }
            self.onPasteImages?(providers)
        }
    }
}

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

/// A presented iPad sheet can overlap the keyboard without receiving a reduced
/// SwiftUI proposal. This background measures the keyboard in the already-proposed
/// dialog bounds, so only residual overlap is reserved, including IME candidates
/// and floating keyboards. It never owns focus or changes the text editor.
struct ComposerKeyboardAvoidance: UIViewRepresentable {
    var onOverlapChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> KeyboardView { KeyboardView() }
    func updateUIView(_ view: KeyboardView, context: Context) {
        view.onOverlapChange = onOverlapChange
    }

    final class KeyboardView: UIView {
        var onOverlapChange: ((CGFloat) -> Void)?
        private let keyboardFrame = UIView()
        private var reportedOverlap: CGFloat = -1

        init() {
            super.init(frame: .zero)
            keyboardLayoutGuide.followsUndockedKeyboard = true
            // SwiftUI already accounts for container safe areas. When dismissed,
            // the guide must collapse at our bounds bottom, not above it.
            keyboardLayoutGuide.usesBottomSafeArea = false
            keyboardFrame.translatesAutoresizingMaskIntoConstraints = false
            addSubview(keyboardFrame)
            NSLayoutConstraint.activate([
                keyboardFrame.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
                keyboardFrame.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.bottomAnchor),
                keyboardFrame.leadingAnchor.constraint(equalTo: keyboardLayoutGuide.leadingAnchor),
                keyboardFrame.trailingAnchor.constraint(equalTo: keyboardLayoutGuide.trailingAnchor),
            ])
        }

        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard window != nil else { return }
            let intersection = bounds.intersection(keyboardFrame.frame)
            // Both rectangles are local to this view. Subtracting safeAreaInsets
            // here would leave that strip of the caption behind the keyboard.
            // An empty intersection also covers dismissal and floating keyboards
            // outside the sheet; neither should reserve any bottom space.
            let overlap = intersection.isEmpty ? 0 : max(0, bounds.maxY - intersection.minY)
            guard abs(overlap - reportedOverlap) > 0.5 else { return }
            reportedOverlap = overlap
            DispatchQueue.main.async { [weak self] in self?.onOverlapChange?(overlap) }
        }
    }
}
#endif
