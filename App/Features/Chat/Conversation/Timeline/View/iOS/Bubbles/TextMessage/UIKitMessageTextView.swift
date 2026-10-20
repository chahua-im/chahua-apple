#if os(iOS)
    import UIKit

    extension MessageTextContent.Coordinator: UITextViewDelegate {

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
                linkTap.isEnabled = !allowsSelection
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
            if geometryChanged {
                setNeedsLayout()
                invalidateIntrinsicContentSize()
            }
            setNeedsDisplay()
        }

        func clear() {
            coordinator.openLink = nil
            coordinator.openMention = nil
            coordinator.textInput = nil
            failureAction = nil
            rowAccessibilityActions = nil
            resignFirstResponder()
            contentLayout.update(attributedText: NSAttributedString(string: ""), metadata: nil)
            selectedRange = NSRange(location: 0, length: 0)
            setNeedsDisplay()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let geometry = contentLayout.assignedGeometry else { return }
            if let failureButton, let metadata = contentLayout.metadata {
                failureButton.setSymbolFrame(metadata.symbolFrame(in: geometry.metadataFrame))
                bringSubviewToFront(failureButton)
            }
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool
        {
            if gestureRecognizer === linkTap {
                return linkCharacterIndex(at: gestureRecognizer.location(in: self)) != nil
            }
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }

        @objc private func activateTappedLink(_ recognizer: UITapGestureRecognizer) {
            guard let index = linkCharacterIndex(at: recognizer.location(in: self)) else { return }
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
            guard index < storage.length,
                storage.attribute(.link, at: index, effectiveRange: nil) != nil
            else { return nil }
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
            let bounds = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            return bounds.insetBy(dx: -4, dy: -4).contains(location) ? index : nil
        }

        override func draw(_ rect: CGRect) {
            super.draw(rect)
            guard let geometry = contentLayout.assignedGeometry else { return }
            contentLayout.metadata?.draw(
                in: geometry.metadataFrame, drawsSymbol: failureButton?.isHidden != false)
        }

        override var accessibilityValue: String? {
            get {
                guard let metadata = contentLayout.metadata else { return super.accessibilityValue }
                return "\(text ?? "") \(metadata.accessibilityLabel)"
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
            button.configure(symbol: metadata.symbol)
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

    /// Shared inline/standalone retry target: layout keeps the measured symbol frame,
    /// while hit testing and the gesture marker retain the existing 44-point region.
    final class TimelineFailureButton: UIButton {
        var onActivate: (() -> Void)?
        private let marker = MessageRowGestureMarker(frame: .zero)
        private var symbolSize: CGSize = .zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            imageView?.contentMode = .scaleAspectFit
            addTarget(self, action: #selector(activate), for: .touchUpInside)
            accessibilityLabel = AppLanguage.localized("Failed to send. Retry options")
            marker.frame = bounds
            addSubview(marker)
        }

        required init?(coder: NSCoder) { nil }

        func setSymbolFrame(_ symbolFrame: CGRect) {
            symbolSize = symbolFrame.size
            setNeedsLayout()
            frame = symbolFrame
        }

        override func imageRect(forContentRect contentRect: CGRect) -> CGRect {
            CGRect(
                x: contentRect.midX - symbolSize.width / 2,
                y: contentRect.midY - symbolSize.height / 2,
                width: symbolSize.width, height: symbolSize.height)
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

        func configure(symbol: UIImage?) {
            setImage(symbol, for: .normal)
            marker.configure(.tap { [weak self] in self?.activate() })
        }

        func clear() {
            setImage(nil, for: .normal)
            marker.stop()
        }

        @objc private func activate() { onActivate?() }

    }

#endif
