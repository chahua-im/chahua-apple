#if os(macOS)
    import AppKit
    import ChahuaAPI
    import QuartzCore
    import SwiftUI

    /// Desktop context menu: the original message stays in the timeline. Only the
    /// compact reaction/action surfaces use menu material, never the window backdrop.
    @MainActor
    final class TimelineActionOverlayView: NSView, NSPopoverDelegate {
        var onDismiss: (() -> Void)?
        var onReaction: ((String) -> Void)?
        var onAction: ((MessageMenuAction) -> Void)?
        var onBlock: (() -> Void)?
        var onRevoke: (() -> Void)?

        private let dismissButton = TimelineMenuButton()
        private let scrollView = NSScrollView()
        private let documentView = TimelineMenuDocumentView()
        private let reactionSurface = TimelineMenuSurface(cornerRadius: 26, opaque: true)
        private let actionSurface = TimelineMenuSurface(cornerRadius: 14)
        private let pendingSurface = TimelineMenuSurface(cornerRadius: 14)
        private let progress = NSProgressIndicator()
        private let sourceHighlight = CAShapeLayer()
        private var pickerHost: NSHostingView<ReactionEmojiKeyboard>?
        private var pickerPlaceholderHost: NSHostingView<ReactionPickerPlaceholder>?
        private var pickerPopover: NSPopover?
        private var reactionEligibility: MessageReactionEligibility?
        var isShowingReactionPicker: Bool { pickerPopover != nil }
        private let blockButton = TimelineMenuButton()
        private let revokeButton = TimelineMenuButton()
        private var reactionButtons: [TimelineMenuButton] = []
        private var actionButtons: [TimelineMenuButton] = []
        private var dividers: [NSView] = []
        private var messageIdentity: ConversationMessageStableKey?
        private var source = CGRect.zero
        private var outgoing = false
        private var controlsWidth: CGFloat = 276
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
            sourceHighlight.lineWidth = 2
            layer?.addSublayer(sourceHighlight)
            updateSourceHighlight()
            setAccessibilityRole(.group)
            setAccessibilityLabel(AppLanguage.localized("Message actions"))

            dismissButton.setAccessibilityLabel(AppLanguage.localized("Dismiss message actions"))
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
            addSubview(scrollView)
            addSubview(reactionSurface)
            documentView.addSubview(actionSurface)
            documentView.addSubview(pendingSurface)
            progress.style = .spinning
            progress.controlSize = .small
            progress.isDisplayedWhenStopped = false
            progress.setAccessibilityLabel(AppLanguage.localized("Updating reaction"))
            reactionSurface.addSubview(progress)

            blockButton.configureHorizontal(
                symbol: "square.and.pencil", label: AppLanguage.localized("Move back to composer"),
                destructive: false)
            blockButton.onPress = { [weak self] in self?.onBlock?() }
            pendingSurface.addSubview(blockButton)
            revokeButton.configureHorizontal(
                symbol: "trash", label: AppLanguage.localized("Revoke unsent message"),
                destructive: true)
            revokeButton.onPress = { [weak self] in self?.onRevoke?() }
            pendingSurface.addSubview(revokeButton)
        }

        required init?(coder: NSCoder) { nil }

        func configure(
            row: TimelineMessageRow, context: MessageInteractionContext,
            actions: TimelineBubbleActions, sourceRect: CGRect
        ) {
            isCleared = false
            self.source = sourceRect
            outgoing = row.isOutgoing
            let availableWidth = max(1, bounds.width - 32)
            controlsWidth = min(276, availableWidth)
            let caption2 = NSFont.preferredFont(forTextStyle: .caption2)
            actionRowHeight = 63 * caption2.pointSize / 11
            if messageIdentity != row.entry.stableKey {
                messageIdentity = row.entry.stableKey
                scrollView.contentView.scroll(to: .zero)
            }

            let policy = MessageActionPolicy(row: row, context: context)
            let isReacting = actions.isReacting(to: row.entry)
            let eligibility = MessageReactionEligibility(
                canReact: policy.canReact && actions.toggleReaction != nil,
                isReacting: isReacting, reactions: row.entry.remoteMessage?.reactions ?? [])
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
                    button.alphaValue = button.isEnabled ? 1 : 0.4
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
                    button.configureSymbol("plus", pointSize: 21)
                    // Limits apply to individual emoji, not opening the keyboard:
                    // selected reactions must remain removable at either limit.
                    button.isEnabled = eligibility.canReact && !eligibility.isReacting
                    button.alphaValue = button.isEnabled ? 1 : 0.4
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
                case .delete: available = actions.deleteMessage != nil
                case .thread: available = actions.openThread != nil
                case .reactionDetails: available = actions.openReactionDetails != nil
                case .select: available = actions.toggleMessageSelection != nil
                case .forward: available = actions.forwardMessage != nil
                case .save: available = actions.toggleSavedMessage != nil
                default: available = true
                }
                let label =
                    action == .save && context.isSaved
                    ? AppLanguage.localized("Remove Saved Message")
                    : action.label(hasAttachments: row.entry.remoteMessage?.hasAttachments == true)
                button.configureAction(
                    symbol: action.symbol, label: label, destructive: action == .delete)
                button.isEnabled = implemented && available
                button.alphaValue = button.isEnabled ? 1 : 0.4
                let hint =
                    implemented
                    ? AppLanguage.localized("Unavailable")
                    : AppLanguage.localized("Not implemented yet")
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
                actions.modifiablePendingMessageIDs.contains(pending.clientGeneratedID)
            {
                showsPending = true
            }
            pendingSurface.isHidden = !showsPending
            blockButton.isEnabled =
                actions.blockPendingMessage != nil
                && [.text, .file].contains(row.entry.messageType)
                && row.entry.presentationMessage?.forwardedFrom == nil
            revokeButton.isEnabled = actions.revokePendingMessage != nil
            blockButton.alphaValue = blockButton.isEnabled ? 1 : 0.4
            revokeButton.alphaValue = revokeButton.isEnabled ? 1 : 0.4
            blockButton.setAccessibilityHelp(
                blockButton.isEnabled ? nil : AppLanguage.localized("Unavailable"))
            revokeButton.setAccessibilityHelp(
                revokeButton.isEnabled ? nil : AppLanguage.localized("Unavailable"))
            if let pickerHost {
                reactionSurface.isHidden = true
                scrollView.isHidden = true
                progress.stopAnimation(nil)
                pickerHost.rootView = pickerContent(eligibility: eligibility)
            }
            needsLayout = true
            layoutSubtreeIfNeeded()
        }

        func present() {
            layoutSubtreeIfNeeded()
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            for view in [reactionSurface, scrollView] {
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = 0.94
                scale.toValue = 1
                scale.duration = 0.16
                scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.layer?.add(scale, forKey: "menuScale")
            }
        }

        func dismiss(completion: @escaping @MainActor () -> Void) {
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if !reduceMotion {
                for view in [reactionSurface, scrollView] {
                    let scale = CABasicAnimation(keyPath: "transform.scale")
                    scale.fromValue =
                        view.layer?.presentation()?.value(forKeyPath: "transform.scale") ?? 1
                    scale.toValue = 0.96
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
            sourceHighlight.path = CGPath(
                roundedRect: source.insetBy(dx: -3, dy: -3),
                cornerWidth: 14, cornerHeight: 14, transform: nil)
            if let placeholder = pickerPlaceholderHost {
                layoutReactionPlaceholder(placeholder)
                return
            }
            let rowCount = (activeActionCount + 4) / 5
            let gridHeight = CGFloat(rowCount) * actionRowHeight + CGFloat(max(0, rowCount - 1))
            contentHeight = gridHeight + (showsPending ? (gridHeight > 0 ? 8 : 0) + 88 : 0)
            let inset = min(16, max(0, min(bounds.width, bounds.height) / 2 - 1))
            let usable = bounds.insetBy(dx: inset, dy: inset)
            let reactionHeight: CGFloat = reactionSurface.isHidden ? 0 : min(52, usable.height)
            let spacing: CGFloat = reactionHeight > 0 && contentHeight > 0 ? 8 : 0
            let actionsHeight = min(contentHeight, max(0, usable.height - reactionHeight - spacing))
            let height = reactionHeight + spacing + actionsHeight
            let x = min(
                max(usable.minX, outgoing ? source.maxX - controlsWidth : source.minX),
                usable.maxX - controlsWidth)
            // Prefer below the message, then above it. In a short window the menu
            // may overlap history, but must never move or clone the source bubble.
            let proposedY =
                source.maxY + 8 + height <= usable.maxY
                ? source.maxY + 8 : source.minY - 8 - height
            let y = min(max(usable.minY, proposedY), usable.maxY - height)
            reactionSurface.frame = CGRect(x: x, y: y, width: controlsWidth, height: reactionHeight)
            if !reactionSurface.isHidden {
                let gaps = CGFloat(max(0, activeReactionCount - 1)) * 2
                let buttonWidth = max(
                    0, (controlsWidth - 12 - gaps) / CGFloat(max(1, activeReactionCount)))
                for index in 0..<activeReactionCount {
                    reactionButtons[index].frame = CGRect(
                        x: 6 + CGFloat(index) * (buttonWidth + 2), y: 4, width: buttonWidth,
                        height: 44)
                }
                progress.frame = CGRect(x: (controlsWidth - 16) / 2, y: 18, width: 16, height: 16)
            }
            scrollView.frame = CGRect(
                x: x, y: y + reactionHeight + spacing,
                width: controlsWidth, height: actionsHeight)
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
                dividers[index].frame = CGRect(
                    x: 0, y: CGFloat(index + 1) * actionRowHeight + CGFloat(index),
                    width: controlsWidth, height: 1)
            }
            if showsPending {
                pendingSurface.frame = CGRect(
                    x: 0, y: gridHeight + (gridHeight > 0 ? 8 : 0), width: controlsWidth, height: 88
                )
                blockButton.frame = CGRect(x: 0, y: 0, width: controlsWidth, height: 44)
                revokeButton.frame = CGRect(x: 0, y: 44, width: controlsWidth, height: 44)
            }
            let clip = scrollView.contentView
            let boundedY = min(max(0, clip.bounds.minY), max(0, contentHeight - clip.bounds.height))
            if boundedY != clip.bounds.minY { clip.scroll(to: NSPoint(x: 0, y: boundedY)) }
            scrollView.reflectScrolledClipView(clip)
        }

        /// Keeps keyboard traversal inside the native modal panel without installing
        /// an application-wide key equivalent handler or consuming Command shortcuts.
        @discardableResult
        func focusNext(backward: Bool) -> Bool {
            // Let AppKit/SwiftUI traverse the hosted category and emoji controls.
            // The native menu's flat button list must not consume their Tab events.
            guard !isShowingReactionPicker else { return false }
            var controls = reactionButtons.prefix(activeReactionCount).filter {
                $0.isEnabled && !$0.isHidden
            }
            controls += actionButtons.prefix(activeActionCount).filter {
                $0.isEnabled && !$0.isHidden
            }
            if showsPending {
                if blockButton.isEnabled { controls.append(blockButton) }
                if revokeButton.isEnabled { controls.append(revokeButton) }
            }
            controls.append(dismissButton)
            guard let window else { return false }
            let current = controls.firstIndex { $0 === window.firstResponder }
            let index =
                current.map { ($0 + (backward ? controls.count - 1 : 1)) % controls.count }
                ?? (backward ? controls.count - 1 : 0)
            let control = controls[index]
            if control.isDescendant(of: documentView) {
                documentView.scrollToVisible(control.convert(control.bounds, to: documentView))
            }
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
            updateSourceHighlight()
            for divider in dividers {
                divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
            }
        }

        func clear() {
            deactivate()
            layer?.removeAllAnimations()
            for view in [reactionSurface, scrollView] {
                view.layer?.removeAllAnimations()
            }
            messageIdentity = nil
        }

        /// Disable callbacks during the short menu dismissal transition.
        func deactivate() {
            isCleared = true
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
            // Programmatic dismissal must not enter the delegate's user-cancel
            // path, which would otherwise re-enter the controller while closing.
            pickerPopover?.delegate = nil
            pickerPopover?.close()
            pickerPopover?.contentViewController = nil
            pickerPopover = nil
            pickerHost = nil
            pickerPlaceholderHost?.removeFromSuperview()
            pickerPlaceholderHost = nil
            reactionEligibility = nil
            nextKeyView = nil
            sourceHighlight.path = nil
        }

        private func updateSourceHighlight() {
            sourceHighlight.fillColor =
                NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            sourceHighlight.strokeColor =
                NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
        }

        /// The popover's auxiliary window is part of this interaction, not a
        /// switch to an unrelated chat window.
        func ownsInteractionWindow(_ candidate: NSWindow?) -> Bool {
            guard let candidate else { return false }
            return candidate === window || candidate === pickerHost?.window
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
                window != nil
            else { return }
            // This frame-view overlay sits above SwiftUI and the native title bar.
            // SwiftUI's popover presenter cannot attach to that native anchor.
            // NSPopover supplies a real pointer, window chrome and transient focus
            // while leaving the original timeline message readable and unmoved.
            let placeholder = NSHostingView(
                rootView: ReactionPickerPlaceholder(
                    onClose: { [weak self] in self?.onDismiss?() }))
            placeholder.sizingOptions = []
            placeholder.setAccessibilityIdentifier("reaction-picker-anchor")
            pickerPlaceholderHost = placeholder
            addSubview(placeholder)

            let host = NSHostingView(rootView: pickerContent(eligibility: reactionEligibility))
            host.sizingOptions = []
            host.autoresizingMask = [.width, .height]
            let controller = NSViewController()
            controller.view = host
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.contentViewController = controller
            popover.delegate = self
            pickerHost = host
            pickerPopover = popover
            reactionSurface.isHidden = true
            scrollView.isHidden = true
            progress.stopAnimation(nil)
            needsLayout = true
            layoutSubtreeIfNeeded()
            let above = placeholder.frame.midY < source.midY
            popover.show(
                relativeTo: placeholder.bounds, of: placeholder,
                preferredEdge: above ? .minY : .maxY)
            host.window?.recalculateKeyViewLoop()
        }

        private func layoutReactionPlaceholder(
            _ placeholder: NSHostingView<ReactionPickerPlaceholder>
        ) {
            let usable = bounds.insetBy(dx: 16, dy: 16)
            let size = min(76, max(1, min(usable.width, usable.height)))
            let below = max(0, usable.maxY - source.maxY - 8)
            let above = max(0, source.minY - usable.minY - 8)
            guard let window, let screen = window.screen, let popover = pickerPopover else {
                return
            }
            let visible = screen.visibleFrame.insetBy(dx: 16, dy: 16)
            let message = window.convertToScreen(convert(source, to: nil))
            let screenBelow = max(0, message.minY - visible.minY)
            let screenAbove = max(0, visible.maxY - message.maxY)
            let opensAbove =
                above >= size
                && (below < size || (screenBelow < size + 388 && screenAbove > screenBelow))
            let proposedY = opensAbove ? source.minY - 8 - size : source.maxY + 8
            placeholder.frame = CGRect(
                x: min(
                    max(usable.minX, outgoing ? source.maxX - size : source.minX),
                    usable.maxX - size),
                y: min(max(usable.minY, proposedY), usable.maxY - size),
                width: size, height: size)
            let anchor = window.convertToScreen(placeholder.convert(placeholder.bounds, to: nil))
            let verticalSpace =
                opensAbove ? visible.maxY - anchor.maxY : anchor.minY - visible.minY
            // Native chrome/pointer lies outside contentSize. Constrain content to
            // the space away from the message rather than covering its source.
            popover.contentSize = NSSize(
                width: min(360, max(1, visible.width)),
                height: min(360, max(1, verticalSpace - 20)))
            if popover.isShown {
                popover.show(
                    relativeTo: placeholder.bounds, of: placeholder,
                    preferredEdge: opensAbove ? .minY : .maxY)
            }
        }

        private func pickerContent(eligibility: MessageReactionEligibility)
            -> ReactionEmojiKeyboard
        {
            ReactionEmojiKeyboard(
                eligibility: eligibility,
                onSelect: { [weak self] emoji in
                    guard let self, !self.isCleared else { return }
                    self.onReaction?(emoji)
                })
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

    private final class TimelineMenuSurface: NSView {
        private let cover = NSView()
        private let usesOpaqueBackground: Bool
        override var isFlipped: Bool { true }

        init(cornerRadius: CGFloat, opaque: Bool = false) {
            usesOpaqueBackground = opaque
            super.init(frame: .zero)
            if !opaque {
                let effect = NSVisualEffectView()
                effect.material = .menu
                effect.blendingMode = .withinWindow
                effect.state = .active
                effect.autoresizingMask = [.width, .height]
                addSubview(effect)
            }
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
            cover.layer?.backgroundColor =
                NSColor(white: dark ? 0.12 : 1, alpha: usesOpaqueBackground ? 1 : 0.65).cgColor
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
            symbol = nil
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

        private func configureLabel(
            symbol name: String, label: String, destructive: Bool, horizontal: Bool
        ) {
            content = .action(label, horizontal: horizontal)
            symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: horizontal ? 17 : 22, weight: .regular))
            self.destructive = destructive
            setAccessibilityLabel(label)
            updateSymbolColor()
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            if case .empty = content { return }
            let color = destructive ? NSColor.systemRed : NSColor.labelColor
            if isHighlighted {
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                if case .reaction = content {
                    let diameter = min(bounds.width, bounds.height)
                    NSBezierPath(
                        ovalIn: CGRect(
                            x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2,
                            width: diameter, height: diameter)
                    ).fill()
                } else {
                    NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
                        .fill()
                }
            }
            switch content {
            case .empty:
                break
            case .symbol:
                drawSymbol(
                    in: CGRect(
                        x: (bounds.width - 21) / 2, y: (bounds.height - 21) / 2, width: 21,
                        height: 21))
            case .reaction(let emoji, let selected):
                let diameter = min(bounds.width, bounds.height)
                let circle = CGRect(
                    x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2,
                    width: diameter, height: diameter)
                if selected {
                    NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                    NSBezierPath(ovalIn: circle).fill()
                }
                drawLabel(
                    emoji,
                    in: CGRect(x: 0, y: (bounds.height - 31) / 2, width: bounds.width, height: 31),
                    font: .systemFont(ofSize: 24), color: color)
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
                    let labelWidth = max(0, bounds.width - 6)
                    if actionLabelWidth != labelWidth {
                        actionLabelWidth = labelWidth
                        let maximumHeight =
                            ceil(captionFont.ascender - captionFont.descender + captionFont.leading)
                            * 2
                        actionLabelHeight = min(
                            maximumHeight,
                            ceil(
                                actionLabel?.boundingRect(
                                    with: CGSize(
                                        width: labelWidth, height: .greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                                ).height ?? 0))
                    }
                    // Center the visible icon/label stack, not an always-two-line label box.
                    let top = max(2, (bounds.height - 22 - 4 - actionLabelHeight) / 2)
                    drawSymbol(
                        in: CGRect(x: (bounds.width - 22) / 2, y: top, width: 22, height: 22))
                    actionLabel?.draw(
                        with: CGRect(
                            x: 3, y: top + 26, width: labelWidth, height: actionLabelHeight),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                    )
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
            coloredSymbol?.draw(
                in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                hints: nil)
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
                    attributes: [
                        .font: captionFont, .foregroundColor: color, .paragraphStyle: paragraph,
                    ]
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
