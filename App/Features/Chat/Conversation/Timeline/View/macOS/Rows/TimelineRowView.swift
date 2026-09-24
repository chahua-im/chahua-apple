#if os(macOS)
    import AppKit
    import ChahuaAPI
    import SwiftUI

    /// Native row assembly consumes prepared rectangles, never asks a child to size
    /// itself, and keeps empty reusable section objects rather than message payloads.
    @MainActor
    final class TimelineRowView: NSView {
        private(set) var binding: TimelineRowBinding?
        private var bubbleView: TimelineBubbleContentView?
        private var avatarView: TimelineAvatarView?
        private var reactionsView: TimelineReactionsView?
        private var standaloneView: TimelineStandaloneView?
        private var replyButton: TimelineHoverReplyButton?
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
            view.bind(binding.presentation)
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
                let profile =
                    row.entry.remoteMessage == nil
                        && binding.actions.currentUserProfile?.uid == row.entry.senderID
                    ? binding.actions.currentUserProfile : nil
                let name =
                    row.entry.remoteMessage?.sender.name.flatMap { $0.isEmpty ? nil : $0 }
                    ?? profile?.username ?? "User \(row.entry.senderID)"
                let url = (row.entry.remoteMessage?.sender.avatarUrl ?? profile?.avatarUrl).flatMap(
                    URL.init(string:))
                view.isHidden = false
                view.configure(
                    url: url, name: name, userID: row.entry.senderID,
                    diameter: binding.presentation.environment.avatarSize,
                    displayScale: binding.presentation.environment.displayScale,
                    mediaContext: binding.mediaContext)
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
            guard let binding, !binding.context.isInteractionPreview,
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
        private var presentation: TimelineRowPresentation?
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
        func bind(_ presentation: TimelineRowPresentation) {
            self.presentation = presentation
            updatePaint()
        }
        func clear() {
            presentation = nil
            attributed = NSAttributedString(string: "")
            setAccessibilityLabel(nil)
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
            guard let p = presentation else { return }
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
                case .message(let row):
                    paragraph.lineSpacing = 3
                    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    let color =
                        dark
                        ? NSColor(srgbRed: 152 / 255, green: 154 / 255, blue: 162 / 255, alpha: 1)
                        : NSColor(srgbRed: 99 / 255, green: 100 / 255, blue: 105 / 255, alpha: 1)
                    let result = NSMutableAttributedString(string: "")
                    if let name = row.entry.remoteMessage?.sender.name, !name.isEmpty {
                        result.append(
                            NSAttributedString(
                                string: name + " ",
                                attributes: [
                                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                    .foregroundColor: color, .paragraphStyle: paragraph,
                                ]))
                    }
                    result.append(
                        NSAttributedString(
                            string: text,
                            attributes: [
                                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: color,
                                .paragraphStyle: paragraph,
                            ]))
                    attributed = result
                }
                setAccessibilityLabel(attributed.string)
            }
            needsLayout = true
            needsDisplay = true
        }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let rect =
                isDate
                ? bounds.insetBy(
                    dx: min(ChahuaTheme.Spacing.medium, bounds.width / 2),
                    dy: min(ChahuaTheme.Spacing.xSmall, bounds.height / 2)) : bounds
            attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }
#endif
