#if os(macOS)
    import AppKit
    import ChahuaAPI
    import SwiftUI

    /// Native row assembly consumes prepared rectangles, never asks a child to size
    /// itself, and keeps empty reusable section objects rather than message payloads.
    @MainActor
    final class TimelineRowView: NSView {
        static let selectionGutterWidth: CGFloat = 44
        private(set) var binding: TimelineRowBinding?
        private var bubbleView: TimelineBubbleContentView?
        private var avatarView: TimelineAvatarView?
        private var reactionsView: TimelineReactionsView?
        private var standaloneView: TimelineStandaloneView?
        private var replyButton: TimelineHoverReplyButton?
        private var messageSelection: TimelineMessageSelectionButton?
        private let highlightLayer = CALayer()
        private var rowTrackingArea: NSTrackingArea?
        private var isRowHovered = false
        private var visible = false

        override var isFlipped: Bool { true }
        override var wantsDefaultClipping: Bool { false }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = false
            highlightLayer.opacity = 0
            highlightLayer.actions = [
                "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(),
                "opacity": NSNull(),
            ]
            layer?.addSublayer(highlightLayer)
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func bind(_ binding: TimelineRowBinding) {
            let previous = self.binding
            let resetSelection = previous?.presentation.row.id != binding.presentation.row.id
            self.binding = binding  // Always replace live callbacks, even for identical rendering.
            if resetSelection { resetHover() }
            switch binding.presentation.row {
            case .dateSeparator, .unreadSeparator:
                bindStandalone(binding)
            case .message(let row):
                if row.entry.messageType == .system {
                    bindStandalone(binding)
                } else {
                    bindMessage(binding, row: row, resetSelection: resetSelection)
                }
            }
            if !canReply { resetHover() }
            configureMessageSelection()
            updateReplyVisibility()
            updateHighlight(
                animated: !resetSelection
                    && previous?.context.isHighlighted != binding.context.isHighlighted)
            updateAccessibilityActions()
            needsLayout = true
        }

        func clear() {
            binding = nil
            visible = false
            resetHover()
            bubbleView?.clear()
            bubbleView?.isHidden = true
            avatarView?.clear()
            avatarView?.isHidden = true
            reactionsView?.clear()
            reactionsView?.isHidden = true
            standaloneView?.clear()
            standaloneView?.isHidden = true
            replyButton?.isHidden = true
            messageSelection?.isHidden = true
            highlightLayer.removeAllAnimations()
            highlightLayer.opacity = 0
            setAccessibilityCustomActions(nil)
            setAccessibilityElement(false)
        }

        func setVisible(_ visible: Bool) {
            self.visible = visible
            bubbleView?.setVisible(visible && bubbleView?.isHidden == false)
            avatarView?.setVisible(visible && avatarView?.isHidden == false)
            reactionsView?.setVisible(visible && reactionsView?.isHidden == false)
            updateHover()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                setVisible(false)
            } else {
                setVisible(!isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty)
            }
        }

        override func layout() {
            super.layout()
            highlightLayer.frame = bounds
            messageSelection?.frame = bounds
            guard let binding else { return }
            let frames = binding.layout.frames
            bubbleView?.frame = frames[.bubble] ?? .zero
            avatarView?.frame = frames[.avatar] ?? .zero
            reactionsView?.frame = frames[.reactions] ?? .zero
            standaloneView?.frame = frames[.standalone] ?? .zero
            if let bubble = frames[.bubble], case .message(let row) = binding.presentation.row {
                replyButton?.frame = CGRect(
                    x: row.isOutgoing ? bubble.minX - 36 : bubble.maxX + 8,
                    y: bubble.maxY - 28, width: 28, height: 28)
            } else {
                replyButton?.frame = .zero
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let rowTrackingArea { removeTrackingArea(rowTrackingArea) }
            let rect = bounds.intersection(visibleRect)
            guard !rect.isEmpty else {
                rowTrackingArea = nil
                return
            }
            let area = NSTrackingArea(
                rect: rect, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
            addTrackingArea(area)
            rowTrackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { updateHover() }
        override func mouseExited(with event: NSEvent) { updateHover() }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateHighlight(animated: false)
        }
        private var isSelectingMessages: Bool {
            binding?.actions.isSelectingMessages == true
                && binding?.context.isInteractionPreview == false
        }

        private var selectableMessage: MessageResponse? {
            guard let binding, case .message(let row) = binding.presentation.row,
                let message = row.entry.remoteMessage, !message.isDeleted,
                message.messageType != .system
            else { return nil }
            return message
        }

        private func configureMessageSelection() {
            guard isSelectingMessages else {
                messageSelection?.isHidden = true
                return
            }
            if messageSelection == nil {
                // A native full-row overlay intercepts child controls without introducing
                // a per-row SwiftUI host, while wheel events still reach the scroll view.
                let button = TimelineMessageSelectionButton(frame: .zero)
                button.target = self
                button.action = #selector(toggleMessageSelection)
                addSubview(button, positioned: .above, relativeTo: nil)
                messageSelection = button
            }
            if let messageSelection {
                addSubview(messageSelection, positioned: .above, relativeTo: nil)
            }
            let message = selectableMessage
            messageSelection?.configure(
                message: message,
                selected: message.map {
                    binding?.actions.selectedMessageIDs.contains($0.id) == true
                } ?? false,
                busy: binding?.actions.isSelectionBusy == true)
        }

        @objc private func toggleMessageSelection() {
            guard isSelectingMessages, binding?.actions.isSelectionBusy != true,
                let message = selectableMessage
            else { return }
            binding?.actions.toggleMessageSelection?(message)
        }

        private func bindStandalone(_ binding: TimelineRowBinding) {
            bubbleView?.clear()
            bubbleView?.isHidden = true
            avatarView?.clear()
            avatarView?.isHidden = true
            reactionsView?.clear()
            reactionsView?.isHidden = true
            let view: TimelineStandaloneView
            if let standaloneView {
                view = standaloneView
            } else {
                view = TimelineStandaloneView(frame: .zero)
                addSubview(view)
                standaloneView = view
            }
            view.isHidden = binding.layout.frames[.standalone] == nil
            view.bind(binding)
        }

        private func bindMessage(
            _ binding: TimelineRowBinding, row: TimelineMessageRow, resetSelection: Bool
        ) {
            standaloneView?.clear()
            standaloneView?.isHidden = true
            let preview = binding.context.isInteractionPreview
            if binding.layout.frames[.bubble] != nil {
                let view: TimelineBubbleContentView
                if let bubbleView {
                    view = bubbleView
                } else {
                    view = TimelineBubbleContentView(frame: .zero)
                    addSubview(view)
                    bubbleView = view
                }
                view.isHidden = false
                view.bind(binding, resetSelection: resetSelection)
                view.setVisible(visible)
            } else {
                bubbleView?.clear()
                bubbleView?.isHidden = true
            }
            if !preview, binding.layout.frames[.avatar] != nil {
                let view: TimelineAvatarView
                if let avatarView {
                    view = avatarView
                } else {
                    view = TimelineAvatarView(frame: .zero)
                    addSubview(view)
                    avatarView = view
                }
                let sender = row.entry.sender
                let name =
                    sender?.name.flatMap { $0.isEmpty ? nil : $0 } ?? "User \(row.entry.senderID)"
                let url = sender?.avatarUrl.flatMap(URL.init(string:))
                view.isHidden = false
                view.configure(
                    url: url, name: name, userID: row.entry.senderID,
                    diameter: binding.presentation.environment.avatarSize,
                    displayScale: binding.presentation.environment.displayScale,
                    mediaContext: binding.mediaContext)
                view.onActivate =
                    !binding.actions.isSelectingMessages
                        && binding.actions.openMention != nil
                    ? { binding.actions.openMention?(row.entry.senderID) } : nil
                view.setVisible(visible)
            } else {
                avatarView?.clear()
                avatarView?.isHidden = true
            }
            if !preview, binding.layout.frames[.reactions] != nil {
                let view: TimelineReactionsView
                if let reactionsView {
                    view = reactionsView
                } else {
                    view = TimelineReactionsView(frame: .zero)
                    addSubview(view)
                    reactionsView = view
                }
                view.isHidden = false
                view.bind(binding)
                view.setVisible(visible)
            } else {
                reactionsView?.clear()
                reactionsView?.isHidden = true
            }
        }

        private var canReply: Bool {
            guard let binding, !binding.context.isInteractionPreview, !isSelectingMessages,
                case .message(let row) = binding.presentation.row,
                row.entry.messageType != .system, binding.layout.frames[.bubble] != nil,
                binding.actions.replyToMessage != nil
            else { return false }
            return MessageActionPolicy(row: row, context: binding.actions.interactionContext)
                .availability(of: .reply) == .enabled
        }
        private func updateHover() {
            // Scroll/layout and delayed tracking events must use the current pointer,
            // not a latched enter/exit flag on a still-visible or reused row.
            // Unclipped AppKit views can report a visibleRect larger than their bounds.
            let hovered =
                visible && window?.isKeyWindow == true
                && window.map {
                    bounds.intersection(visibleRect).contains(
                        convert($0.mouseLocationOutsideOfEventStream, from: nil))
                } == true
                && canReply
            if !hovered { resetHover() } else { isRowHovered = true }
            updateReplyVisibility()
        }
        private func resetHover() {
            isRowHovered = false
            replyButton?.resetHover()
        }
        private func updateReplyVisibility() {
            guard visible, isRowHovered, canReply else {
                replyButton?.isHidden = true
                return
            }
            if replyButton == nil {
                let button = TimelineHoverReplyButton(frame: .zero)
                button.target = self
                button.action = #selector(reply)
                addSubview(button)
                replyButton = button
                needsLayout = true
            }
            replyButton?.isHidden = false
        }
        @objc private func reply() {
            guard canReply, let binding, case .message(let row) = binding.presentation.row,
                let message = row.entry.remoteMessage
            else { return }
            binding.actions.replyToMessage?(message)
        }
        private func updateHighlight(animated: Bool) {
            let highlighted =
                binding?.context.isHighlighted == true
                && binding?.context.isInteractionPreview != true
            let opacity: Float = highlighted ? 1 : 0
            if animated {
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue =
                    highlightLayer.presentation()?.opacity ?? highlightLayer.opacity
                animation.toValue = opacity
                animation.duration = 0.3
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                highlightLayer.add(animation, forKey: "highlight")
            } else {
                highlightLayer.removeAnimation(forKey: "highlight")
            }
            highlightLayer.opacity = opacity
            effectiveAppearance.performAsCurrentDrawingAppearance {
                highlightLayer.backgroundColor =
                    NSColor(ChahuaTheme.accent).withAlphaComponent(0.15).cgColor
            }
        }
        private func updateAccessibilityActions() {
            guard let binding, !binding.context.isInteractionPreview,
                !binding.actions.interactionContext.isReadOnly, !isSelectingMessages,
                binding.actions.openContextMenu != nil,
                case .message(let row) = binding.presentation.row, row.entry.messageType != .system,
                binding.layout.frames[.bubble] != nil
            else {
                setAccessibilityCustomActions(nil)
                setAccessibilityElement(false)
                return
            }
            setAccessibilityElement(true)
            setAccessibilityRole(.group)
            setAccessibilityCustomActions([
                NSAccessibilityCustomAction(
                    name: AppLanguage.localized("Message actions"),
                    handler: { [weak self] in
                        guard let self else { return false }
                        return TimelineContextSource.openContextMenu(for: self)
                    })
            ])
        }
    }

    private final class TimelineMessageSelectionButton: NSButton {
        private let symbol = NSImageView()
        override var isFlipped: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame)
            title = ""
            isBordered = false
            addSubview(symbol)
        }
        required init?(coder: NSCoder) { nil }
        func configure(message: MessageResponse?, selected: Bool, busy: Bool) {
            isHidden = false
            isEnabled = !busy
            symbol.isHidden = message == nil
            symbol.image = NSImage(
                systemSymbolName: selected ? "checkmark.circle.fill" : "circle",
                accessibilityDescription: nil)
            symbol.contentTintColor = NSColor(ChahuaTheme.accent)
            setAccessibilityElement(message != nil)
            setAccessibilityLabel(
                AppLanguage.localized(selected ? "Deselect message" : "Select message"))
            setAccessibilityValue(selected ? 1 : 0)
            needsLayout = true
        }
        override func layout() {
            super.layout()
            symbol.frame = CGRect(
                x: bounds.maxX - (TimelineRowView.selectionGutterWidth + 24) / 2,
                y: bounds.midY - 12, width: 24, height: 24)
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
            return self
        }
        override func menu(for event: NSEvent) -> NSMenu? { nil }
    }

    @MainActor
    private final class TimelineHoverReplyButton: NSButton {
        private var hoverArea: NSTrackingArea?
        private var hovered = false
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            title = ""
            isBordered = false
            imagePosition = .imageOnly
            imageScaling = .scaleNone
            setButtonType(.momentaryPushIn)
            wantsLayer = true
            layer?.cornerRadius = 14
            setAccessibilityLabel(AppLanguage.localized("Reply"))
            toolTip = AppLanguage.localized("Reply")
            updatePaint()
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func resetHover() {
            if hovered {
                hovered = false
                updatePaint()
            }
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverArea { removeTrackingArea(hoverArea) }
            let area = NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self)
            addTrackingArea(area)
            hoverArea = area
        }
        override func mouseEntered(with event: NSEvent) {
            hovered = true
            updatePaint()
        }
        override func mouseExited(with event: NSEvent) { resetHover() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updatePaint()
        }
        private func updatePaint() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let color = hovered ? NSColor(ChahuaTheme.accent) : .secondaryLabelColor
                image = NSImage(
                    systemSymbolName: "arrowshape.turn.up.left", accessibilityDescription: nil)?
                    .withSymbolConfiguration(
                        .init(pointSize: 16, weight: .regular).applying(
                            .init(paletteColors: [color])))
                layer?.backgroundColor =
                    NSColor.labelColor.withAlphaComponent(hovered ? 0.12 : 0.06).cgColor
            }
        }
    }

    @MainActor
    private final class TimelineStandaloneView: NSView {
        private var binding: TimelineRowBinding?
        private lazy var systemLayout = MessageSummaryLayout()
        private var pressedTarget: TimelineSystemMessageContent.Target?
        private var attributed = NSAttributedString(string: "")
        private var isDate = false
        override var isFlipped: Bool { true }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func bind(_ binding: TimelineRowBinding) {
            self.binding = binding
            pressedTarget = nil
            updatePaint()
        }
        func clear() {
            binding = nil
            pressedTarget = nil
            attributed = NSAttributedString(string: "")
            setAccessibilityLabel(nil)
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
        override func layout() {
            super.layout()
            layer?.cornerRadius = isDate ? bounds.height / 2 : 0
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updatePaint()
        }
        private func updatePaint() {
            guard let binding else { return }
            let p = binding.presentation
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                paragraph.lineBreakMode = .byWordWrapping
                let text = p.standaloneText ?? ""
                isDate = false
                layer?.backgroundColor = nil
                switch p.row {
                case .dateSeparator:
                    isDate = true
                    attributed = NSAttributedString(
                        string: text,
                        attributes: [
                            .font: NSFont.systemFont(ofSize: p.environment.captionSize),
                            .foregroundColor: NSColor(ChahuaTheme.secondaryText),
                            .paragraphStyle: paragraph,
                        ])
                    layer?.backgroundColor = NSColor(ChahuaTheme.secondaryBackground).cgColor
                case .unreadSeparator:
                    attributed = NSAttributedString(
                        string: text,
                        attributes: [
                            .font: NSFont.systemFont(ofSize: p.environment.captionSize),
                            .foregroundColor: NSColor(ChahuaTheme.ChatBubble.outgoingBackground),
                            .paragraphStyle: paragraph,
                        ])
                case .message:
                    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    let color =
                        dark
                        ? NSColor(srgbRed: 152 / 255, green: 154 / 255, blue: 162 / 255, alpha: 1)
                        : NSColor(srgbRed: 99 / 255, green: 100 / 255, blue: 105 / 255, alpha: 1)
                    attributed =
                        p.systemContent?.attributedText(
                            color: color,
                            linksEnabled: binding.actions.canOpenSystemTargets(in: binding.context))
                        ?? NSAttributedString(string: text)
                    systemLayout.container.lineBreakMode = .byWordWrapping
                    systemLayout.update(attributed, lineLimit: 0)
                }
                setAccessibilityLabel(attributed.string)
            }
            needsLayout = true
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if binding?.presentation.systemContent != nil {
                systemLayout.draw(in: bounds)
                return
            }
            let rect =
                isDate
                ? bounds.insetBy(
                    dx: min(ChahuaTheme.Spacing.medium, bounds.width / 2),
                    dy: min(ChahuaTheme.Spacing.xSmall, bounds.height / 2)) : bounds
            attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            target(at: convert(point, from: superview)) == nil ? nil : self
        }

        private func target(at point: CGPoint) -> TimelineSystemMessageContent.Target? {
            guard let binding, binding.actions.canOpenSystemTargets(in: binding.context),
                let content = binding.presentation.systemContent
            else { return nil }
            return systemLayout.systemTarget(at: point, width: bounds.width, content: content)
        }

        override func mouseDown(with event: NSEvent) {
            pressedTarget = target(at: convert(event.locationInWindow, from: nil))
        }

        override func mouseUp(with event: NSEvent) {
            defer { pressedTarget = nil }
            guard let pressedTarget,
                target(at: convert(event.locationInWindow, from: nil)) == pressedTarget
            else { return }
            binding?.actions.openSystemTarget(pressedTarget)
        }

        override func resetCursorRects() {
            guard let binding, binding.actions.canOpenSystemTargets(in: binding.context),
                let content = binding.presentation.systemContent
            else { return }
            _ = systemLayout.size(width: bounds.width)
            for link in content.links {
                let glyphs = systemLayout.manager.glyphRange(
                    forCharacterRange: link.range, actualCharacterRange: nil)
                systemLayout.manager.enumerateEnclosingRects(
                    forGlyphRange: glyphs,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: systemLayout.container
                ) { rect, _ in
                    self.addCursorRect(rect, cursor: .pointingHand)
                }
            }
        }
    }
#endif
