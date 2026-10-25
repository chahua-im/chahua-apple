#if os(iOS)
    import UIKit
    import SwiftUI
    import ChahuaAPI

    /// UIKit is required here because nested SwiftUI hosting incurred per-row layout
    /// work during scrolling. Prepared timeline rectangles remain the sizing authority.
    @MainActor
    final class TimelineRowView: UIView {
        static let selectionGutterWidth: CGFloat = 44
        private(set) var binding: TimelineRowBinding?
        lazy var rowGestures = MessageRowGestureCoordinator(view: self)
        private let content = UIView()
        private let rowMarker = MessageRowGestureMarker()
        private let holdMarker = MessageRowGestureMarker()
        private let arrow = TimelineReplyArrowView()
        private var bubble: TimelineBubbleContentView?
        private var avatar: TimelineAvatarView?
        private var reactions: TimelineReactionsView?
        private var thread: TimelineThreadButton?
        private var standalone: TimelineStandaloneView?
        private var hoverReply: UIButton?
        private var messageSelection: TimelineMessageSelectionButton?
        private let hoverMarker = MessageRowGestureMarker()
        private var visible = false
        private var mediaFullyVisible = false
        private var hovered = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            addSubview(arrow)
            addSubview(content)
            addSubview(rowMarker)
            content.addSubview(holdMarker)
            _ = rowGestures
            addGestureRecognizer(
                UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        }
        required init?(coder: NSCoder) { nil }

        func bind(_ binding: TimelineRowBinding) {
            let changed = self.binding?.presentation.row.id != binding.presentation.row.id
            let highlightChanged =
                self.binding?.context.isHighlighted != binding.context.isHighlighted
            let selectionModeChanged =
                isSelectingMessages
                != (binding.actions.isSelectingMessages && !binding.context.isInteractionPreview)
            if changed {
                rowGestures.cancel()
                resetSwipe(animated: false)
                hovered = false
            }
            self.binding = binding  // Refresh callbacks even when rendering is unchanged.
            mediaFullyVisible = false
            switch binding.presentation.row {
            case .dateSeparator, .unreadSeparator: bindStandalone(binding)
            case .message(let row):
                if row.entry.messageType == .system {
                    bindStandalone(binding)
                } else {
                    bindMessage(
                        binding, row: row, resetSelection: changed || selectionModeChanged)
                }
            }
            configureMessageSelection()
            if binding.context.isInteractionPreview || isSelectingMessages {
                rowMarker.stop()
                holdMarker.stop()
            } else {
                rowMarker.configure(
                    .row(
                        .init(
                            isEnabled: canReply, onChange: { [weak self] in self?.swipe($0) },
                            onFinish: { [weak self] in self?.resetSwipe(animated: true) },
                            onReply: { [weak self] in self?.reply() })))
                if bubble?.isHidden == false, !binding.actions.interactionContext.isReadOnly,
                    binding.actions.openContextMenu != nil
                {
                    holdMarker.configure(
                        .bubble(
                            .init(
                                view: bubble,
                                open: { [weak self] rect, feedback in
                                    self?.openMenu(rect, pressFeedback: feedback)
                                })))
                } else {
                    holdMarker.stop()
                }
            }
            if !canReply { resetSwipe(animated: false) }
            updateHover()
            let paint = {
                self.backgroundColor =
                    binding.context.isHighlighted && !binding.context.isInteractionPreview
                    ? UIColor(ChahuaTheme.accent).withAlphaComponent(0.15) : .clear
            }
            if highlightChanged && !changed {
                UIView.animate(
                    withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .curveEaseOut],
                    animations: paint)
            } else {
                layer.removeAllAnimations()
                paint()
            }
            setNeedsLayout()
        }

        func clear() {
            rowGestures.cancel()
            rowMarker.stop()
            holdMarker.stop()
            hoverMarker.stop()
            binding = nil
            visible = false
            mediaFullyVisible = false
            hovered = false
            resetSwipe(animated: false)
            bubble?.clear()
            bubble?.isHidden = true
            avatar?.clear()
            avatar?.isHidden = true
            reactions?.clear()
            reactions?.isHidden = true
            thread?.clear()
            thread?.isHidden = true
            standalone?.clear()
            standalone?.isHidden = true
            hoverReply?.isHidden = true
            messageSelection?.clear()
            content.isUserInteractionEnabled = true
            content.accessibilityElementsHidden = false
            rowGestures.setEnabled(true)
            backgroundColor = .clear
        }
        func setVisible(_ visible: Bool) {
            guard self.visible != visible else { return }
            mediaFullyVisible = false
            self.visible = visible
            if !visible {
                rowGestures.cancel()
                resetSwipe(animated: false)
                hovered = false
            }
            bubble?.setVisible(visible && bubble?.isHidden == false)
            avatar?.setVisible(visible && avatar?.isHidden == false)
            reactions?.setVisible(visible && reactions?.isHidden == false)
            updateHover()
        }
        func refreshMediaVisibility(isFullyVisible: Bool) {
            guard visible else { return }
            // A fully exposed row has no descendant crossing the viewport edge.
            // Refresh once on entry, including when a previously clipped tile reappears.
            guard !isFullyVisible || !mediaFullyVisible else { return }
            mediaFullyVisible = isFullyVisible
            bubble?.refreshMediaVisibility()
            avatar?.setVisible(avatar?.isHidden == false)
            reactions?.setVisible(reactions?.isHidden == false)
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            setVisible(window != nil && !isHidden)
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            content.bounds = bounds
            content.center = CGPoint(x: bounds.midX, y: bounds.midY)
            rowMarker.frame = bounds
            messageSelection?.frame = bounds
            arrow.frame = CGRect(x: bounds.maxX - 52, y: bounds.midY - 18, width: 36, height: 36)
            guard let binding else { return }
            let frames = binding.layout.frames
            let bubbleFrame =
                binding.context.isInteractionPreview ? bounds : frames[.bubble] ?? .zero
            // A pending press transforms only the bubble. Assign its untransformed
            // bounds/center, never UIView.frame while that transform is active.
            bubble?.bounds = CGRect(origin: .zero, size: bubbleFrame.size)
            bubble?.center = CGPoint(x: bubbleFrame.midX, y: bubbleFrame.midY)
            holdMarker.frame = bubbleFrame
            avatar?.frame = frames[.avatar] ?? .zero
            reactions?.frame = frames[.reactions] ?? .zero
            thread?.frame = frames[.thread] ?? .zero
            standalone?.frame = frames[.standalone] ?? .zero
            if let frame = frames[.bubble], case .message(let row) = binding.presentation.row {
                hoverReply?.frame = CGRect(
                    x: row.isOutgoing ? frame.minX - 36 : frame.maxX + 8, y: frame.maxY - 28,
                    width: 28, height: 28)
                hoverMarker.frame = hoverReply?.bounds ?? .zero
            }
        }
        private func bindStandalone(_ binding: TimelineRowBinding) {
            bubble?.clear()
            bubble?.isHidden = true
            avatar?.clear()
            avatar?.isHidden = true
            reactions?.clear()
            reactions?.isHidden = true
            thread?.clear()
            thread?.isHidden = true
            if standalone == nil {
                let view = TimelineStandaloneView()
                content.addSubview(view)
                standalone = view
            }
            standalone?.isHidden = false
            standalone?.bind(binding)
        }
        private func bindMessage(
            _ binding: TimelineRowBinding, row: TimelineMessageRow, resetSelection: Bool
        ) {
            standalone?.clear()
            standalone?.isHidden = true
            if bubble == nil {
                let view = TimelineBubbleContentView(frame: .zero)
                content.addSubview(view)
                bubble = view
            }
            bubble?.isHidden = false
            bubble?.bind(binding, resetSelection: resetSelection)
            bubble?.setVisible(visible)
            let preview = binding.context.isInteractionPreview
            if !preview, binding.layout.frames[.avatar] != nil {
                if avatar == nil {
                    let view = TimelineAvatarView(frame: .zero)
                    content.addSubview(view)
                    avatar = view
                }
                let sender = row.entry.sender
                let name =
                    sender?.name.flatMap { $0.isEmpty ? nil : $0 } ?? "User \(row.entry.senderID)"
                let url = sender?.avatarUrl.flatMap(URL.init(string:))
                avatar?.isHidden = false
                avatar?.configure(
                    url: url, name: name, userID: row.entry.senderID,
                    diameter: binding.presentation.environment.avatarSize,
                    displayScale: binding.presentation.environment.displayScale,
                    mediaContext: binding.mediaContext)
                avatar?.onActivate =
                    !binding.actions.isSelectingMessages
                        && binding.actions.openMention != nil
                    ? { binding.actions.openMention?(row.entry.senderID) } : nil
                avatar?.setVisible(visible)
            } else {
                avatar?.clear()
                avatar?.isHidden = true
            }
            if !preview, binding.layout.frames[.reactions] != nil {
                if reactions == nil {
                    let view = TimelineReactionsView(frame: .zero)
                    content.addSubview(view)
                    reactions = view
                }
                reactions?.isHidden = false
                reactions?.bind(binding)
                reactions?.setVisible(visible)
            } else {
                reactions?.clear()
                reactions?.isHidden = true
            }
            if !preview, binding.layout.frames[.thread] != nil,
                let label = binding.presentation.threadLabel
            {
                if thread == nil {
                    let view = TimelineThreadButton()
                    content.addSubview(view)
                    thread = view
                }
                thread?.isHidden = false
                thread?.configure(
                    label: label, binding: binding,
                    action: { [weak self] in
                        guard let binding = self?.binding,
                            case .message(let row) = binding.presentation.row,
                            let message = row.entry.remoteMessage, !message.isDeleted
                        else { return }
                        binding.actions.openThread?(message.id)
                    })
            } else {
                thread?.clear()
                thread?.isHidden = true
            }
            bubble?.accessibilityCustomActions =
                preview || isSelectingMessages
                ? nil
                : [
                    UIAccessibilityCustomAction(
                        name: AppLanguage.localized("Message actions"),
                        actionHandler: { [weak self] _ in
                            guard let self, let bubble = self.bubble, let window = self.window,
                                self.binding?.actions.openContextMenu != nil
                            else { return false }
                            self.openMenu(bubble.convert(bubble.bounds, to: window))
                            return true
                        })
                ]
        }
        private var isSelectingMessages: Bool {
            binding?.actions.isSelectingMessages == true
                && binding?.context.isInteractionPreview == false
        }

        private var selectableMessage: MessageResponse? {
            guard let binding, case .message(let row) = binding.presentation.row,
                row.entry.messageType != .system, let message = row.entry.remoteMessage,
                !message.isDeleted
            else { return nil }
            return message
        }

        private func configureMessageSelection() {
            let selecting = isSelectingMessages
            rowGestures.setEnabled(!selecting)
            content.isUserInteractionEnabled = !selecting
            content.accessibilityElementsHidden = selecting
            guard selecting else {
                messageSelection?.clear()
                return
            }
            hovered = false
            if messageSelection == nil {
                // The native timeline owns prepared row geometry and gesture arbitration.
                // A reusable UIKit overlay can consume every child hit target while still
                // yielding drags to the collection view; a separate SwiftUI host cannot
                // participate in that arbitration without per-row hosting/layout work.
                let button = TimelineMessageSelectionButton(frame: .zero)
                button.addAction(
                    UIAction { [weak self] _ in self?.toggleMessageSelection() },
                    for: .touchUpInside)
                addSubview(button)
                messageSelection = button
            }
            let message = selectableMessage
            messageSelection?.isEnabled = binding?.actions.isSelectionBusy != true
            messageSelection?.configure(
                message: message,
                selected: message.map {
                    binding?.actions.selectedMessageIDs.contains($0.id) == true
                } ?? false)
        }

        private func toggleMessageSelection() {
            guard isSelectingMessages, binding?.actions.isSelectionBusy != true,
                let message = selectableMessage
            else { return }
            binding?.actions.toggleMessageSelection?(message)
        }

        private var canReply: Bool {
            guard let binding, !binding.context.isInteractionPreview, !isSelectingMessages,
                case .message(let row) = binding.presentation.row,
                row.entry.messageType != .system, binding.actions.replyToMessage != nil
            else { return false }
            return MessageActionPolicy(row: row, context: binding.actions.interactionContext)
                .availability(of: .reply) == .enabled
        }
        private func reply() {
            guard canReply, let binding, case .message(let row) = binding.presentation.row,
                let message = row.entry.remoteMessage
            else { return }
            binding.actions.replyToMessage?(message)
        }
        private func openMenu(_ rect: CGRect, pressFeedback: MessageBubblePressFeedback? = nil) {
            guard let binding, !binding.context.isInteractionPreview,
                !binding.actions.interactionContext.isReadOnly, !isSelectingMessages,
                case .message(let row) = binding.presentation.row,
                let open = binding.actions.openContextMenu
            else {
                pressFeedback?.restore()
                return
            }
            // End editing only after the row recognizer has awarded the hold to the
            // menu. Doing this on touch-down can relayout/cancel the pending hold.
            window?.endEditing(false)
            open(
                row,
                .init(
                    rect: rect, presentation: binding.presentation, layout: binding.layout,
                    pressFeedback: pressFeedback))
        }
        private func swipe(_ displacement: CGFloat) {
            content.layer.removeAllAnimations()
            content.transform = CGAffineTransform(translationX: -displacement, y: 0)
            arrow.update(progress: min(displacement / 60, 1))
        }
        private func resetSwipe(animated: Bool) {
            let reset = {
                self.content.transform = .identity
                self.arrow.update(progress: 0)
            }
            if animated {
                UIView.animate(
                    withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseOut],
                    animations: reset)
            } else {
                content.layer.removeAllAnimations()
                reset()
            }
        }
        @objc private func hover(_ gesture: UIHoverGestureRecognizer) {
            hovered =
                (gesture.state == .began || gesture.state == .changed)
                && bounds.contains(gesture.location(in: self))
            updateHover()
        }
        private func updateHover() {
            guard visible, hovered, canReply else {
                hoverReply?.isHidden = true
                hoverMarker.stop()
                return
            }
            if hoverReply == nil {
                let button = UIButton(type: .system)
                button.setImage(UIImage(systemName: "arrowshape.turn.up.left"), for: .normal)
                button.tintColor = .secondaryLabel
                button.backgroundColor = UIColor.label.withAlphaComponent(0.06)
                button.layer.cornerRadius = 14
                button.accessibilityLabel = AppLanguage.localized("Reply")
                button.addAction(
                    UIAction { [weak self] _ in self?.reply() }, for: .primaryActionTriggered)
                button.addSubview(hoverMarker)
                content.addSubview(button)
                hoverReply = button
            }
            hoverMarker.configure(.tap { [weak self] in self?.reply() })
            hoverReply?.isHidden = false
            setNeedsLayout()
        }
    }

    /// One reused full-row target prevents media, text, avatar and reaction controls
    /// from handling selection taps. Its image occupies only the reserved right gutter.
    private final class TimelineMessageSelectionButton: UIButton {
        private static let uncheckedImage = UIImage(systemName: "circle")
        private static let checkedImage = UIImage(systemName: "checkmark.circle.fill")

        override init(frame: CGRect) {
            super.init(frame: frame)
            tintColor = UIColor(ChahuaTheme.accent)
        }

        required init?(coder: NSCoder) { nil }

        func configure(message: MessageResponse?, selected: Bool) {
            isHidden = false
            isSelected = selected
            // UIButton updates image visibility during layout; remove the state images
            // themselves for separators and other ineligible rows.
            setImage(message == nil ? nil : Self.uncheckedImage, for: .normal)
            setImage(message == nil ? nil : Self.checkedImage, for: .selected)
            isAccessibilityElement = message != nil
            accessibilityIdentifier = message.map { "message-selection-\($0.id.rawValue)" }
            accessibilityLabel = message.map { _ in
                AppLanguage.localized(selected ? "Deselect message" : "Select message")
            }
            accessibilityHint = message.map { _ in
                AppLanguage.localized(
                    selected
                        ? "Double-tap to deselect this message."
                        : "Double-tap to select this message.")
            }
            accessibilityTraits = selected ? [.button, .selected] : .button
        }

        func clear() {
            isHidden = true
            isSelected = false
            isHighlighted = false
            setImage(nil, for: .normal)
            setImage(nil, for: .selected)
            isAccessibilityElement = false
            accessibilityIdentifier = nil
            accessibilityLabel = nil
            accessibilityHint = nil
            accessibilityTraits = .button
        }

        override func imageRect(forContentRect contentRect: CGRect) -> CGRect {
            CGRect(
                x: bounds.maxX - (TimelineRowView.selectionGutterWidth + 24) / 2,
                y: bounds.midY - 12, width: 24, height: 24)
        }
    }

    private final class TimelineThreadButton: UIButton {
        private let text = UILabel()
        private let symbol = UIImageView()
        private let chevron = UIImageView()
        private let marker = MessageRowGestureMarker()
        private var contentFrames: [CGRect] = []
        private var action: (() -> Void)?
        init() {
            super.init(frame: .zero)
            addSubview(text)
            addSubview(symbol)
            addSubview(chevron)
            addSubview(marker)
            text.isAccessibilityElement = false
            addAction(UIAction { [weak self] _ in self?.action?() }, for: .primaryActionTriggered)
        }
        required init?(coder: NSCoder) { nil }
        func configure(label: String, binding: TimelineRowBinding, action: @escaping () -> Void) {
            self.action = action
            text.text = label
            let fontSize = binding.presentation.environment.captionSize
            let isOutgoing: Bool
            if case .message(let row) = binding.presentation.row {
                isOutgoing = row.isOutgoing
            } else {
                isOutgoing = false
            }
            let color = UIColor(
                isOutgoing ? ChahuaTheme.ChatBubble.outgoingForeground : ChahuaTheme.accent)
            text.font = .systemFont(ofSize: fontSize, weight: .semibold)
            text.textColor = color
            let configuration = UIImage.SymbolConfiguration(pointSize: fontSize, weight: .semibold)
            symbol.image = UIImage(
                systemName: "bubble.left.and.bubble.right.fill", withConfiguration: configuration)
            chevron.image = UIImage(systemName: "chevron.right", withConfiguration: configuration)
            symbol.tintColor = color
            chevron.tintColor = color
            contentFrames = binding.layout.threadContentFrames
            isEnabled = binding.actions.openThread != nil
            accessibilityLabel = label
            marker.configure(.tap(isEnabled ? action : nil))
            setNeedsLayout()
        }
        func clear() {
            action = nil
            text.text = nil
            symbol.image = nil
            chevron.image = nil
            contentFrames.removeAll(keepingCapacity: true)
            marker.stop()
            accessibilityLabel = nil
            isEnabled = false
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            symbol.frame = contentFrames.indices.contains(0) ? contentFrames[0] : .zero
            text.frame = contentFrames.indices.contains(1) ? contentFrames[1] : .zero
            chevron.frame = contentFrames.indices.contains(2) ? contentFrames[2] : .zero
            marker.frame = bounds
        }
    }

    private final class TimelineStandaloneView: UIView {
        private var binding: TimelineRowBinding?
        private lazy var systemLayout = MessageSummaryLayout()
        private var attributed = NSAttributedString(string: "")
        private var isDate = false
        init() {
            super.init(frame: .zero)
            isOpaque = false
            isAccessibilityElement = true
            accessibilityTraits = .staticText
            addGestureRecognizer(
                UITapGestureRecognizer(target: self, action: #selector(activateTarget(_:))))
            registerForTraitChanges([
                UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self,
                UITraitUserInterfaceLevel.self,
                UITraitDisplayGamut.self, UITraitDisplayScale.self, UITraitLayoutDirection.self,
            ]) { (view: TimelineStandaloneView, _: UITraitCollection) in
                view.updatePaint()
            }
        }
        required init?(coder: NSCoder) { nil }
        func bind(_ binding: TimelineRowBinding) {
            self.binding = binding
            updatePaint()
        }
        func clear() {
            binding = nil
            attributed = NSAttributedString(string: "")
            accessibilityLabel = nil
            setNeedsDisplay()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            layer.cornerRadius = isDate ? bounds.height / 2 : 0
        }
        private func updatePaint() {
            guard let binding else { return }
            let p = binding.presentation
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            let text = p.standaloneText ?? ""
            isDate = false
            backgroundColor = .clear
            switch p.row {
            case .dateSeparator:
                isDate = true
                attributed = NSAttributedString(
                    string: text,
                    attributes: [
                        .font: UIFont.systemFont(ofSize: p.environment.captionSize),
                        .foregroundColor: UIColor(ChahuaTheme.secondaryText),
                        .paragraphStyle: paragraph,
                    ])
                backgroundColor = UIColor(ChahuaTheme.secondaryBackground)
            case .unreadSeparator:
                attributed = NSAttributedString(
                    string: text,
                    attributes: [
                        .font: UIFont.systemFont(ofSize: p.environment.captionSize),
                        .foregroundColor: UIColor(ChahuaTheme.ChatBubble.outgoingBackground),
                        .paragraphStyle: paragraph,
                    ])
            case .message:
                let color =
                    traitCollection.userInterfaceStyle == .dark
                    ? UIColor(red: 152 / 255, green: 154 / 255, blue: 162 / 255, alpha: 1)
                    : UIColor(red: 99 / 255, green: 100 / 255, blue: 105 / 255, alpha: 1)
                attributed =
                    p.systemContent?.attributedText(
                        color: color,
                        linksEnabled: binding.actions.canOpenSystemTargets(in: binding.context))
                    ?? NSAttributedString(string: text)
                systemLayout.container.lineBreakMode = .byWordWrapping
                systemLayout.update(attributed, lineLimit: 0)
            }
            accessibilityLabel = attributed.string
            setNeedsDisplay()
            setNeedsLayout()
        }
        override func draw(_ rect: CGRect) {
            if binding?.presentation.systemContent != nil {
                systemLayout.draw(in: bounds)
                return
            }
            let rect =
                isDate
                ? bounds.insetBy(
                    dx: min(ChahuaTheme.Spacing.medium, bounds.width / 2),
                    dy: min(ChahuaTheme.Spacing.xSmall, bounds.height / 2)) : bounds
            attributed.draw(
                with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            target(at: point) != nil
        }

        private func target(at point: CGPoint) -> TimelineSystemMessageContent.Target? {
            guard let binding, binding.actions.canOpenSystemTargets(in: binding.context),
                let content = binding.presentation.systemContent
            else { return nil }
            return systemLayout.systemTarget(at: point, width: bounds.width, content: content)
        }

        @objc private func activateTarget(_ recognizer: UITapGestureRecognizer) {
            guard let target = target(at: recognizer.location(in: self)) else { return }
            binding?.actions.openSystemTarget(target)
        }
    }

    private final class TimelineReplyArrowView: UIView {
        private let outline = CAShapeLayer()
        private let fill = CAShapeLayer()
        private let reveal = CALayer()
        private var progress: CGFloat = 0
        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            alpha = 0
            layer.addSublayer(outline)
            layer.addSublayer(fill)
            fill.mask = reveal
            outline.fillColor = nil
            outline.lineWidth = 35 * 0.044
            outline.lineJoin = .round
            reveal.backgroundColor = UIColor.black.cgColor
        }
        required init?(coder: NSCoder) { nil }
        func update(progress: CGFloat) {
            let crossed = self.progress < 1 && progress >= 1
            self.progress = progress
            alpha = progress
            transform = CGAffineTransform(scaleX: 0.5 + 0.5 * progress, y: 0.5 + 0.5 * progress)
            setNeedsLayout()
            if crossed {
                let burst = CAKeyframeAnimation(keyPath: "transform.scale")
                burst.values = [1, 1.25, 1]
                burst.keyTimes = [0, 0.45, 1]
                burst.duration = 0.4
                layer.add(burst, forKey: "replyThreshold")
            }
            if progress == 0 { layer.removeAllAnimations() }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if outline.path == nil {
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 240, y: 424))
                path.addLine(to: CGPoint(x: 240, y: 328))
                path.addCurve(
                    to: CGPoint(x: 448, y: 424), controlPoint1: CGPoint(x: 356.4, y: 328),
                    controlPoint2: CGPoint(x: 399.39, y: 361.76))
                path.addCurve(
                    to: CGPoint(x: 240, y: 184), controlPoint1: CGPoint(x: 448, y: 304.77),
                    controlPoint2: CGPoint(x: 408.43, y: 184))
                path.addLine(to: CGPoint(x: 240, y: 88))
                path.addLine(to: CGPoint(x: 64, y: 256))
                path.close()
                path.apply(
                    CGAffineTransform(translationX: 7, y: 6.472).scaledBy(x: 0.044, y: 0.044))
                outline.path = path.cgPath
                fill.path = path.cgPath
            }
            outline.strokeColor = UIColor(ChahuaTheme.accent).cgColor
            fill.fillColor = outline.strokeColor
            let amount = max(0, 2 * progress - 1)
            reveal.frame = CGRect(
                x: 7 + (448 - 384 * amount) * 0.044, y: 6.472 + 88 * 0.044,
                width: 384 * amount * 0.044, height: 336 * 0.044)
            CATransaction.commit()
        }
    }
#endif
