#if os(macOS)
    import AppKit

    /// AppKit owns the fixed header and no-wrap selectable code viewport inside
    /// one measured attachment. A SwiftUI subtree cannot share this TextKit
    /// selection graph or its recycled native layout without remeasurement.
    final class MessageCodeScrollView: NSScrollView {
        private let codeView: NSTextView
        private let languageLabel = NSTextField(labelWithString: "")
        let copyButton = MessageCodeCopyButton()
        private let copyController = MessageCodeCopyController()
        private var attachment: MessageCodeAttachment?

        override var isFlipped: Bool { true }

        override func resetCursorRects() {
            super.resetCursorRects()
            guard let attachment else { return }
            addCursorRect(
                CGRect(x: 0, y: 0, width: bounds.width, height: attachment.headerHeight),
                cursor: .arrow)
        }

        init() {
            let storage = NSTextStorage()
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 1_000_000, height: 1_000_000))
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            codeView = NSTextView(frame: .zero, textContainer: container)
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 8
            layer?.masksToBounds = true
            drawsBackground = true
            // The scroll view paints the code surface. NSClipView's default
            // opaque backing otherwise covers it (and white sent code disappears).
            contentView.drawsBackground = false
            hasHorizontalScroller = true
            hasVerticalScroller = false
            autohidesScrollers = true
            scrollerStyle = .overlay
            borderType = .noBorder
            codeView.isEditable = false
            codeView.isSelectable = true
            codeView.isRichText = true
            codeView.drawsBackground = false
            codeView.textContainerInset = CGSize(
                width: MessageCodeAttachment.horizontalPadding,
                height: MessageCodeAttachment.verticalPadding)
            codeView.isHorizontallyResizable = false
            codeView.isVerticallyResizable = false
            codeView.setAccessibilityLabel(AppLanguage.localized("Code"))
            languageLabel.lineBreakMode = .byTruncatingTail
            languageLabel.maximumNumberOfLines = 1
            copyButton.isBordered = false
            copyButton.imagePosition = .imageOnly
            copyButton.imageScaling = .scaleProportionallyDown
            copyButton.target = self
            copyButton.action = #selector(copyCode)
            documentView = codeView
            addSubview(languageLabel)
            addSubview(copyButton)
            copyController.onChange = { [weak self] in self?.updateCopyFeedback() }
            updateCopyFeedback()
        }

        required init?(coder: NSCoder) { nil }

        func apply(
            _ attachment: MessageCodeAttachment, allowsSelection: Bool = true,
            copyEnabled: Bool = true
        ) {
            backgroundColor = attachment.backgroundColor
            languageLabel.font = attachment.headerFont
            languageLabel.textColor = attachment.headerForeground
            copyButton.contentTintColor = attachment.headerForeground
            if codeView.isSelectable != allowsSelection { codeView.isSelectable = allowsSelection }
            copyController.isEnabled = copyEnabled
            copyButton.isEnabled = copyEnabled
            if self.attachment !== attachment {
                codeView.textStorage?.setAttributedString(attachment.attributedCode)
                languageLabel.stringValue = attachment.language ?? ""
                self.attachment = attachment
                window?.invalidateCursorRects(for: self)
                // Replacing NSTextStorage can move AppKit's insertion point to the
                // end of the new string. Reset after replacement, never before it.
                resetInteraction()
            }
            let frame = CGRect(origin: .zero, size: attachment.codeSize)
            if codeView.frame != frame { codeView.frame = frame }
            tile()
            needsLayout = true
            needsDisplay = true
        }

        override func tile() {
            super.tile()
            guard let attachment else { return }
            let height = attachment.headerHeight
            // Keep the original NSScrollView as the wheel/selection owner. Reserve
            // a fixed header by tiling its native clip below non-scrolling controls,
            // rather than nesting another scroll view behind a wrapper.
            var clip = contentView.frame
            clip.origin.y += height
            clip.size.height = max(0, clip.height - height)
            if contentView.frame != clip { contentView.frame = clip }
            let buttonWidth = min(24, bounds.width)
            copyButton.frame = CGRect(
                x: max(0, bounds.width - buttonWidth - 2), y: 0,
                width: buttonWidth, height: height)
            let labelHeight = min(height, ceil(languageLabel.intrinsicContentSize.height))
            languageLabel.frame = CGRect(
                x: 6, y: (height - labelHeight) / 2,
                width: max(0, copyButton.frame.minX - 8 - 6), height: labelHeight)
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if let attachment {
                attachment.backgroundColor.setFill()
                bounds.fill()
                attachment.headerBackground.setFill()
                CGRect(x: 0, y: 0, width: bounds.width, height: attachment.headerHeight).fill()
            }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        @objc private func copyCode() {
            guard let attachment else { return }
            copyController.copy(attachment.code)
        }

        private func updateCopyFeedback() {
            copyButton.image = NSImage(
                systemSymbolName: copyController.status.symbol,
                accessibilityDescription: copyController.status.label
            )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
            copyButton.setAccessibilityLabel(copyController.status.label)
            copyButton.toolTip = copyController.status.label
        }

        func resetInteraction() {
            copyController.reset()
            let empty = NSRange(location: 0, length: 0)
            if codeView.selectedRange() != empty { codeView.setSelectedRange(empty) }
            if contentView.bounds.origin != .zero {
                contentView.scroll(to: .zero)
                reflectScrolledClipView(contentView)
            }
        }

        func clear() {
            resetInteraction()
            attachment = nil
            copyController.isEnabled = false
            copyButton.isEnabled = false
            languageLabel.stringValue = ""
            codeView.textStorage?.setAttributedString(NSAttributedString(string: ""))
            codeView.frame = .zero
        }
    }

    /// Secondary/control clicks on copy never become a message context gesture.
    /// The timeline's local event monitor recognizes this target before the row.
    final class MessageCodeCopyButton: NSButton {
        override func rightMouseDown(with event: NSEvent) {}
        override func menu(for event: NSEvent) -> NSMenu? { nil }
        override func mouseDown(with event: NSEvent) {
            guard !event.modifierFlags.contains(.control) else { return }
            super.mouseDown(with: event)
        }
    }
#endif
