import SwiftUI

#if os(iOS)
import UIKit

struct NativeComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let maxHeight: CGFloat
    let isEnabled: Bool
    let onSubmit: () -> Void
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 15

    func makeUIView(context: Context) -> ComposerUITextView {
        let view = ComposerUITextView()
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: ComposerUITextView, context: Context) {
        context.coordinator.parent = self
        view.onSubmit = onSubmit
        view.editingEnabled = isEnabled
        view.maximumHeight = maxHeight
        view.requestedFontSize = fontSize
        view.applyTypography()
        view.applyExternalText(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerUITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeComposerTextView

        init(parent: NativeComposerTextView) { self.parent = parent }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            parent.isEnabled
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let view = textView as? ComposerUITextView else { return }
            view.contentDidChange()
            if view.pendingExternalText == nil, parent.text != view.text { parent.text = view.text }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            guard let view = textView as? ComposerUITextView else { return }
            view.updateEditingAvailability()
        }
    }
}

final class ComposerUITextView: UITextView {
    var onSubmit: (() -> Void)?
    var editingEnabled = true {
        didSet { updateEditingAvailability() }
    }
    var maximumHeight: CGFloat = 36 {
        didSet {
            guard maximumHeight != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }
    var requestedFontSize: CGFloat = 15
    private(set) var pendingExternalText: String?
    private var appliedFontSize: CGFloat?

    private let placeholder = UILabel()
    private var measuredWidth: CGFloat?
    private var contentHeight: CGFloat = 36
    private var consumedPresses = Set<UIPress>()
    private var needsSelectionVisibility = false

    init() {
        super.init(frame: .zero, textContainer: nil)
        backgroundColor = .clear
        textColor = .label
        textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 4)
        textContainer.lineFragmentPadding = 0
        contentInsetAdjustmentBehavior = .never
        isScrollEnabled = false
        alwaysBounceVertical = false
        showsHorizontalScrollIndicator = false
        allowsEditingTextAttributes = false
        returnKeyType = .default
        accessibilityLabel = String(localized: "Message")
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        placeholder.textColor = .placeholderText
        placeholder.isUserInteractionEnabled = false
        placeholder.isAccessibilityElement = false
        addSubview(placeholder)
        applyTypography()
    }

    required init?(coder: NSCoder) { nil }

    func updateEditingAvailability() {
        // Keep the current first responder through the local commit. The delegate
        // rejects edits while disabled, without dismissing and reopening the keyboard.
        isEditable = editingEnabled || isFirstResponder
        if editingEnabled {
            accessibilityTraits.remove(.notEnabled)
        } else {
            accessibilityTraits.insert(.notEnabled)
        }
    }

    func applyTypography() {
        guard markedTextRange == nil, appliedFontSize != requestedFontSize else { return }
        appliedFontSize = requestedFontSize
        let newFont = UIFont.systemFont(ofSize: requestedFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = requestedFontSize * 1.3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: newFont, .foregroundColor: UIColor.label, .paragraphStyle: paragraph,
        ]
        font = newFont
        typingAttributes = attributes
        if textStorage.length > 0 {
            textStorage.addAttributes(attributes, range: NSRange(location: 0, length: textStorage.length))
        }
        placeholder.attributedText = NSAttributedString(string: String(localized: "Message"), attributes: [
            .font: newFont, .foregroundColor: UIColor.placeholderText, .paragraphStyle: paragraph,
        ])
        invalidateMeasurement()
    }

    func applyExternalText(_ newText: String) {
        guard text != newText else {
            pendingExternalText = nil
            return
        }
        // Defer external updates until the input method releases its marked range.
        guard markedTextRange == nil else {
            pendingExternalText = newText
            return
        }
        pendingExternalText = nil
        let selection = selectedRange
        attributedText = NSAttributedString(string: newText, attributes: typingAttributes)
        let length = (newText as NSString).length
        let location = min(selection.location, length)
        selectedRange = NSRange(location: location, length: min(selection.length, length - location))
        contentDidChange()
    }

    func contentDidChange() {
        if markedTextRange == nil, let pendingExternalText {
            applyExternalText(pendingExternalText)
            return
        }
        applyTypography()
        placeholder.isHidden = !text.isEmpty
        needsSelectionVisibility = true
        invalidateMeasurement()
    }

    override func unmarkText() {
        super.unmarkText()
        contentDidChange()
    }

    private var minimumHeight: CGFloat {
        ceil(max(36, requestedFontSize * 1.3 + 16))
    }

    private var heightLimit: CGFloat { max(minimumHeight, maximumHeight) }

    private func invalidateMeasurement() {
        measuredWidth = nil
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func measure(width: CGFloat) -> CGFloat {
        guard width > 0 else { return minimumHeight }
        if measuredWidth != width {
            contentHeight = ceil(max(minimumHeight, super.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height))
            measuredWidth = width
        }
        return min(contentHeight, heightLimit)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: measure(width: bounds.width))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: measure(width: size.width))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let widthChanged = measuredWidth != bounds.width
        _ = measure(width: bounds.width)
        let shouldScroll = contentHeight > heightLimit
        if isScrollEnabled != shouldScroll { isScrollEnabled = shouldScroll }
        placeholder.frame = CGRect(x: 12, y: 8, width: max(0, bounds.width - 16), height: minimumHeight - 16)
        if widthChanged { invalidateIntrinsicContentSize() }
        if needsSelectionVisibility, isFirstResponder {
            needsSelectionVisibility = false
            if shouldScroll { scrollRangeToVisible(selectedRange) }
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard markedTextRange == nil else {
            super.pressesBegan(presses, with: event)
            return
        }
        var unhandled = presses
        for press in presses {
            guard let key = press.key,
                  key.keyCode == .keyboardReturnOrEnter || key.keyCode == .keypadEnter,
                  key.modifierFlags.intersection([.shift, .control, .alternate, .command]).isEmpty else { continue }
            unhandled.remove(press)
            consumedPresses.insert(press)
            if editingEnabled { onSubmit?() }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.subtracting(consumedPresses)
        consumedPresses.subtract(presses)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.subtracting(consumedPresses)
        consumedPresses.subtract(presses)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }
}

#elseif os(macOS)
import AppKit

struct NativeComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let maxHeight: CGFloat
    let isEnabled: Bool
    let onSubmit: () -> Void
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 15

    func makeNSView(context: Context) -> ComposerScrollView {
        let view = ComposerScrollView()
        view.editor.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: ComposerScrollView, context: Context) {
        context.coordinator.parent = self
        view.maximumHeight = maxHeight
        view.editor.editingEnabled = isEnabled
        view.editor.requestedFontSize = fontSize
        view.editor.applyTypography()
        view.editor.applyExternalText(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        return CGSize(width: width, height: nsView.measuredHeight(for: width))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposerTextView

        init(parent: NativeComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? ComposerNSTextView else { return }
            view.contentDidChange()
            if view.pendingExternalText == nil, parent.text != view.string { parent.text = view.string }
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let view = notification.object as? ComposerNSTextView else { return }
            view.updateEditingAvailability()
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            parent.isEnabled
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let view = textView as? ComposerNSTextView,
                  !view.hasMarkedText(), !view.isHandlingMarkedKey else { return false }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                textView.window?.makeFirstResponder(nil)
                return true
            }
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let modifiers = NSApp.currentEvent?.modifierFlags.intersection([.shift, .control, .option, .command]) ?? []
            guard modifiers.isEmpty else { return false }
            if parent.isEnabled { parent.onSubmit() }
            return true
        }
    }
}

final class ComposerScrollView: NSScrollView {
    let editor = ComposerNSTextView()
    var maximumHeight: CGFloat = 36 {
        didSet {
            guard maximumHeight != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }
    private var measuredWidth: CGFloat?
    private var contentHeight: CGFloat = 36
    private var needsSelectionVisibility = false

    init() {
        super.init(frame: .zero)
        borderType = .noBorder
        drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none
        documentView = editor
        editor.contentChanged = { [weak self] in self?.invalidateMeasurement() }
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    private var minimumHeight: CGFloat {
        ceil(max(36, editor.requestedFontSize * 1.3 + 16))
    }

    private var heightLimit: CGFloat { max(minimumHeight, maximumHeight) }

    private func invalidateMeasurement() {
        measuredWidth = nil
        needsSelectionVisibility = true
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func measuredHeight(for width: CGFloat) -> CGFloat {
        guard width > 0, let container = editor.textContainer, let layout = editor.layoutManager else { return minimumHeight }
        if measuredWidth != width {
            container.containerSize = NSSize(width: max(1, width - 16), height: .greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            var bodyHeight = layout.usedRect(for: container).maxY
            if layout.extraLineFragmentTextContainer === container {
                bodyHeight = max(bodyHeight, layout.extraLineFragmentRect.maxY)
            }
            contentHeight = ceil(max(minimumHeight, bodyHeight + 16))
            measuredWidth = width
        }
        return min(contentHeight, heightLimit)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight(for: bounds.width))
    }

    override func layout() {
        super.layout()
        let width = contentSize.width
        let widthChanged = measuredWidth != width
        _ = measuredHeight(for: width)
        let shouldScroll = contentHeight > heightLimit
        if hasVerticalScroller != shouldScroll { hasVerticalScroller = shouldScroll }
        verticalScrollElasticity = shouldScroll ? .automatic : .none
        editor.frame = NSRect(x: 0, y: 0, width: width, height: max(contentSize.height, contentHeight))
        if widthChanged { invalidateIntrinsicContentSize() }
        if needsSelectionVisibility, window?.firstResponder === editor {
            needsSelectionVisibility = false
            editor.scrollRangeToVisible(editor.selectedRange())
        }
    }
}

final class ComposerNSTextView: NSTextView {
    var contentChanged: (() -> Void)?
    var requestedFontSize: CGFloat = 15
    var editingEnabled = true {
        didSet { updateEditingAvailability() }
    }
    private(set) var pendingExternalText: String?
    private var appliedFontSize: CGFloat?
    private(set) var isHandlingMarkedKey = false
    private var placeholderAttributes: [NSAttributedString.Key: Any] = [:]

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        drawsBackground = false
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isEditable = true
        isSelectable = true
        isHorizontallyResizable = false
        isVerticallyResizable = false
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = NSSize(width: 0, height: 8)
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        setAccessibilityLabel(String(localized: "Message"))
        applyTypography()
    }

    required init?(coder: NSCoder) { nil }

    override var textContainerOrigin: NSPoint { NSPoint(x: 12, y: 8) }

    func updateEditingAvailability() {
        isEditable = editingEnabled || window?.firstResponder === self
        setAccessibilityEnabled(editingEnabled)
    }

    func applyTypography() {
        guard !hasMarkedText(), appliedFontSize != requestedFontSize else { return }
        appliedFontSize = requestedFontSize
        let newFont = NSFont.systemFont(ofSize: requestedFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = requestedFontSize * 1.3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: newFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]
        font = newFont
        defaultParagraphStyle = paragraph
        typingAttributes = attributes
        if let textStorage, textStorage.length > 0 {
            textStorage.addAttributes(attributes, range: NSRange(location: 0, length: textStorage.length))
        }
        placeholderAttributes = [.font: newFont, .foregroundColor: NSColor.placeholderTextColor, .paragraphStyle: paragraph]
        contentChanged?()
        needsDisplay = true
    }

    func applyExternalText(_ newText: String) {
        guard string != newText else {
            pendingExternalText = nil
            return
        }
        guard !hasMarkedText() else {
            pendingExternalText = newText
            return
        }
        pendingExternalText = nil
        let selections = selectedRanges
        textStorage?.setAttributedString(NSAttributedString(string: newText, attributes: typingAttributes))
        let length = (newText as NSString).length
        selectedRanges = selections.map { value in
            let range = value.rangeValue
            let location = min(range.location, length)
            return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
        }
        contentDidChange()
    }

    func contentDidChange() {
        if !hasMarkedText(), let pendingExternalText {
            applyExternalText(pendingExternalText)
            return
        }
        applyTypography()
        contentChanged?()
        needsDisplay = true
    }

    override func unmarkText() {
        super.unmarkText()
        contentDidChange()
    }

    override func keyDown(with event: NSEvent) {
        // IME confirmation can clear marked text before the delegate receives a
        // command. Remember composition at the start of this native key event.
        isHandlingMarkedKey = hasMarkedText()
        defer { isHandlingMarkedKey = false }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        (String(localized: "Message") as NSString).draw(
            in: NSRect(x: 12, y: 8, width: max(0, bounds.width - 16), height: bounds.height - 16),
            withAttributes: placeholderAttributes
        )
    }
}
#endif
