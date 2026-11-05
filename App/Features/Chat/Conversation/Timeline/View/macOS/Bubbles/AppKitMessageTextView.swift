#if os(macOS)
    import AppKit

    extension MessageTextContent.Coordinator: NSTextViewDelegate {
        func textView(
            _ textView: NSTextView,
            willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange,
            toCharacterRange newSelectedCharRange: NSRange
        ) -> NSRange {
            layout?.selectableRange(newSelectedCharRange, previous: oldSelectedCharRange)
                ?? newSelectedCharRange
        }

        func textView(
            _ textView: NSTextView,
            willChangeSelectionFromCharacterRanges oldSelectedCharRanges: [NSValue],
            toCharacterRanges newSelectedCharRanges: [NSValue]
        ) -> [NSValue] {
            guard let layout else { return newSelectedCharRanges }
            return newSelectedCharRanges.enumerated().map { index, value in
                let previous =
                    index < oldSelectedCharRanges.count
                    ? oldSelectedCharRanges[index].rangeValue : value.rangeValue
                return NSValue(range: layout.selectableRange(value.rangeValue, previous: previous))
            }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let storage = textView.textStorage { activateLink(in: storage, at: charIndex) }
            // Never let AppKit open a URL itself, including after a handler is removed.
            return true
        }
    }

    final class AppKitMessageTextView: NSTextView {
        private let coordinator = MessageTextContent.Coordinator()
        let contentLayout: MessageTextLayout
        var allowsContextMenu = true
        override func menu(for event: NSEvent) -> NSMenu? {
            allowsContextMenu ? super.menu(for: event) : nil
        }
        var failureAction: (() -> Void)? {
            didSet { updateFailureButton() }
        }
        private var failureButton: NSButton?
        private let statusView = TimelineDeliveryStatusView(frame: .zero)
        private var codeViews: [Int: MessageCodeScrollView] = [:]
        private var copyEnabled = true
        // Keep only a small number of empty TextKit/scroll graphs between rows.
        // They retain neither message text nor selection, unlike a payload cache.
        private var reusableCodeViews: [MessageCodeScrollView] = []
        private let spoilerAnimator = MessageSpoilerAnimator()

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
            addSubview(statusView)
            coordinator.spoilerChanged = { [weak self] in
                guard let self else { return }
                let selections = self.selectedRanges
                let safe = selections.map {
                    NSValue(
                        range: self.contentLayout.selectableRange(
                            $0.rangeValue, previous: $0.rangeValue))
                }
                if safe != selections { self.selectedRanges = safe }
                self.needsDisplay = true
                self.updateSpoilerAnimation()
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(updateSpoilerAnimation),
                name: NSApplication.didBecomeActiveNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(stopSpoilerAnimation),
                name: NSApplication.willResignActiveNotification, object: nil)
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: NSSize { contentLayout.assignedSize }

        /// Native cells own their TextKit graph: the shared engine supplies geometry,
        /// while this coordinator keeps callbacks current without replacing selection.
        func apply(_ content: MessageTextContent, resetSelection: Bool) {
            if resetSelection {
                contentLayout.layoutManager.revealedSpoilers.removeAll()
                // A row identity change resets interaction even when prepared text
                // supplies the very same attachment object. Keep the native graphs.
                for view in codeViews.values { view.resetInteraction() }
            }
            let selection = selectedRange()
            let geometryChanged = content.update(contentLayout, coordinator: coordinator)
            let copyPolicyChanged = copyEnabled != content.copyEnabled
            copyEnabled = content.copyEnabled
            let length = contentLayout.storage.length
            if resetSelection {
                let empty = NSRange(location: 0, length: 0)
                if selectedRange() != empty { setSelectedRange(empty) }
            } else if selection.location != NSNotFound {
                let location = min(selection.location, length)
                let clamped = NSRange(
                    location: location, length: min(selection.length, length - location))
                if selectedRange() != clamped { setSelectedRange(clamped) }
            }
            failureAction = content.failureAction
            statusView.configure(contentLayout.metadata)
            if geometryChanged { needsLayout = true }
            needsDisplay = true
            if geometryChanged || resetSelection || copyPolicyChanged { updateCodeViews() }
            updateSpoilerAnimation()
        }

        func clear() {
            coordinator.openLink = nil
            coordinator.openMention = nil
            coordinator.textInput = nil
            coordinator.document = nil
            contentLayout.layoutManager.revealedSpoilers.removeAll()
            spoilerAnimator.stop()
            for view in codeViews.values { recycleCodeView(view) }
            codeViews.removeAll(keepingCapacity: true)
            failureAction = nil
            contentLayout.update(attributedText: NSAttributedString(string: ""), metadata: nil)
            statusView.configure(nil)
            let empty = NSRange(location: 0, length: 0)
            if selectedRange() != empty { setSelectedRange(empty) }
            needsDisplay = true
        }

        func setVisible(_ visible: Bool) {
            statusView.setVisible(visible)
        }

        override func copy(_ sender: Any?) {
            let selections = selectedRanges
            let safe = selections.map {
                NSValue(
                    range: contentLayout.selectableRange($0.rangeValue, previous: $0.rangeValue))
            }
            if safe != selections { selectedRanges = safe }
            guard safe.contains(where: { $0.rangeValue.length > 0 }) else { return }
            super.copy(sender)
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if let index = interactiveCharacterIndex(at: point),
                contentLayout.layoutManager.isConcealed(at: index)
                    || textStorage?.attribute(.link, at: index, effectiveRange: nil) == nil,
                coordinator.toggleSpoiler(at: index)
            {
                return
            }
            super.mouseDown(with: event)
        }

        private func interactiveCharacterIndex(at point: CGPoint) -> Int? {
            guard let manager = layoutManager, let container = textContainer,
                let storage = textStorage, storage.length > 0
            else { return nil }
            let index = manager.characterIndex(
                for: point, in: container,
                fractionOfDistanceBetweenInsertionPoints: nil)
            guard index < storage.length else { return nil }
            let glyphs = manager.glyphRange(
                forCharacterRange: NSRange(location: index, length: 1),
                actualCharacterRange: nil)
            return manager.boundingRect(forGlyphRange: glyphs, in: container).contains(point)
                ? index : nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateSpoilerAnimation()
        }

        override func viewDidHide() {
            super.viewDidHide()
            spoilerAnimator.stop()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            updateSpoilerAnimation()
        }

        @objc private func stopSpoilerAnimation() { spoilerAnimator.stop() }

        @objc private func updateSpoilerAnimation() {
            guard window != nil, !isHiddenOrHasHiddenAncestor, NSApp.isActive,
                !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                contentLayout.layoutManager.hasConcealedSpoilers
            else {
                spoilerAnimator.stop()
                return
            }
            spoilerAnimator.start { [weak self] in
                guard let self else { return }
                self.contentLayout.layoutManager.particlePhase += 1.0 / 24
                self.needsDisplay = true
            }
        }

        private func updateCodeViews() {
            // Applied geometry is authoritative, so synchronize here rather than
            // repeating attachment lookup and code-view updates on every native layout.
            let blocks = contentLayout.codeBlocks
            let indices = Set(blocks.map { $0.0.characterIndex })
            for index in Array(codeViews.keys) where !indices.contains(index) {
                if let view = codeViews.removeValue(forKey: index) { recycleCodeView(view) }
            }
            for (geometry, attachment) in blocks {
                let view: MessageCodeScrollView
                if let existing = codeViews[geometry.characterIndex] {
                    view = existing
                } else {
                    view = reusableCodeViews.popLast() ?? MessageCodeScrollView()
                    codeViews[geometry.characterIndex] = view
                    if view.superview == nil { addSubview(view) }
                }
                view.isHidden = false
                if view.frame != geometry.frame { view.frame = geometry.frame }
                view.apply(
                    attachment, allowsSelection: isSelectable, copyEnabled: copyEnabled)
            }
        }

        private func recycleCodeView(_ view: MessageCodeScrollView) {
            view.clear()
            view.isHidden = true
            if reusableCodeViews.count < 4 {
                reusableCodeViews.append(view)
            } else {
                view.removeFromSuperview()
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }

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
                button.setButtonType(.momentaryPushIn)
                button.target = self
                button.action = #selector(openFailureOptions)
                button.setAccessibilityLabel(AppLanguage.localized("Failed to send. Retry options"))
                button.setAccessibilityElement(true)
                addSubview(button)
                failureButton = button
            }
            button.isHidden = false
            needsLayout = true
        }

        @objc private func openFailureOptions() {
            guard contentLayout.metadata?.state == .failed else { return }
            failureAction?()
        }

        override func layout() {
            super.layout()
            guard let geometry = contentLayout.assignedGeometry else { return }

            let frame = contentLayout.metadata?.statusFrame(in: geometry.metadataFrame) ?? .zero
            statusView.frame = frame
            failureButton?.frame = frame
        }

        override func draw(_ dirtyRect: NSRect) {
            // NSTextView leaves the context clipped to the narrower body container.
            // Restore it before drawing metadata in the footer's trailing outset.
            NSGraphicsContext.saveGraphicsState()
            super.draw(dirtyRect)
            NSGraphicsContext.restoreGraphicsState()
            guard let geometry = contentLayout.assignedGeometry else { return }
            effectiveAppearance.performAsCurrentDrawingAppearance {
                contentLayout.metadata?.draw(in: geometry.metadataFrame)
            }
        }

        override func accessibilityValue() -> String? {
            guard let metadata = contentLayout.metadata else {
                return contentLayout.accessibilityText
            }
            return "\(contentLayout.accessibilityText) \(metadata.accessibilityLabel)"
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
