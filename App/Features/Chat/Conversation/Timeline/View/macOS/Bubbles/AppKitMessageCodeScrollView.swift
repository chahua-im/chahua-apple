#if os(macOS)
    import AppKit

    /// AppKit supplies selection and trackpad horizontal scrolling inside the code
    /// slot. SwiftUI's text selection cannot share the bubble's TextKit geometry.
    final class MessageCodeScrollView: NSScrollView {
        private let codeView: NSTextView
        private var attachment: MessageCodeAttachment?

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
            drawsBackground = true
            hasHorizontalScroller = true
            hasVerticalScroller = false
            autohidesScrollers = true
            scrollerStyle = .overlay
            borderType = .noBorder
            wantsLayer = true
            layer?.cornerRadius = 8
            layer?.masksToBounds = true
            codeView.isEditable = false
            codeView.isSelectable = true
            codeView.isRichText = true
            codeView.drawsBackground = false
            codeView.textContainerInset = CGSize(
                width: MessageCodeAttachment.horizontalPadding,
                height: MessageCodeAttachment.verticalPadding)
            codeView.isHorizontallyResizable = false
            codeView.isVerticallyResizable = false
            codeView.textContainer?.widthTracksTextView = false
            codeView.textContainer?.heightTracksTextView = false
            codeView.textContainer?.containerSize = CGSize(width: 1_000_000, height: 1_000_000)
            codeView.setAccessibilityLabel("Code")
            documentView = codeView
        }

        required init?(coder: NSCoder) { nil }

        func apply(_ attachment: MessageCodeAttachment) {
            if backgroundColor != attachment.backgroundColor {
                backgroundColor = attachment.backgroundColor
            }
            if self.attachment !== attachment {
                codeView.textStorage?.setAttributedString(attachment.attributedCode)
                self.attachment = attachment
                resetInteraction()
            }
            let frame = CGRect(origin: .zero, size: attachment.naturalSize)
            if codeView.frame != frame { codeView.frame = frame }
        }

        func resetInteraction() {
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
            codeView.textStorage?.setAttributedString(NSAttributedString(string: ""))
            codeView.frame = .zero
        }
    }
#endif
