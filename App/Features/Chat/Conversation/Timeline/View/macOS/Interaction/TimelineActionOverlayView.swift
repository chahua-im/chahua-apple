#if os(macOS)
import AppKit
import ChahuaAPI
import QuartzCore
import SwiftUI

/// Window-level native popup. Its preview owns independent text storage, media
/// lifecycle and cached geometry; no view is borrowed from a recyclable cell.
@MainActor
final class TimelineActionOverlayView: NSView {
    var onDismiss: (() -> Void)?
    var onReaction: ((String) -> Void)?
    var onAction: ((MessageMenuAction) -> Void)?
    var onBlock: (() -> Void)?
    var onRevoke: (() -> Void)?

    private let backdrop = NSVisualEffectView()
    private let dimmingView = NSView()
    private let dismissButton = TimelineMenuButton()
    private let scrollView = NSScrollView()
    private let documentView = TimelineMenuDocumentView()
    private let reactionSurface = TimelineMenuSurface(cornerRadius: 26)
    private let actionSurface = TimelineMenuSurface(cornerRadius: 14)
    private let pendingSurface = TimelineMenuSurface(cornerRadius: 14)
    private let previewSurface = NSView()
    private let previewClip = TimelinePreviewClipView()
    private let preview = TimelineBubbleContentView()
    private let progress = NSProgressIndicator()
    private let blockButton = TimelineMenuButton()
    private let revokeButton = TimelineMenuButton()
    private var reactionButtons: [TimelineMenuButton] = []
    private var actionButtons: [TimelineMenuButton] = []
    private var dividers: [NSView] = []
    private let previewCache = TimelineLayoutCache()
    private var previewIdentity: ConversationMessageStableKey?
    private var source = CGRect.zero
    private var outgoing = false
    private var controlsWidth: CGFloat = 276
    private var previewSize = CGSize.zero
    private var contentHeight: CGFloat = 0
    private var actionRowHeight: CGFloat = 63
    private var activeActionCount = 0
    private var activeReactionCount = 0
    private var showsPending = false
    private var isCleared = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { !isCleared }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Message actions"))

        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        addSubview(backdrop)
        dimmingView.wantsLayer = true
        dimmingView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        addSubview(dimmingView)
        dismissButton.setAccessibilityLabel(String(localized: "Dismiss message actions"))
        dismissButton.onPress = { [weak self] in self?.onDismiss?() }
        addSubview(dismissButton)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = documentView
        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = false
        scrollView.layer?.shadowColor = NSColor.black.withAlphaComponent(0.28).cgColor
        scrollView.layer?.shadowOpacity = 1
        scrollView.layer?.shadowRadius = 16
        scrollView.layer?.shadowOffset = CGSize(width: 0, height: -8)
        previewSurface.wantsLayer = true
        previewSurface.layer?.shadowColor = NSColor.black.cgColor
        previewSurface.layer?.shadowOpacity = 0.24
        previewSurface.layer?.shadowRadius = 14
        previewSurface.layer?.shadowOffset = CGSize(width: 0, height: -8)
        addSubview(previewSurface)
        previewSurface.addSubview(previewClip)
        // Controls stay above the independently clipped bubble. On short
        // windows they may overlap it instead of shrinking/reflowing its text.
        addSubview(reactionSurface)
        addSubview(scrollView)
        documentView.addSubview(actionSurface)
        documentView.addSubview(pendingSurface)
        previewClip.addSubview(preview)
        previewClip.setAccessibilityElement(false)
        previewClip.setAccessibilityHidden(true)
        preview.setAccessibilityHidden(true)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.setAccessibilityLabel(String(localized: "Updating reaction"))
        reactionSurface.addSubview(progress)

        blockButton.configureHorizontal(symbol: "square.and.pencil", label: String(localized: "Move back to composer"), destructive: false)
        blockButton.onPress = { [weak self] in self?.onBlock?() }
        pendingSurface.addSubview(blockButton)
        revokeButton.configureHorizontal(symbol: "trash", label: String(localized: "Revoke unsent message"), destructive: true)
        revokeButton.onPress = { [weak self] in self?.onRevoke?() }
        pendingSurface.addSubview(revokeButton)
        NotificationCenter.default.addObserver(
            self, selector: #selector(previewVisibilityChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { nil }

    func configure(
        row: TimelineMessageRow, currentUserID: Int32, context: MessageInteractionContext,
        actions: TimelineBubbleActions, mediaContext: AppMediaContext?,
        source: MessageInteractionSource, sourceRect: CGRect
    ) {
        isCleared = false
        self.source = sourceRect
        outgoing = row.isOutgoing
        let availableWidth = max(1, bounds.width - 32)
        controlsWidth = min(276, availableWidth)
        // Source layout is the sizing authority: converting bubble width back
        // into a timeline width applies media/text constraints a second time.
        let caption2 = NSFont.preferredFont(forTextStyle: .caption2)
        actionRowHeight = 63 * caption2.pointSize / 11
        let environment = source.presentation.environment
        let identityChanged = previewIdentity != row.entry.stableKey
        if identityChanged {
            previewCache.removeAll()
            preview.clear()
            previewIdentity = row.entry.stableKey
            scrollView.contentView.scroll(to: .zero)
        }
        let presentation = TimelineRowPresentation.make(
            row: .message(row), currentUserProfile: actions.currentUserProfile,
            currentUserID: currentUserID, isThreadTimeline: context.isThreadView, environment: environment)
        let layout = presentation.layoutKey == source.presentation.layoutKey
            ? source.layout : previewCache.layout(for: presentation, environment: environment)
        previewSize = layout.frames[.bubble]?.size ?? .zero
        preview.bind(TimelineRowBinding(
            presentation: presentation, layout: layout,
            context: .init(currentUserID: currentUserID, isThreadTimeline: context.isThreadView, isInteractionPreview: true),
            actions: actions, mediaContext: mediaContext), resetSelection: identityChanged)

        let policy = MessageActionPolicy(row: row, context: context)
        let isReacting = actions.pendingReactionMessageIDs.contains(row.entry.serverID ?? "")
        let eligibility = MessageReactionEligibility(
            canReact: policy.canReact && actions.toggleReaction != nil,
            isReacting: isReacting, reactions: row.entry.remoteMessage?.reactions ?? [])
        reactionSurface.isHidden = !policy.canReact
        let storage = UserDefaults.standard.string(forKey: MessageReactionPreferences.recentStorageKey)
            ?? MessageReactionPreferences.defaultRecentStorage
        let quick = policy.canReact ? MessageReactionPreferences.quick(from: storage) : []
        activeReactionCount = policy.canReact ? quick.count + 1 : 0
        while reactionButtons.count < activeReactionCount {
            let button = TimelineMenuButton()
            reactionSurface.addSubview(button, positioned: .below, relativeTo: progress)
            reactionButtons.append(button)
        }
        for (index, button) in reactionButtons.enumerated() {
            button.isHidden = index >= activeReactionCount
            button.onPress = nil
            guard index < activeReactionCount else { continue }
            if index < quick.count {
                let emoji = quick[index]
                let selected = eligibility.isSelected(emoji)
                button.configureReaction(emoji: emoji, selected: selected)
                button.isEnabled = eligibility.canToggle(emoji)
                button.alphaValue = button.isEnabled ? 1 : 0.4
                let count = row.entry.remoteMessage?.reactions.first(where: { $0.emoji == emoji && $0.count > 0 })?.count ?? 0
                let label = selected ? String(localized: "Remove reaction: \(emoji)") : String(localized: "React with: \(emoji)")
                button.setAccessibilityLabel(label + ", " + String(localized: "\(count) reactions"))
                button.setAccessibilityValue(selected ? 1 : 0)
                button.setAccessibilitySelected(selected)
                button.setAccessibilityHelp(button.isEnabled ? nil : reactionHint(eligibility: eligibility, hasCallback: actions.toggleReaction != nil))
                button.onPress = { [weak self] in self?.onReaction?(emoji) }
                button.toolTip = emoji
            } else {
                button.configureSymbol("plus", pointSize: 21)
                button.isEnabled = false
                button.alphaValue = 0.4
                button.setAccessibilityLabel(String(localized: "More reactions"))
                button.setAccessibilityValue(nil)
                button.setAccessibilitySelected(false)
                button.setAccessibilityHelp(String(localized: "Not implemented yet"))
                button.toolTip = String(localized: "Not implemented yet")
            }
        }
        if isReacting && policy.canReact { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }

        let menuActions = policy.actions
        activeActionCount = menuActions.count
        actionSurface.isHidden = menuActions.isEmpty
        while actionButtons.count < menuActions.count {
            let button = TimelineMenuButton()
            actionSurface.addSubview(button)
            actionButtons.append(button)
        }
        for (index, button) in actionButtons.enumerated() {
            button.isHidden = index >= menuActions.count
            button.onPress = nil
            guard index < menuActions.count else { continue }
            let action = menuActions[index]
            let implemented = policy.availability(of: action) == .enabled
            let available: Bool
            switch action {
            case .reply: available = actions.replyToMessage != nil
            case .edit: available = actions.editMessage != nil
            default: available = true
            }
            let label = action.label(hasAttachments: row.entry.remoteMessage?.hasAttachments == true)
            button.configureAction(symbol: action.symbol, label: label, destructive: action == .delete)
            button.isEnabled = implemented && available
            button.alphaValue = button.isEnabled ? 1 : 0.4
            let hint = implemented ? String(localized: "Unavailable") : String(localized: "Not implemented yet")
            button.toolTip = button.isEnabled ? label : hint
            button.setAccessibilityHelp(button.isEnabled ? nil : hint)
            button.onPress = { [weak self] in self?.onAction?(action) }
        }
        let dividerCount = max(0, (activeActionCount + 4) / 5 - 1)
        while dividers.count < dividerCount {
            let divider = NSView()
            divider.wantsLayer = true
            actionSurface.addSubview(divider)
            dividers.append(divider)
        }
        for (index, divider) in dividers.enumerated() {
            divider.isHidden = index >= dividerCount
            divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
        showsPending = false
        if case .pending(let pending) = row.entry, !pending.dispatchClaimed,
           actions.modifiablePendingMessageIDs.contains(pending.clientGeneratedID) {
            showsPending = true
        }
        pendingSurface.isHidden = !showsPending
        blockButton.isEnabled = actions.blockPendingMessage != nil
        revokeButton.isEnabled = actions.revokePendingMessage != nil
        blockButton.alphaValue = blockButton.isEnabled ? 1 : 0.4
        revokeButton.alphaValue = revokeButton.isEnabled ? 1 : 0.4
        blockButton.setAccessibilityHelp(blockButton.isEnabled ? nil : String(localized: "Unavailable"))
        revokeButton.setAccessibilityHelp(revokeButton.isEnabled ? nil : String(localized: "Unavailable"))
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func present() {
        layoutSubtreeIfNeeded()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for view in [backdrop, dimmingView, reactionSurface, scrollView] {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = reduceMotion ? 0.12 : 0.2
            view.layer?.add(fade, forKey: "previewAppearance")
        }
        guard !reduceMotion else { return }
        // AppKit's spring runs on the preview's compositing layer, never its
        // measured text/media frames. Source pixels lift without another layout.
        if !source.isEmpty, let layer = previewSurface.layer {
            let destination = previewSurface.frame
            let bubbleOrigin = preview.convert(CGPoint.zero, to: self)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewSurface.setFrameOrigin(CGPoint(
                x: destination.minX + source.minX - bubbleOrigin.x,
                y: destination.minY + source.minY - bubbleOrigin.y))
            let initialPosition = layer.position
            previewSurface.frame = destination
            let finalPosition = layer.position
            CATransaction.commit()
            let lift = CASpringAnimation(keyPath: "position")
            lift.mass = 1
            lift.stiffness = 360
            lift.damping = 30
            lift.fromValue = NSValue(point: initialPosition)
            lift.toValue = NSValue(point: finalPosition)
            lift.duration = lift.settlingDuration
            layer.add(lift, forKey: "previewLift")
        }
        let liftScale = CAKeyframeAnimation(keyPath: "transform.scale")
        liftScale.values = [1, 1.025, 1]
        liftScale.keyTimes = [0, 0.4, 1]
        liftScale.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        liftScale.duration = 0.42
        previewSurface.layer?.add(liftScale, forKey: "previewLiftScale")
        for view in [reactionSurface, scrollView] {
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.mass = 1
            spring.stiffness = 360
            spring.damping = 28
            spring.fromValue = 0.94
            spring.toValue = 1
            spring.duration = spring.settlingDuration
            view.layer?.add(spring, forKey: "previewControls")
        }
    }

    func dismiss(completion: @escaping @MainActor () -> Void) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduceMotion, let layer = previewSurface.layer {
            let settle = CABasicAnimation(keyPath: "transform.scale")
            settle.fromValue = layer.presentation()?.value(forKeyPath: "transform.scale") ?? 1
            settle.toValue = 0.98
            settle.duration = 0.14
            settle.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.add(settle, forKey: "previewLiftScale")
        }
        NSAnimationContext.runAnimationGroup({ animation in
            animation.duration = reduceMotion ? 0.1 : 0.14
            self.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { completion() }
        })
    }

    override func layout() {
        super.layout()
        guard !isCleared else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        backdrop.frame = bounds
        dimmingView.frame = bounds
        dismissButton.frame = bounds
        let rowCount = (activeActionCount + 4) / 5
        let gridHeight = CGFloat(rowCount) * actionRowHeight + CGFloat(max(0, rowCount - 1))
        contentHeight = gridHeight + (showsPending ? (gridHeight > 0 ? 8 : 0) + 88 : 0)
        let placement = MessageOverlayLayout(
            bounds: bounds, source: source, previewSize: previewSize,
            controlsWidth: controlsWidth, reactionHeight: reactionSurface.isHidden ? 0 : 52,
            actionsHeight: contentHeight, isOutgoing: outgoing)

        previewSurface.frame = placement.previewFrame.insetBy(dx: -8, dy: -8)
        previewClip.frame = previewSurface.bounds
        preview.frame = CGRect(
            x: 8 + (outgoing ? min(0, placement.previewFrame.width - previewSize.width) : 0),
            y: 8, width: previewSize.width, height: previewSize.height)
        reactionSurface.frame = placement.reactionFrame
        if !reactionSurface.isHidden {
            let gaps = CGFloat(max(0, activeReactionCount - 1)) * 2
            let buttonWidth = max(0, (controlsWidth - 12 - gaps) / CGFloat(max(1, activeReactionCount)))
            for index in 0..<activeReactionCount {
                reactionButtons[index].frame = CGRect(x: 6 + CGFloat(index) * (buttonWidth + 2), y: 4, width: buttonWidth, height: 44)
            }
            progress.frame = CGRect(x: (controlsWidth - 16) / 2, y: 18, width: 16, height: 16)
        }
        scrollView.frame = placement.actionsFrame
        scrollView.isHidden = contentHeight == 0
        documentView.frame = CGRect(x: 0, y: 0, width: controlsWidth, height: contentHeight)
        actionSurface.frame = CGRect(x: 0, y: 0, width: controlsWidth, height: gridHeight)
        for index in 0..<activeActionCount {
            let row = index / 5
            actionButtons[index].frame = CGRect(
                x: CGFloat(index % 5) * controlsWidth / 5,
                y: CGFloat(row) * (actionRowHeight + 1),
                width: controlsWidth / 5, height: actionRowHeight)
        }
        for index in 0..<max(0, rowCount - 1) {
            dividers[index].frame = CGRect(x: 0, y: CGFloat(index + 1) * actionRowHeight + CGFloat(index), width: controlsWidth, height: 1)
        }
        if showsPending {
            pendingSurface.frame = CGRect(x: 0, y: gridHeight + (gridHeight > 0 ? 8 : 0), width: controlsWidth, height: 88)
            blockButton.frame = CGRect(x: 0, y: 0, width: controlsWidth, height: 44)
            revokeButton.frame = CGRect(x: 0, y: 44, width: controlsWidth, height: 44)
        }
        let clip = scrollView.contentView
        let boundedY = min(max(0, clip.bounds.minY), max(0, contentHeight - clip.bounds.height))
        if boundedY != clip.bounds.minY { clip.scroll(to: NSPoint(x: 0, y: boundedY)) }
        scrollView.reflectScrolledClipView(clip)
        updatePreviewVisibility()
    }

    /// Keeps keyboard traversal inside the native modal panel without installing
    /// an application-wide key equivalent handler or consuming Command shortcuts.
    func focusNext(backward: Bool) {
        var controls = reactionButtons.prefix(activeReactionCount).filter { $0.isEnabled && !$0.isHidden }
        controls += actionButtons.prefix(activeActionCount).filter { $0.isEnabled && !$0.isHidden }
        if showsPending {
            if blockButton.isEnabled { controls.append(blockButton) }
            if revokeButton.isEnabled { controls.append(revokeButton) }
        }
        controls.append(dismissButton)
        guard let window else { return }
        let current = controls.firstIndex { $0 === window.firstResponder }
        let index = current.map { ($0 + (backward ? controls.count - 1 : 1)) % controls.count }
            ?? (backward ? controls.count - 1 : 0)
        let control = controls[index]
        if control.isDescendant(of: documentView) {
            documentView.scrollToVisible(control.convert(control.bounds, to: documentView))
        }
        window.makeFirstResponder(control)
    }

    override func cancelOperation(_ sender: Any?) { onDismiss?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDismiss?() } else { super.keyDown(with: event) }
    }

    // Scrolling outside the panel is modal, not a command to the timeline below.
    override func scrollWheel(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) { onDismiss?() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isCleared ? nil : super.hitTest(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePreviewVisibility()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for divider in dividers { divider.layer?.backgroundColor = NSColor.separatorColor.cgColor }
    }

    func clear() {
        deactivate()
        layer?.removeAllAnimations()
        for view in [backdrop, dimmingView, previewSurface, reactionSurface, scrollView] {
            view.layer?.removeAllAnimations()
        }
        preview.clear()
        previewCache.removeAll()
        previewIdentity = nil
    }

    /// Cancel work immediately while leaving decoded pixels in place for the
    /// short dismissal fade. `clear` releases the remaining payload afterwards.
    func deactivate() {
        isCleared = true
        preview.setVisible(false)
        progress.stopAnimation(nil)
        onDismiss = nil
        onReaction = nil
        onAction = nil
        onBlock = nil
        onRevoke = nil
        for button in reactionButtons + actionButtons { button.onPress = nil }
        blockButton.onPress = nil
        revokeButton.onPress = nil
        dismissButton.onPress = nil
    }

    private func reactionHint(eligibility: MessageReactionEligibility, hasCallback: Bool) -> String {
        if eligibility.isReacting { return String(localized: "Updating reaction") }
        if !hasCallback || !eligibility.canReact { return String(localized: "Unavailable") }
        if eligibility.personalLimitReached { return String(localized: "You can add up to five reactions") }
        return String(localized: "Reaction limit reached")
    }

    @objc private func previewVisibilityChanged() { updatePreviewVisibility() }

    private func updatePreviewVisibility() {
        preview.setVisible(!isCleared && window != nil && !isHiddenOrHasHiddenAncestor
            && previewSurface.frame.intersects(visibleRect))
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

private final class TimelineMenuDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class TimelinePreviewClipView: NSView {
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class TimelineMenuSurface: NSVisualEffectView {
    private let cover = NSView()
    override var isFlipped: Bool { true }

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        material = .menu
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        cover.wantsLayer = true
        cover.autoresizingMask = [.width, .height]
        addSubview(cover)
        updateColor()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        cover.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    private func updateColor() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        cover.layer?.backgroundColor = NSColor(white: dark ? 0.12 : 1, alpha: 0.65).cgColor
    }
}

/// Drawn content never installs child hit targets: NSButton retains native mouse,
/// accessibility, keyboard activation and enabled-state behavior.
private final class TimelineMenuButton: NSButton {
    var onPress: (() -> Void)?
    private enum Content {
        case empty
        case symbol
        case reaction(String, selected: Bool)
        case action(String, horizontal: Bool)
    }
    private var content = Content.empty
    private var symbol: NSImage?
    private var coloredSymbol: NSImage?
    private var destructive = false
    private let captionFont = NSFont.preferredFont(forTextStyle: .caption2)
    private var actionLabel: NSAttributedString?
    private var actionLabelWidth: CGFloat = -1
    private var actionLabelHeight: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var isEnabled: Bool {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(activate)
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { nil }

    func configureReaction(emoji: String, selected: Bool) {
        content = .reaction(emoji, selected: selected)
        symbol = selected ? NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) : nil
        destructive = false
        updateSymbolColor()
        needsDisplay = true
    }

    func configureSymbol(_ name: String, pointSize: CGFloat) {
        content = .symbol
        symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))
        destructive = false
        updateSymbolColor()
        needsDisplay = true
    }

    func configureAction(symbol name: String, label: String, destructive: Bool) {
        configureLabel(symbol: name, label: label, destructive: destructive, horizontal: false)
    }

    func configureHorizontal(symbol name: String, label: String, destructive: Bool) {
        configureLabel(symbol: name, label: label, destructive: destructive, horizontal: true)
    }

    private func configureLabel(symbol name: String, label: String, destructive: Bool, horizontal: Bool) {
        content = .action(label, horizontal: horizontal)
        symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: horizontal ? 17 : 22, weight: .regular))
        self.destructive = destructive
        setAccessibilityLabel(label)
        updateSymbolColor()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = destructive ? NSColor.systemRed : NSColor.labelColor
        if isHighlighted {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill()
        }
        switch content {
        case .empty:
            break
        case .symbol:
            drawSymbol(in: CGRect(x: (bounds.width - 21) / 2, y: (bounds.height - 21) / 2, width: 21, height: 21))
        case .reaction(let emoji, let selected):
            let diameter = min(bounds.width, bounds.height)
            let circle = CGRect(x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
            if selected {
                NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                NSBezierPath(ovalIn: circle).fill()
            }
            drawLabel(emoji, in: CGRect(x: 0, y: (bounds.height - 31) / 2, width: bounds.width, height: 31), font: .systemFont(ofSize: 24), color: color)
            if selected {
                let check = CGRect(x: circle.maxX - 12, y: circle.maxY - 12, width: 12, height: 12)
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(ovalIn: check).fill()
                drawSymbol(in: check)
            }
        case .action(let label, let horizontal):
            if horizontal {
                drawSymbol(in: CGRect(x: 12, y: (bounds.height - 18) / 2, width: 18, height: 18))
                drawLabel(label, in: CGRect(x: 38, y: (bounds.height - 20) / 2, width: max(0, bounds.width - 44), height: 20), font: .preferredFont(forTextStyle: .body), color: color, alignment: .left)
            } else {
                let labelWidth = max(0, bounds.width - 6)
                if actionLabelWidth != labelWidth {
                    actionLabelWidth = labelWidth
                    let maximumHeight = ceil(captionFont.ascender - captionFont.descender + captionFont.leading) * 2
                    actionLabelHeight = min(maximumHeight, ceil(actionLabel?.boundingRect(
                        with: CGSize(width: labelWidth, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                    ).height ?? 0))
                }
                // Center the visible icon/label stack, not an always-two-line label box.
                let top = max(2, (bounds.height - 22 - 4 - actionLabelHeight) / 2)
                drawSymbol(in: CGRect(x: (bounds.width - 22) / 2, y: top, width: 22, height: 22))
                actionLabel?.draw(
                    with: CGRect(x: 3, y: top + 26, width: labelWidth, height: actionLabelHeight),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                )
            }
        }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    private func drawLabel(_ text: String, in rect: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .center, multiline: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = multiline ? .byWordWrapping : .byTruncatingTail
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
            .draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawSymbol(in rect: CGRect) {
        coloredSymbol?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func updateSymbolColor() {
        let color: NSColor
        if case .reaction = content {
            color = .controlAccentColor
        } else {
            color = destructive ? .systemRed : .labelColor
        }
        coloredSymbol = symbol?.withSymbolConfiguration(.init(paletteColors: [color])) ?? symbol
        if case .action(let label, false) = content {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            actionLabel = NSAttributedString(
                string: label,
                attributes: [.font: captionFont, .foregroundColor: color, .paragraphStyle: paragraph]
            )
        } else {
            actionLabel = nil
        }
        actionLabelWidth = -1
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSymbolColor()
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        return accepted
    }

    @objc private func activate() {
        guard isEnabled else { return }
        onPress?()
    }
}
#endif
