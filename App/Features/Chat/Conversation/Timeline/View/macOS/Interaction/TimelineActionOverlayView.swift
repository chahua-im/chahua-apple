#if os(macOS)
    import AppKit
    import CoreImage
    import ChahuaAPI
    import QuartzCore
    import SwiftUI

    /// Native capture preserves the exact text/media presentation without moving a
    /// reusable row. AppKit owns the modal event/accessibility tree above the capture;
    /// a SwiftUI material alone cannot blur the entire window at a specified radius.
    @MainActor
    final class TimelineActionOverlayView: NSView, NSPopoverDelegate {
        private static let snapshotContext = CIContext(options: [.cacheIntermediates: false])
        var onDismiss: (() -> Void)?
        var onReaction: ((String) -> Void)?
        var onAction: ((MessageMenuAction) -> Void)?
        var onEditPending: (() -> Void)?
        var onRemovePending: (() -> Void)?

        private let dismissButton = TimelineMenuButton()
        private let actionsContainer = TimelineMenuDocumentView()
        private let backdrop = NSImageView()
        private let dimming = NSView()
        private let previewViewport = TimelineMenuPreviewView()
        private let preview = TimelineMenuPreviewImageView()
        private let previewMask = CAShapeLayer()
        private let reactionSurface = TimelineMenuSurface(cornerRadius: MessageMenuLayout.radius)
        private let actionSurface = TimelineMenuSurface(cornerRadius: MessageMenuLayout.radius)
        private let pendingSurface = TimelineMenuSurface(cornerRadius: MessageMenuLayout.radius)
        private let progress = NSProgressIndicator()
        private var pickerView: TimelineReactionPickerView?
        private var pickerPlaceholder: NSView?
        private var pickerPopover: NSPopover?
        private var pickerOpensAbove = false
        private var reactionEligibility: MessageReactionEligibility?
        var isShowingReactionPicker: Bool { pickerPopover != nil }
        private let editPendingButton = TimelineMenuButton()
        private let removePendingButton = TimelineMenuButton()
        private var reactionButtons: [TimelineMenuButton] = []
        private var actionButtons: [TimelineMenuButton] = []
        private let pageButton = TimelineMenuButton()
        private var menuPage = 0
        private var menuActions: [MessageMenuAction] = []
        private var orderedActionButtons: [TimelineMenuButton] = []
        private var rebuildActions: (() -> Void)?
        private var pressPoint: CGPoint?
        private var previewFrame = CGRect.zero
        private var messageIdentity: ConversationMessageStableKey?
        private var source = CGRect.zero
        private var previewCaptureBounds = CGRect.zero
        private var outgoing = false
        private var controlsWidth: CGFloat = 276
        private var contentHeight: CGFloat = 0
        private var actionRowHeight: CGFloat = 63
        private var activeActionCount = 0
        private var activeReactionCount = 0
        private var pendingButtonCount: Int {
            (editPendingButton.isEnabled ? 1 : 0) + (removePendingButton.isEnabled ? 1 : 0)
        }
        private var isCleared = false

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { !isCleared }
        override var mouseDownCanMoveWindow: Bool { false }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true
            setAccessibilityElement(false)
            for image in [backdrop, preview] {
                image.imageScaling = .scaleAxesIndependently
                image.wantsLayer = true
                image.setAccessibilityElement(false)
            }
            addSubview(backdrop)
            dimming.wantsLayer = true
            dimming.setAccessibilityElement(false)
            addSubview(dimming)
            previewViewport.wantsLayer = true
            previewViewport.layer?.masksToBounds = true
            previewViewport.addSubview(preview)
            preview.layer?.mask = previewMask
            setAccessibilityRole(.group)
            previewViewport.setAccessibilityElement(true)
            previewViewport.setAccessibilityRole(.image)
            setAccessibilityLabel(AppLanguage.localized("Message actions"))

            dismissButton.setAccessibilityLabel(AppLanguage.localized("Dismiss message actions"))
            dismissButton.onPress = { [weak self] in self?.onDismiss?() }
            addSubview(dismissButton)

            actionsContainer.wantsLayer = true
            actionsContainer.layer?.shadowColor = NSColor.black.cgColor
            actionsContainer.layer?.shadowOpacity = 0.12
            actionsContainer.layer?.shadowRadius = 20
            actionsContainer.layer?.shadowOffset = CGSize(width: 0, height: -4)
            addSubview(actionsContainer)
            addSubview(reactionSurface)
            addSubview(previewViewport, positioned: .below, relativeTo: actionsContainer)
            reactionSurface.wantsLayer = true
            reactionSurface.layer?.shadowColor = NSColor.black.cgColor
            reactionSurface.layer?.shadowOpacity = 0.12
            reactionSurface.layer?.shadowRadius = 20
            reactionSurface.layer?.shadowOffset = CGSize(width: 0, height: -4)
            actionSurface.addSubview(pageButton)
            actionsContainer.addSubview(actionSurface)
            actionsContainer.addSubview(pendingSurface)
            progress.style = .spinning
            progress.controlSize = .small
            progress.isDisplayedWhenStopped = false
            progress.setAccessibilityLabel(AppLanguage.localized("Updating reaction"))
            reactionSurface.addSubview(progress)

            editPendingButton.configureHorizontal(
                symbol: "square.and.pencil", label: AppLanguage.localized("Edit queued message"),
                destructive: false)
            editPendingButton.onPress = { [weak self] in self?.onEditPending?() }
            pendingSurface.addSubview(editPendingButton)
            removePendingButton.configureHorizontal(
                symbol: "trash", label: AppLanguage.localized("Remove from Outbox"),
                destructive: true)
            removePendingButton.onPress = { [weak self] in self?.onRemovePending?() }
            pendingSurface.addSubview(removePendingButton)
        }

        /// Capture before insertion, so neither image can recursively contain the menu.
        func capturePresentation(
            content: NSView, timeline: NSView, sourceRect: CGRect, sourceContour: CGPath
        ) {
            let captureBounds = Self.captureBounds(for: sourceRect, contour: sourceContour)
            let captureRect = CGRect(
                origin: CGPoint(
                    x: sourceRect.minX + captureBounds.minX,
                    y: sourceRect.minY + captureBounds.minY),
                size: captureBounds.size)
            let rect =
                content.isFlipped
                ? captureRect
                : CGRect(
                    x: captureRect.minX, y: content.bounds.maxY - captureRect.maxY,
                    width: captureRect.width, height: captureRect.height)
            let bubble = timeline.convert(rect, from: content)
            if let bitmap = timeline.bitmapImageRepForCachingDisplay(in: bubble) {
                timeline.cacheDisplay(in: bubble, to: bitmap)
                let image = NSImage(size: captureBounds.size)
                image.addRepresentation(bitmap)
                preview.image = image
            }
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)
            {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                if let input = CIImage(bitmapImageRep: bitmap) {
                    let scale = CGFloat(bitmap.pixelsWide) / max(1, content.bounds.width)
                    let blurred = input.clampedToExtent().applyingFilter(
                        "CIGaussianBlur", parameters: [kCIInputRadiusKey: 10 * scale]
                    )
                    .cropped(to: input.extent)
                    if let cgImage = Self.snapshotContext.createCGImage(blurred, from: input.extent)
                    {
                        backdrop.image = NSImage(cgImage: cgImage, size: content.bounds.size)
                    }
                }
            }
            updateBackdrop()
        }

        /// The droplet tail is rendered outside the measured bubble body. Round
        /// outward before translating its curved contour so floating-point curve
        /// extrema cannot land beyond a tightly fitted capture/mask boundary.
        private static func captureBounds(for sourceRect: CGRect, contour: CGPath) -> CGRect {
            CGRect(origin: .zero, size: sourceRect.size).union(contour.boundingBoxOfPath).integral
        }

        required init?(coder: NSCoder) { nil }

        func configure(
            row: TimelineMessageRow, context: MessageInteractionContext,
            actions: TimelineBubbleActions, sourceRect: CGRect, sourceContour: CGPath,
            pressPoint: CGPoint? = nil
        ) {
            isCleared = false
            self.source = sourceRect
            self.pressPoint = pressPoint
            previewCaptureBounds = Self.captureBounds(for: sourceRect, contour: sourceContour)
            var contourTransform = CGAffineTransform(
                translationX: -previewCaptureBounds.minX, y: -previewCaptureBounds.minY)
            previewMask.path = sourceContour.copy(using: &contourTransform)
            outgoing = row.isOutgoing
            controlsWidth = min(MessageMenuLayout.width, max(1, bounds.width - 32))
            actionRowHeight = MessageMenuLayout.rowHeight
            if messageIdentity != row.entry.stableKey {
                messageIdentity = row.entry.stableKey
                menuPage = 0
            }

            let policy = MessageActionPolicy(row: row, context: context)
            let isReacting = actions.isReacting(to: row.entry)
            let eligibility = MessageReactionEligibility(
                canReact: policy.canReact && actions.toggleReaction != nil,
                isReacting: isReacting, reactions: row.entry.remoteMessage?.reactions ?? [])
            previewViewport.setAccessibilityLabel(
                row.entry.clipboardText ?? AppLanguage.localized("Message preview"))
            reactionEligibility = eligibility
            if isShowingReactionPicker && !eligibility.canReact {
                onDismiss?()
                return
            }
            reactionSurface.isHidden = !policy.canReact
            let storage =
                UserDefaults.standard.string(forKey: MessageReactionPreferences.recentStorageKey)
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
                    button.alphaValue = button.isEnabled ? 1 : 0.5
                    let count =
                        row.entry.remoteMessage?.reactions.first(where: {
                            $0.emoji == emoji && $0.count > 0
                        })?.count ?? 0
                    let label =
                        selected
                        ? AppLanguage.localized("Remove reaction: \(emoji)")
                        : AppLanguage.localized("React with: \(emoji)")
                    button.setAccessibilityLabel(
                        label + ", " + AppLanguage.localized("\(count) reactions"))
                    button.setAccessibilityValue(selected ? 1 : 0)
                    button.setAccessibilitySelected(selected)
                    button.setAccessibilityHelp(
                        button.isEnabled
                            ? nil
                            : reactionHint(
                                eligibility: eligibility, hasCallback: actions.toggleReaction != nil
                            ))
                    button.onPress = { [weak self] in self?.onReaction?(emoji) }
                    button.toolTip = emoji
                } else {
                    button.configureSymbol("plus", pointSize: 26)
                    button.isHidden = eligibility.distinctLimitReached
                    // At the distinct-message limit, selected quick reactions remain
                    // removable, but the full picker is no longer offered.
                    button.isEnabled =
                        eligibility.canReact && !eligibility.isReacting
                        && !eligibility.distinctLimitReached
                    button.alphaValue = button.isEnabled ? 1 : 0.5
                    button.setAccessibilityLabel(AppLanguage.localized("More reactions"))
                    button.setAccessibilityValue(nil)
                    button.setAccessibilitySelected(false)
                    button.setAccessibilityHelp(
                        button.isEnabled
                            ? nil
                            : reactionHint(
                                eligibility: eligibility, hasCallback: actions.toggleReaction != nil
                            ))
                    button.toolTip = AppLanguage.localized("More reactions")
                    button.onPress = { [weak self] in self?.showReactionPicker() }
                }
            }
            if isReacting && policy.canReact {
                progress.startAnimation(nil)
            } else {
                progress.stopAnimation(nil)
            }

            menuActions = policy.actions
            rebuildActions = { [weak self] in
                self?.configureActions(row: row, context: context, actions: actions, policy: policy)
            }
            rebuildActions?()
            if case .pending(let pending) = row.entry {
                editPendingButton.isEnabled = actions.canEditPendingMessage(pending)
                removePendingButton.isEnabled = actions.canRemovePendingMessage(pending)
            } else {
                editPendingButton.isEnabled = false
                removePendingButton.isEnabled = false
            }
            editPendingButton.isHidden = !editPendingButton.isEnabled
            removePendingButton.isHidden = !removePendingButton.isEnabled
            pendingSurface.isHidden = pendingButtonCount == 0
            if let pickerView {
                reactionSurface.isHidden = true
                actionsContainer.isHidden = true
                progress.stopAnimation(nil)
                pickerView.update(eligibility: eligibility)
            }
            needsLayout = true
            layoutSubtreeIfNeeded()
        }

        private func configureActions(
            row: TimelineMessageRow, context: MessageInteractionContext,
            actions: TimelineBubbleActions, policy: MessageActionPolicy
        ) {
            let page = MessageMenuPage(actions: menuActions, page: menuPage)
            menuPage = page.page
            activeActionCount = page.actions.count
            actionSurface.isHidden = menuActions.isEmpty
            while actionButtons.count < activeActionCount {
                let button = TimelineMenuButton()
                actionSurface.addSubview(button)
                actionButtons.append(button)
            }
            for (index, button) in actionButtons.enumerated() {
                button.isHidden = index >= activeActionCount
                button.onPress = nil
            }
            for (index, action) in page.actions.enumerated() {
                let button = actionButtons[index]
                let available: Bool
                switch action {
                case .reply: available = actions.replyToMessage != nil
                case .edit: available = actions.editMessage != nil
                case .delete: available = actions.deleteMessage != nil
                case .thread: available = actions.openThread != nil
                case .reactionDetails: available = actions.openReactionDetails != nil
                case .select: available = actions.toggleMessageSelection != nil
                case .forward: available = actions.forwardMessage != nil
                case .save: available = actions.toggleSavedMessage != nil
                case .favorite:
                    available =
                        actions.toggleStickerFavorite != nil
                        && !(row.entry.remoteMessage?.sticker.map {
                            actions.pendingStickerIDs.contains($0.id)
                        } ?? false)
                case .toSticker: available = actions.addMessageToStickerPack != nil
                default: available = true
                }
                let label = action.label(
                    isSaved: context.isSaved, isFavorite: context.isFavoriteSticker)
                button.configureAction(
                    symbol: action.symbol(
                        isSaved: context.isSaved, isFavorite: context.isFavoriteSticker),
                    label: label, destructive: action == .delete)
                button.isEnabled = policy.availability(of: action) == .enabled && available
                button.alphaValue = button.isEnabled ? 1 : 0.5
                button.toolTip = button.isEnabled ? label : AppLanguage.localized("Unavailable")
                button.setAccessibilityHelp(
                    button.isEnabled ? nil : AppLanguage.localized("Unavailable"))
                let selected =
                    (action == .save && context.isSaved)
                    || (action == .favorite && context.isFavoriteSticker) || action == .unpin
                button.setAccessibilitySelected(selected)
                button.setAccessibilityValue(selected ? 1 : 0)
                button.onPress = { [weak self] in self?.onAction?(action) }
            }
            pageButton.isHidden = !page.hasNavigation
            pageButton.configureSymbol(
                page.navigationSymbol, pointSize: MessageMenuLayout.actionIcon)
            pageButton.setAccessibilityLabel(page.navigationLabel)
            pageButton.toolTip = page.navigationLabel
            orderedActionButtons.removeAll(keepingCapacity: true)
            for index in 0..<activeActionCount {
                if page.navigationSlot == index { orderedActionButtons.append(pageButton) }
                orderedActionButtons.append(actionButtons[index])
            }
            if page.navigationSlot == activeActionCount { orderedActionButtons.append(pageButton) }
            actionSurface.setAccessibilityChildren(orderedActionButtons)
            pageButton.onPress = { [weak self] in
                guard let self, !self.isCleared else { return }
                self.menuPage = page.nextPage
                self.rebuildActions?()
                self.needsLayout = true
                self.layoutSubtreeIfNeeded()
                self.window?.makeFirstResponder(self.pageButton)
            }
        }

        func present() {
            layoutSubtreeIfNeeded()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.1 : 0.18
            layer?.add(fade, forKey: "menuFade")
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            for view in [reactionSurface, actionsContainer, preview] {
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = 0.92
                scale.toValue = 1
                scale.duration = 0.18
                scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.layer?.add(scale, forKey: "menuScale")
                let slide = CABasicAnimation(keyPath: "position")
                slide.fromValue = NSValue(
                    point: CGPoint(
                        x: (view.layer?.position.x ?? 0) + source.minX - previewFrame.minX,
                        y: (view.layer?.position.y ?? 0) + source.minY - previewFrame.minY))
                slide.toValue = view.layer.map { NSValue(point: $0.position) }
                slide.duration = 0.18
                slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.layer?.add(slide, forKey: "menuSlide")
            }
        }

        func dismiss(completion: @escaping @MainActor () -> Void) {
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if !reduceMotion {
                for view in [reactionSurface, actionsContainer, preview] {
                    let scale = CABasicAnimation(keyPath: "transform.scale")
                    scale.fromValue =
                        view.layer?.presentation()?.value(forKeyPath: "transform.scale") ?? 1
                    scale.toValue = 0.92
                    scale.duration = 0.12
                    scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    view.layer?.add(scale, forKey: "menuScale")
                }
            }
            NSAnimationContext.runAnimationGroup(
                { animation in
                    animation.duration = reduceMotion ? 0.1 : 0.12
                    self.animator().alphaValue = 0
                },
                completionHandler: {
                    MainActor.assumeIsolated { completion() }
                })
        }

        override func layout() {
            super.layout()
            guard !isCleared else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            dismissButton.frame = bounds
            backdrop.frame = bounds
            dimming.frame = bounds
            previewViewport.frame = bounds
            if let placeholder = pickerPlaceholder {
                layoutReactionPlaceholder(placeholder)
                return
            }
            let page = MessageMenuPage(actions: menuActions, page: menuPage)
            let slots = page.hasNavigation ? 10 : activeActionCount
            let rowCount = (slots + 4) / 5
            let padding = MessageMenuLayout.padding
            let gridHeight = rowCount > 0 ? CGFloat(rowCount) * actionRowHeight + padding * 2 : 0
            let pendingHeight = CGFloat(pendingButtonCount) * 44
            contentHeight =
                gridHeight + (pendingHeight > 0 && gridHeight > 0 ? 8 : 0)
                + pendingHeight
            let geometry = MessageOverlayLayout(
                bounds: bounds, source: source, previewSize: source.size,
                controlsWidth: controlsWidth,
                reactionHeight: reactionSurface.isHidden ? 0 : MessageMenuLayout.reactionHeight,
                actionsHeight: contentHeight, isOutgoing: outgoing, pressPoint: pressPoint)
            previewFrame = geometry.previewFrame
            preview.frame = CGRect(
                x: previewFrame.minX + previewCaptureBounds.minX,
                y: previewFrame.minY + previewCaptureBounds.minY,
                width: previewCaptureBounds.width, height: previewCaptureBounds.height)
            previewMask.frame = preview.bounds
            reactionSurface.frame = geometry.reactionFrame
            if !reactionSurface.isHidden {
                let buttonWidth = max(
                    0,
                    (controlsWidth - padding * 2)
                        / CGFloat(max(1, activeReactionCount)))
                for index in 0..<activeReactionCount {
                    reactionButtons[index].frame = CGRect(
                        x: padding + CGFloat(index) * buttonWidth, y: padding,
                        width: buttonWidth, height: MessageMenuLayout.reactionTarget)
                }
                progress.frame = CGRect(x: (controlsWidth - 16) / 2, y: 20, width: 16, height: 16)
                reactionSurface.layer?.shadowPath =
                    reactionSurface.outline(
                        in: reactionSurface.bounds
                    ).cgPath
            }
            actionsContainer.frame = geometry.actionsFrame
            actionsContainer.isHidden = contentHeight == 0
            actionSurface.frame = CGRect(x: 0, y: 0, width: controlsWidth, height: gridHeight)
            let cellWidth = max(0, (controlsWidth - padding * 2) / 5)
            func cell(_ slot: Int) -> CGRect {
                CGRect(
                    x: padding + CGFloat(slot % 5) * cellWidth,
                    y: padding + CGFloat(slot / 5) * actionRowHeight,
                    width: cellWidth, height: actionRowHeight)
            }
            for index in 0..<activeActionCount {
                let slot = page.page == 1 && index >= 4 ? index + 1 : index
                actionButtons[index].frame = cell(slot)
            }
            if let slot = page.navigationSlot { pageButton.frame = cell(slot) }
            if pendingHeight > 0 {
                let pendingY = gridHeight + (gridHeight > 0 ? 8 : 0)
                pendingSurface.frame = CGRect(
                    x: 0, y: pendingY, width: controlsWidth, height: pendingHeight)
                editPendingButton.frame = CGRect(x: 0, y: 0, width: controlsWidth, height: 44)
                removePendingButton.frame = CGRect(
                    x: 0, y: editPendingButton.isEnabled ? 44 : 0,
                    width: controlsWidth, height: 44)
            }
            var shadow = Path()
            for surface in [actionSurface, pendingSurface] where !surface.isHidden {
                shadow.addPath(surface.outline(in: surface.frame))
            }
            actionsContainer.layer?.shadowPath = shadow.cgPath
        }

        /// Keeps keyboard traversal inside the native modal panel without installing
        /// an application-wide key equivalent handler or consuming Command shortcuts.
        @discardableResult
        func focusNext(backward: Bool) -> Bool {
            // Let AppKit traverse the native category, search and emoji controls.
            // The menu's flat button list must not consume their Tab events.
            guard !isShowingReactionPicker else { return false }
            var controls = reactionButtons.prefix(activeReactionCount).filter {
                $0.isEnabled && !$0.isHidden
            }
            controls += orderedActionButtons.filter { $0.isEnabled && !$0.isHidden }
            if editPendingButton.isEnabled { controls.append(editPendingButton) }
            if removePendingButton.isEnabled { controls.append(removePendingButton) }
            controls.append(dismissButton)
            guard let window else { return false }
            let current = controls.firstIndex { $0 === window.firstResponder }
            let index =
                current.map { ($0 + (backward ? controls.count - 1 : 1)) % controls.count }
                ?? (backward ? controls.count - 1 : 0)
            let control = controls[index]
            window.makeFirstResponder(control)
            return true
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

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateBackdrop()
        }

        func clear() {
            deactivate()
            layer?.removeAllAnimations()
            for view in [reactionSurface, actionsContainer, preview] {
                view.layer?.removeAllAnimations()
            }
            messageIdentity = nil
            backdrop.image = nil
            preview.image = nil
        }

        /// Disable callbacks during the short menu dismissal transition.
        func deactivate() {
            isCleared = true
            progress.stopAnimation(nil)
            onDismiss = nil
            onReaction = nil
            onAction = nil
            onEditPending = nil
            onRemovePending = nil
            for button in reactionButtons + actionButtons { button.onPress = nil }
            editPendingButton.onPress = nil
            removePendingButton.onPress = nil
            dismissButton.onPress = nil
            // Programmatic dismissal must not enter the delegate's user-cancel
            // path, which would otherwise re-enter the controller while closing.
            pickerPopover?.delegate = nil
            pickerPopover?.close()
            pickerPopover?.contentViewController = nil
            pickerPopover = nil
            pickerView?.deactivate()
            pickerView = nil
            pickerPlaceholder?.removeFromSuperview()
            pickerPlaceholder = nil
            reactionEligibility = nil
            nextKeyView = nil
            rebuildActions = nil
            pageButton.onPress = nil
            menuActions.removeAll()
        }

        private func updateBackdrop() {
            let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            backdrop.isHidden = opaque
            dimming.layer?.backgroundColor =
                opaque
                ? NSColor.windowBackgroundColor.cgColor
                : NSColor(red: 34 / 255, green: 36 / 255, blue: 40 / 255, alpha: 0.25).cgColor
        }

        /// The popover's auxiliary window is part of this interaction, not a
        /// switch to an unrelated chat window.
        func ownsInteractionWindow(_ candidate: NSWindow?) -> Bool {
            guard let candidate else { return false }
            return candidate === window || pickerView?.ownsInteractionWindow(candidate) == true
        }

        func popoverDidClose(_ notification: Notification) {
            guard let popover = notification.object as? NSPopover,
                popover === pickerPopover, !isCleared
            else { return }
            // Keep picker state until the controller deactivates the overlay.
            // Closing the native window cancels the entire interaction; it must
            // never reveal or rebuild the previous quick-reaction menu.
            onDismiss?()
        }

        private func showReactionPicker() {
            guard !isCleared, pickerPopover == nil, let reactionEligibility,
                reactionEligibility.canReact, !reactionEligibility.isReacting,
                !reactionEligibility.distinctLimitReached, window != nil
            else { return }
            // Replace both quick panels at their existing anchor; never re-open the
            // timeline menu behind a dismissed full picker.
            let placeholder = NSView(frame: reactionSurface.frame)
            placeholder.setAccessibilityElement(false)
            pickerPlaceholder = placeholder
            addSubview(placeholder)

            let picker = TimelineReactionPickerView(eligibility: reactionEligibility)
            picker.onSelect = { [weak self] emoji in
                guard let self, !self.isCleared else { return }
                self.onReaction?(emoji)
            }
            picker.onClose = { [weak self] in self?.onDismiss?() }
            picker.autoresizingMask = [.width, .height]
            let controller = NSViewController()
            controller.view = picker
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.contentViewController = controller
            popover.delegate = self
            pickerView = picker
            pickerPopover = popover
            reactionSurface.isHidden = true
            actionsContainer.isHidden = true
            progress.stopAnimation(nil)
            needsLayout = true
            layoutSubtreeIfNeeded()
            popover.show(
                relativeTo: placeholder.bounds, of: placeholder,
                preferredEdge: pickerOpensAbove ? .minY : .maxY)
            picker.window?.recalculateKeyViewLoop()
            picker.focusSearch()
        }

        private func layoutReactionPlaceholder(
            _ placeholder: NSView
        ) {
            placeholder.frame = reactionSurface.frame
            guard let window, let screen = window.screen, let popover = pickerPopover else {
                return
            }
            let visible = screen.visibleFrame.insetBy(dx: 16, dy: 16)
            let anchor = window.convertToScreen(placeholder.convert(placeholder.bounds, to: nil))
            let screenBelow = max(0, anchor.minY - visible.minY)
            let screenAbove = max(0, visible.maxY - anchor.maxY)
            pickerOpensAbove = screenAbove >= 380 || screenAbove > screenBelow
            let verticalSpace =
                pickerOpensAbove ? screenAbove : screenBelow
            // Native chrome and pointer lie outside the picker content size.
            popover.contentSize = NSSize(
                width: min(360, max(1, visible.width)),
                height: min(360, max(1, verticalSpace - 20)))
            if popover.isShown {
                popover.show(
                    relativeTo: placeholder.bounds, of: placeholder,
                    preferredEdge: pickerOpensAbove ? .minY : .maxY)
            }
        }

        private func reactionHint(eligibility: MessageReactionEligibility, hasCallback: Bool)
            -> String
        {
            if eligibility.isReacting { return AppLanguage.localized("Updating reaction") }
            if !hasCallback || !eligibility.canReact { return AppLanguage.localized("Unavailable") }
            if eligibility.personalLimitReached {
                return AppLanguage.localized("You can add up to five reactions")
            }
            return AppLanguage.localized("Reaction limit reached")
        }

    }

    private final class TimelineMenuDocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    private final class TimelineMenuPreviewView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// The source contour uses the flipped bubble view's top-origin coordinates.
    /// NSImageView is otherwise bottom-origin, which moves its tail mask to the
    /// opposite corner and exposes captured timeline pixels above the bubble.
    private final class TimelineMenuPreviewImageView: NSImageView {
        override var isFlipped: Bool { true }
    }

    /// Matte native backing keeps the same compact appearance on every OS version.
    private final class TimelineMenuSurface: NSView {
        private let cornerRadius: CGFloat
        override var isFlipped: Bool { true }

        init(cornerRadius: CGFloat) {
            self.cornerRadius = cornerRadius
            super.init(frame: .zero)
            wantsLayer = true
            // The panels are deliberately opaque; only the full-window capture blurs.
            layer?.cornerRadius = cornerRadius
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
            updateColor()
        }

        required init?(coder: NSCoder) { nil }

        func outline(in rect: CGRect) -> Path {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: rect)
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColor()
        }

        private func updateColor() {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            layer?.backgroundColor = NSColor(white: dark ? 0.12 : 1, alpha: 1).cgColor
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
        private var symbolSize: CGFloat = 26
        private var destructive = false
        private let captionFont = NSFont.systemFont(ofSize: MessageMenuLayout.labelSize)
        private var actionLabel: NSAttributedString?
        private var actionLabelWidth: CGFloat = -1
        private var hoverArea: NSTrackingArea?
        private var hovered = false

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
            symbol = nil
            destructive = false
            updateSymbolColor()
            needsDisplay = true
        }

        func configureSymbol(_ name: String, pointSize: CGFloat) {
            content = .symbol
            symbolSize = pointSize
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

        private func configureLabel(
            symbol name: String, label: String, destructive: Bool, horizontal: Bool
        ) {
            content = .action(label, horizontal: horizontal)
            symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    .init(
                        pointSize: horizontal ? 17 : MessageMenuLayout.actionIcon, weight: .regular)
                )
            self.destructive = destructive
            setAccessibilityLabel(label)
            updateSymbolColor()
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            if case .empty = content { return }
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let color =
                destructive
                ? (dark
                    ? NSColor.systemRed
                    : NSColor(red: 197 / 255, green: 0, blue: 15 / 255, alpha: 1))
                : NSColor.labelColor
            if isEnabled && (isHighlighted || hovered) {
                NSColor(white: dark ? 0.23 : 0.96, alpha: 1).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
            }
            switch content {
            case .empty:
                break
            case .symbol:
                drawSymbol(
                    in: CGRect(
                        x: (bounds.width - symbolSize) / 2, y: (bounds.height - symbolSize) / 2,
                        width: symbolSize, height: symbolSize))
            case .reaction(let emoji, let selected):
                if selected {
                    NSColor(white: dark ? 0.23 : 0.96, alpha: 1).setFill()
                    NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
                }
                drawLabel(
                    emoji,
                    in: CGRect(x: 0, y: (bounds.height - 35) / 2, width: bounds.width, height: 35),
                    font: .systemFont(ofSize: 28), color: color)
            case .action(let label, let horizontal):
                if horizontal {
                    drawSymbol(
                        in: CGRect(x: 12, y: (bounds.height - 18) / 2, width: 18, height: 18))
                    drawLabel(
                        label,
                        in: CGRect(
                            x: 38, y: (bounds.height - 20) / 2, width: max(0, bounds.width - 44),
                            height: 20), font: .preferredFont(forTextStyle: .body), color: color,
                        alignment: .left)
                } else {
                    let labelWidth = max(1, bounds.width - 2)
                    if actionLabelWidth != labelWidth {
                        actionLabelWidth = labelWidth
                        let naturalWidth = (label as NSString).size(
                            withAttributes: [.font: captionFont]).width
                        let font = NSFont.systemFont(
                            ofSize: MessageMenuLayout.labelSize
                                * min(1, labelWidth / max(1, naturalWidth)))
                        let paragraph = NSMutableParagraphStyle()
                        paragraph.alignment = .center
                        paragraph.lineBreakMode = .byClipping
                        actionLabel = NSAttributedString(
                            string: label,
                            attributes: [
                                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
                            ])
                    }
                    let icon = MessageMenuLayout.actionIcon
                    let top =
                        (bounds.height - icon - MessageMenuLayout.labelGap
                            - MessageMenuLayout.labelLineHeight) / 2
                    drawSymbol(
                        in: CGRect(
                            x: (bounds.width - icon) / 2, y: top, width: icon, height: icon))
                    actionLabel?.draw(
                        in: CGRect(
                            x: 1, y: top + icon + MessageMenuLayout.labelGap,
                            width: labelWidth, height: MessageMenuLayout.labelLineHeight))
                }
            }
            if window?.firstResponder === self {
                NSColor.keyboardFocusIndicatorColor.setStroke()
                let ring = NSBezierPath(
                    roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7)
                ring.lineWidth = 2
                ring.stroke()
            }
        }

        private func drawLabel(
            _ text: String, in rect: CGRect, font: NSFont, color: NSColor,
            alignment: NSTextAlignment = .center, multiline: Bool = false
        ) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = multiline ? .byWordWrapping : .byTruncatingTail
            NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            )
            .draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }

        private func drawSymbol(in rect: CGRect) {
            guard let coloredSymbol else { return }
            coloredSymbol.draw(
                in: MessageMenuLayout.symbolRect(for: coloredSymbol.size, in: rect),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        private func updateSymbolColor() {
            let color: NSColor
            if case .reaction = content {
                color = .controlAccentColor
            } else {
                let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                color =
                    destructive
                    ? (dark
                        ? .systemRed : NSColor(red: 197 / 255, green: 0, blue: 15 / 255, alpha: 1))
                    : .labelColor
            }
            coloredSymbol = symbol?.withSymbolConfiguration(.init(paletteColors: [color])) ?? symbol
            actionLabel = nil
            actionLabelWidth = -1
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverArea { removeTrackingArea(hoverArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self)
            addTrackingArea(area)
            hoverArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            hovered = true
            needsDisplay = true
        }

        override func mouseExited(with event: NSEvent) {
            hovered = false
            needsDisplay = true
        }

        override func keyDown(with event: NSEvent) {
            if [36, 49, 76].contains(event.keyCode),
                event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            {
                activate()
            } else {
                super.keyDown(with: event)
            }
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
