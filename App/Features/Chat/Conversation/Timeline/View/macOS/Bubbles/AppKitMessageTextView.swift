#if os(macOS)
    import AppKit

    extension MessageTextContent.Coordinator: NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let storage = textView.textStorage { activateLink(in: storage, at: charIndex) }
            // Never let AppKit open a URL itself, including after a handler is removed.
            return true
        }
    }

    final class AppKitMessageTextView: NSTextView {
        private let coordinator = MessageTextContent.Coordinator()
        let contentLayout: MessageTextLayout
        var failureAction: (() -> Void)? {
            didSet { updateFailureButton() }
        }
        private var failureButton: NSButton?

        init(geometry: MessageTextGeometry) {
            let layout = MessageTextLayout()
            layout.install(geometry: geometry)
            contentLayout = layout
            super.init(frame: .zero, textContainer: layout.textContainer)
            isEditable = false
            isSelectable = true
            isRichText = true
            drawsBackground = false
            textContainerInset = .zero
            isHorizontallyResizable = false
            isVerticallyResizable = false
            layout.textContainer.widthTracksTextView = false
            layout.textContainer.heightTracksTextView = false
            // Keep bubble colors, but retain AppKit's link cursor attribute so native
            // text selection and link hovering use the same cursor handling.
            linkTextAttributes = [.cursor: NSCursor.pointingHand]
            delegate = coordinator
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: NSSize { contentLayout.assignedSize }

        /// Native cells own their TextKit graph: the shared engine supplies geometry,
        /// while this coordinator keeps callbacks current without replacing selection.
        func apply(_ content: MessageTextContent, resetSelection: Bool) {
            let selection = selectedRange()
            let geometryChanged = content.update(contentLayout, coordinator: coordinator)
            let length = contentLayout.storage.length
            if resetSelection {
                setSelectedRange(NSRange(location: 0, length: 0))
            } else if selection.location != NSNotFound {
                let location = min(selection.location, length)
                let clamped = NSRange(
                    location: location, length: min(selection.length, length - location))
                if selectedRange() != clamped { setSelectedRange(clamped) }
            }
            failureAction = content.failureAction
            if geometryChanged { needsLayout = true }
            needsDisplay = true
        }

        func clear() {
            coordinator.openLink = nil
            coordinator.openMention = nil
            coordinator.textInput = nil
            failureAction = nil
            contentLayout.update(attributedText: NSAttributedString(string: ""), metadata: nil)
            setSelectedRange(NSRange(location: 0, length: 0))
            needsDisplay = true
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
        private func updateFailureButton() {
            guard failureAction != nil, let metadata = contentLayout.metadata,
                metadata.state == .failed
            else {
                failureButton?.isHidden = true
                return
            }
            let button: NSButton
            if let failureButton {
                button = failureButton
            } else {
                button = BubbleFailureButton(frame: .zero)
                button.title = ""
                button.isBordered = false
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleProportionallyUpOrDown
                button.setButtonType(.momentaryPushIn)
                button.target = self
                button.action = #selector(openFailureOptions)
                button.setAccessibilityLabel(String(localized: "Failed to send. Retry options"))
                button.setAccessibilityElement(true)
                addSubview(button)
                failureButton = button
            }
            button.isHidden = false
            button.image = metadata.symbol
            needsLayout = true
        }

        @objc private func openFailureOptions() {
            guard contentLayout.metadata?.state == .failed else { return }
            failureAction?()
        }

        override func layout() {
            super.layout()
            guard let geometry = contentLayout.assignedGeometry else { return }

            if let metadata = contentLayout.metadata {
                failureButton?.frame = metadata.symbolFrame(in: geometry.metadataFrame)
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let geometry = contentLayout.assignedGeometry else { return }
            effectiveAppearance.performAsCurrentDrawingAppearance {
                contentLayout.metadata?.draw(
                    in: geometry.metadataFrame, drawsSymbol: failureButton?.isHidden != false)
            }
        }

        override func accessibilityValue() -> String? {
            guard let metadata = contentLayout.metadata else { return super.accessibilityValue() }
            return "\(string) \(metadata.accessibilityLabel)"
        }

        override func accessibilityChildren() -> [Any]? {
            var children = super.accessibilityChildren() ?? []
            if let failureButton, !failureButton.isHidden,
                !children.contains(where: { ($0 as? NSView) === failureButton })
            {
                children.append(failureButton)
            }
            return children
        }
    }
    private final class BubbleFailureButton: NSButton {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
#endif
