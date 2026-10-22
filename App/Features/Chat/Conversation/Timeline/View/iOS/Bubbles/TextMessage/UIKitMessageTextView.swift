#if os(iOS)
    import UIKit

    extension MessageTextContent.Coordinator: UITextViewDelegate {
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard let layout else { return }
            let selection = textView.selectedRange
            let safe = layout.selectableRange(selection, previous: previousSelection)
            previousSelection = safe
            if safe != selection { textView.selectedRange = safe }
        }

        @available(iOS 17.0, *)
        func textView(
            _ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction
        ) -> UIAction? {
            UIAction { [weak self, weak textView] _ in
                guard let textView else { return }
                self?.activateLink(in: textView.textStorage, at: textItem.range.location)
            }
        }

        @available(iOS 17.0, *)
        func textView(
            _ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu
        ) -> UITextItem.MenuConfiguration? {
            nil
        }
    }

    /// UIKit is required for native text selection and link interaction using the
    /// engine's TextKit geometry. A SwiftUI text subtree would remeasure the row and
    /// cannot retain this layout manager and selection across collection-cell binds.
    final class UIKitMessageTextView: UITextView {
        private let coordinator = MessageTextContent.Coordinator()
        let contentLayout: MessageTextLayout
        var failureAction: (() -> Void)? {
            didSet { updateFailureButton() }
        }
        var rowAccessibilityActions: [UIAccessibilityCustomAction]? {
            didSet { updateAccessibilityActions() }
        }
        private var failureButton: TimelineFailureButton?
        private let statusHost = TimelineDeliveryStatusHost(frame: .zero)
        private var codeViews: [Int: MessageCodeScrollView] = [:]
        private let spoilerAnimator = MessageSpoilerAnimator()
        /// A non-selectable UITextView does not activate links; this tap stands in for
        /// UIKit's link interaction while selection is off.
        private lazy var linkTap = UITapGestureRecognizer(
            target: self, action: #selector(activateTappedLink(_:)))

        /// Touch timelines show inert text so holds and swipes belong to the row; the
        /// action-menu preview turns selection on. macOS bubbles are always selectable.
        var allowsSelection = false {
            didSet {
                guard allowsSelection != oldValue else { return }
                if !allowsSelection {
                    resignFirstResponder()
                    selectedRange = NSRange(location: 0, length: 0)
                }
                isSelectable = allowsSelection
                // Spoilers remain tappable in the selectable action-menu preview.
                linkTap.isEnabled = true
                updateCodeViews()
            }
        }

        init(geometry: MessageTextGeometry) {
            let layout = MessageTextLayout()
            layout.install(geometry: geometry)
            contentLayout = layout
            // Supplying the shared TextKit 1 container keeps sizing and visible glyphs
            // on the same layout manager rather than UITextView's TextKit 2 default.
            super.init(frame: .zero, textContainer: layout.textContainer)
            isEditable = false
            isSelectable = allowsSelection
            isScrollEnabled = false
            backgroundColor = .clear
            isOpaque = false
            textContainerInset = .zero
            contentInset = .zero
            contentInsetAdjustmentBehavior = .never
            showsHorizontalScrollIndicator = false
            showsVerticalScrollIndicator = false
            alwaysBounceVertical = false
            delaysContentTouches = false
            dataDetectorTypes = []
            linkTextAttributes = [:]
            delegate = coordinator
            addGestureRecognizer(linkTap)
            addSubview(statusHost)
            coordinator.spoilerChanged = { [weak self] in
                guard let self else { return }
                let safe = self.contentLayout.selectableRange(
                    self.selectedRange, previous: self.selectedRange)
                if safe != self.selectedRange { self.selectedRange = safe }
                self.setNeedsDisplay()
                self.updateSpoilerAnimation()
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(updateSpoilerAnimation),
                name: UIApplication.didBecomeActiveNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(stopSpoilerAnimation),
                name: UIApplication.willResignActiveNotification, object: nil)
            layout.textContainer.widthTracksTextView = false
            layout.textContainer.heightTracksTextView = false
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            registerForTraitChanges([
                UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self,
                UITraitUserInterfaceLevel.self, UITraitDisplayGamut.self, UITraitDisplayScale.self,
            ]) { (view: UIKitMessageTextView, _: UITraitCollection) in
                view.setNeedsDisplay()
            }
        }

        required init?(coder: NSCoder) { nil }

        override var intrinsicContentSize: CGSize {
            contentLayout.assignedSize
        }

        override func sizeThatFits(_ size: CGSize) -> CGSize {
            contentLayout.assignedSize
        }

        func apply(_ content: MessageTextContent, resetSelection: Bool) {
            if resetSelection {
                contentLayout.layoutManager.revealedSpoilers.removeAll()
                for view in codeViews.values { view.removeFromSuperview() }
                codeViews.removeAll()
            }
            let selection = selectedRange
            let geometryChanged = content.update(contentLayout, coordinator: coordinator)
            let length = contentLayout.storage.length
            if resetSelection {
                resignFirstResponder()
                selectedRange = NSRange(location: 0, length: 0)
            } else if selection.location != NSNotFound {
                let location = min(selection.location, length)
                let clamped = NSRange(
                    location: location, length: min(selection.length, length - location))
                if selectedRange != clamped { selectedRange = clamped }
            }
            failureAction = content.failureAction
            statusHost.configure(contentLayout.metadata)
            if geometryChanged {
                setNeedsLayout()
                invalidateIntrinsicContentSize()
            }
            setNeedsDisplay()
            updateCodeViews()
            updateSpoilerAnimation()
        }

        func clear() {
            coordinator.openLink = nil
            coordinator.openMention = nil
            coordinator.textInput = nil
            coordinator.document = nil
            contentLayout.layoutManager.revealedSpoilers.removeAll()
            spoilerAnimator.stop()
            for view in codeViews.values { view.removeFromSuperview() }
            codeViews.removeAll()
            failureAction = nil
            statusHost.clear()
            rowAccessibilityActions = nil
            resignFirstResponder()
            contentLayout.update(attributedText: NSAttributedString(string: ""), metadata: nil)
            selectedRange = NSRange(location: 0, length: 0)
            setNeedsDisplay()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let geometry = contentLayout.assignedGeometry else { return }
            updateCodeViews()
            if let metadata = contentLayout.metadata {
                let frame = metadata.statusFrame(in: geometry.metadataFrame)
                statusHost.frame = frame
                bringSubviewToFront(statusHost)
                failureButton?.setStatusFrame(frame)
            }
            if let failureButton {
                bringSubviewToFront(failureButton)
            }
        }

        func setVisible(_ visible: Bool) {
            statusHost.setVisible(visible)
        }

        func hitTestFailureButton(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard let failureButton, !failureButton.isHidden else { return nil }
            return failureButton.hitTest(failureButton.convert(point, from: self), with: event)
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool
        {
            if gestureRecognizer === linkTap {
                return linkCharacterIndex(at: gestureRecognizer.location(in: self)) != nil
            }
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }

        override func copy(_ sender: Any?) {
            let safe = contentLayout.selectableRange(selectedRange, previous: selectedRange)
            if safe != selectedRange { selectedRange = safe }
            guard safe.length > 0 else { return }
            super.copy(sender)
        }

        @objc private func activateTappedLink(_ recognizer: UITapGestureRecognizer) {
            guard let index = linkCharacterIndex(at: recognizer.location(in: self)) else { return }
            if contentLayout.layoutManager.isConcealed(at: index)
                || textStorage.attribute(.link, at: index, effectiveRange: nil) == nil
            {
                if coordinator.toggleSpoiler(at: index) { return }
            }
            coordinator.activateLink(in: textStorage, at: index)
        }

        /// The character under `point` only when its glyph is actually hit and carries a link.
        private func linkCharacterIndex(at point: CGPoint) -> Int? {
            let storage = textStorage
            guard storage.length > 0 else { return nil }
            let location = CGPoint(
                x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
            let index = layoutManager.characterIndex(
                for: location, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
            guard index < storage.length else { return nil }
            let hasLink = storage.attribute(.link, at: index, effectiveRange: nil) != nil
            let hasSpoiler =
                storage.attribute(.bubbleSpoiler, at: index, effectiveRange: nil) != nil
            guard hasLink || hasSpoiler,
                !allowsSelection
                    || (hasSpoiler
                        && (!hasLink || contentLayout.layoutManager.isConcealed(at: index)))
            else { return nil }
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
            let bounds = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            return bounds.insetBy(dx: -4, dy: -4).contains(location) ? index : nil
        }

        override var isHidden: Bool {
            didSet {
                updateSpoilerAnimation()
                statusHost.isHidden = isHidden
            }
        }

        @objc private func stopSpoilerAnimation() { spoilerAnimator.stop() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateSpoilerAnimation()
        }

        @objc private func updateSpoilerAnimation() {
            guard window != nil, !isHidden, UIApplication.shared.applicationState == .active,
                !UIAccessibility.isReduceMotionEnabled,
                contentLayout.layoutManager.hasConcealedSpoilers
            else {
                spoilerAnimator.stop()
                return
            }
            spoilerAnimator.start { [weak self] in
                guard let self else { return }
                self.contentLayout.layoutManager.particlePhase += 1.0 / 24
                self.setNeedsDisplay()
            }
        }

        private func updateCodeViews() {
            let blocks = contentLayout.codeBlocks
            let indices = Set(blocks.map { $0.0.characterIndex })
            for index in Array(codeViews.keys) where !indices.contains(index) {
                codeViews.removeValue(forKey: index)?.removeFromSuperview()
            }
            for (geometry, attachment) in blocks {
                let view: MessageCodeScrollView
                if let existing = codeViews[geometry.characterIndex] {
                    view = existing
                } else {
                    view = MessageCodeScrollView()
                    codeViews[geometry.characterIndex] = view
                    addSubview(view)
                }
                view.frame = geometry.frame
                view.apply(attachment, allowsSelection: allowsSelection)
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        override func draw(_ rect: CGRect) {
            super.draw(rect)
            guard let geometry = contentLayout.assignedGeometry else { return }
            contentLayout.metadata?.draw(in: geometry.metadataFrame)
        }

        override var accessibilityValue: String? {
            get {
                guard let metadata = contentLayout.metadata else {
                    return contentLayout.accessibilityText
                }
                return "\(contentLayout.accessibilityText) \(metadata.accessibilityLabel)"
            }
            set { super.accessibilityValue = newValue }
        }

        private func updateFailureButton() {
            guard failureAction != nil, let metadata = contentLayout.metadata,
                metadata.state == .failed
            else {
                failureButton?.clear()
                failureButton?.isHidden = true
                updateAccessibilityActions()
                return
            }
            let button: TimelineFailureButton
            if let failureButton {
                button = failureButton
            } else {
                button = TimelineFailureButton(frame: .zero)
                button.onActivate = { [weak self] in self?.openFailureOptions() }
                addSubview(button)
                failureButton = button
            }
            updateAccessibilityActions()
            button.configure()
            button.isHidden = false
            setNeedsLayout()
        }

        private func updateAccessibilityActions() {
            // Keep native selectable text accessible, adding row and retry actions
            // without replacing its link/mention accessibility elements.
            var actions = rowAccessibilityActions ?? []
            if failureAction != nil, contentLayout.metadata?.state == .failed {
                actions.append(
                    UIAccessibilityCustomAction(
                        name: AppLanguage.localized("Failed to send. Retry options"),
                        target: self, selector: #selector(performAccessibleFailureAction)
                    ))
            }
            accessibilityCustomActions = actions.isEmpty ? nil : actions
        }

        @objc private func openFailureOptions() {
            guard contentLayout.metadata?.state == .failed else { return }
            failureAction?()
        }

        @objc private func performAccessibleFailureAction() -> Bool {
            guard contentLayout.metadata?.state == .failed, let failureAction else { return false }
            failureAction()
            return true
        }
    }

    /// A transparent native retry target preserves the row gesture marker and
    /// 44-point hit region without replacing the shared SwiftUI failure icon.
    final class TimelineFailureButton: UIButton {
        var onActivate: (() -> Void)?
        private let marker = MessageRowGestureMarker(frame: .zero)

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            addTarget(self, action: #selector(activate), for: .touchUpInside)
            accessibilityLabel = AppLanguage.localized("Failed to send. Retry options")
            marker.frame = bounds
            addSubview(marker)
        }

        required init?(coder: NSCoder) { nil }

        func setStatusFrame(_ statusFrame: CGRect) {
            frame = statusFrame
            setNeedsLayout()
        }

        private var hitBounds: CGRect {
            bounds.insetBy(
                dx: -max(0, (44 - bounds.width) / 2), dy: -max(0, (44 - bounds.height) / 2))
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            hitBounds.contains(point)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            marker.frame = hitBounds
        }

        func configure() {
            marker.configure(.tap { [weak self] in self?.activate() })
        }

        func clear() {
            marker.stop()
        }

        @objc private func activate() { onActivate?() }

    }

#endif
