#if os(macOS)
    import AppKit
    import ChahuaAPI

    /// Owns the popup independently of reused cells. Menu rendering remains native;
    /// the shared emoji keyboard is hosted only while this single overlay needs it.
    @MainActor
    final class TimelineInteractionController: NSObject {
        weak var timelineView: NSView?
        var onRoutedActionsChanged: (() -> Void)?

        private struct Target {
            let key: ConversationMessageStableKey
            let sourceRect: CGRect
        }

        private let model: ConversationTimelineModel
        private var actions = TimelineBubbleActions()
        private var context = MessageInteractionContext()
        private var target: Target?
        private var overlay: TimelineActionOverlayView?
        private var dismissingOverlay: TimelineActionOverlayView?
        private weak var overlayWindow: NSWindow?
        private weak var previousFirstResponder: NSResponder?
        private var keyMonitor: Any?

        init(model: ConversationTimelineModel) {
            self.model = model
            super.init()
            let notifications = NotificationCenter.default
            for name in [
                NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                NSWindow.didChangeBackingPropertiesNotification,
            ] {
                notifications.addObserver(
                    self, selector: #selector(windowGeometryChanged(_:)), name: name, object: nil)
            }
            for name in [
                NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                NSWindow.didResignKeyNotification, NSWindow.willEnterFullScreenNotification,
                NSWindow.willExitFullScreenNotification,
            ] {
                notifications.addObserver(
                    self, selector: #selector(windowBecameUnavailable(_:)), name: name, object: nil)
            }
            notifications.addObserver(
                self, selector: #selector(windowBecameKey(_:)),
                name: NSWindow.didBecomeKeyNotification, object: nil)
            notifications.addObserver(
                self, selector: #selector(preferencesChanged),
                name: UserDefaults.didChangeNotification, object: nil)
            notifications.addObserver(
                self, selector: #selector(applicationBecameInactive),
                name: NSApplication.didResignActiveNotification, object: nil)
        }

        func configure(actions: TimelineBubbleActions, context: MessageInteractionContext) {
            self.actions = actions
            self.context = context
            refresh()
            onRoutedActionsChanged?()
        }

        var routedActions: TimelineBubbleActions {
            var result = actions
            result.interactionContext = context
            result.openContextMenu =
                target == nil
                ? { [weak self] row, source in
                    guard let self, let timelineView = self.timelineView else { return }
                    self.open(row: row, source: source, in: timelineView)
                } : nil
            if !context.canWrite { result.toggleReaction = nil }
            if target != nil || !context.canWrite { result.replyToMessage = nil }
            return result
        }

        func open(
            row: TimelineMessageRow, source: MessageInteractionSource, in timelineView: NSView
        ) {
            guard target == nil, row.entry.messageType != .system,
                let window = timelineView.window, let content = window.contentView,
                let overlayHost = content.superview,
                !timelineView.isHiddenOrHasHiddenAncestor,
                let live = liveRow(for: row.entry.stableKey), live.entry.messageType != .system
            else { return }
            finishDismissal()
            self.timelineView = timelineView
            target = Target(key: live.entry.stableKey, sourceRect: source.rect)
            previousFirstResponder = window.firstResponder
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                let owner = editor.delegate as? NSResponder
            {
                // AppKit detaches its shared field editor when focus leaves a field.
                // Restore the owning control rather than the detached text view.
                previousFirstResponder = owner
            }
            overlayWindow = window
            let overlay = TimelineActionOverlayView()
            overlay.onDismiss = { [weak self] in self?.dismiss() }
            overlay.onReaction = { [weak self] emoji in self?.react(emoji) }
            overlay.onAction = { [weak self] action in self?.perform(action) }
            overlay.onBlock = { [weak self] in self?.modifyPending(revoke: false) }
            overlay.onRevoke = { [weak self] in self?.modifyPending(revoke: true) }
            self.overlay = overlay
            overlay.frame = overlayHost.bounds
            overlay.autoresizingMask = [.width, .height]
            // SwiftUI's content host cannot accept native children, and its bounds
            // exclude native title-bar controls. The window's common frame view is
            // the only same-window host above both SwiftUI chrome and the title bar;
            // no auxiliary key window is created or kept alive after the chat closes.
            overlayHost.addSubview(overlay, positioned: .above, relativeTo: nil)
            refresh()
            guard self.overlay === overlay else { return }
            window.makeFirstResponder(overlay)
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [
                .keyDown, .leftMouseDown, .rightMouseDown,
            ]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, self.target != nil, let window = self.overlayWindow,
                        self.overlay?.ownsInteractionWindow(event.window) == true
                    else { return false }
                    // AppKit routes native title-bar mouse events separately from
                    // frame-view children. Covered window controls must not receive
                    // the click, even when the menu opened in an inactive window.
                    if event.type != .keyDown, event.window === window,
                        !window.contentLayoutRect.contains(event.locationInWindow)
                    {
                        self.dismiss()
                        return true
                    }
                    guard event.type == .keyDown,
                        event.modifierFlags.intersection([.command, .control, .option]).isEmpty
                    else { return false }
                    if event.keyCode == 53 {
                        self.dismiss()
                        return true
                    }
                    if event.keyCode == 48 {
                        return self.overlay?.focusNext(
                            backward: event.modifierFlags.contains(.shift)) ?? false
                    }
                    return false
                }
                return consumed ? nil : event
            }
            overlay.present()
            onRoutedActionsChanged?()
        }

        /// Called by the surface's independently scheduled model/geometry refresh.
        func refresh() {
            guard let target else { return }
            guard let row = liveRow(for: target.key), row.entry.messageType != .system,
                let timelineView, !timelineView.isHiddenOrHasHiddenAncestor,
                let window = timelineView.window, window === overlayWindow,
                let content = window.contentView, let overlayHost = content.superview, let overlay,
                overlay.superview === overlayHost
            else {
                dismiss(animated: false)
                return
            }
            overlay.frame = overlayHost.bounds
            if overlayHost.subviews.last !== overlay {
                overlayHost.addSubview(overlay, positioned: .above, relativeTo: nil)
            }
            let rect = target.sourceRect
            let sourceInContent =
                content.isFlipped
                ? rect
                : CGRect(
                    x: rect.minX, y: content.bounds.maxY - rect.maxY,
                    width: rect.width, height: rect.height)
            let localSource = overlay.convert(sourceInContent, from: content)
            overlay.configure(
                row: row, context: context, actions: actions, sourceRect: localSource)
        }

        func dismiss(animated: Bool = true) {
            guard target != nil || overlay != nil else {
                if !animated { finishDismissal() }
                return
            }
            target = nil
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            finishDismissal()
            let dismissedOverlay = overlay
            let restoresPickerFocus = dismissedOverlay?.isShowingReactionPicker == true
            dismissedOverlay?.deactivate()
            restoreFirstResponder(includingReactionPicker: restoresPickerFocus)
            overlay = nil
            previousFirstResponder = nil
            overlayWindow = nil
            dismissingOverlay = dismissedOverlay
            if let dismissedOverlay, animated {
                dismissedOverlay.dismiss { [weak self, weak dismissedOverlay] in
                    guard let self, self.dismissingOverlay === dismissedOverlay else { return }
                    self.finishDismissal()
                }
            } else {
                finishDismissal()
            }
            onRoutedActionsChanged?()
        }

        private func finishDismissal() {
            dismissingOverlay?.clear()
            dismissingOverlay?.removeFromSuperview()
            dismissingOverlay = nil
        }

        private func restoreFirstResponder(includingReactionPicker: Bool = false) {
            guard let window = overlayWindow, let overlay,
                includingReactionPicker || window.firstResponder === overlay
                    || (window.firstResponder as? NSView)?.isDescendant(of: overlay) == true
            else { return }
            var restored = false
            if let view = previousFirstResponder as? NSView, view.window === window {
                restored = window.makeFirstResponder(view)
            } else if let controller = previousFirstResponder as? NSViewController,
                controller.isViewLoaded, controller.view.window === window
            {
                restored = window.makeFirstResponder(controller)
            } else if previousFirstResponder === window {
                restored = window.makeFirstResponder(window)
            }
            if !restored {
                window.makeFirstResponder(timelineView?.window === window ? timelineView : nil)
            }
        }

        private func liveRow(for key: ConversationMessageStableKey) -> TimelineMessageRow? {
            for row in model.rows {
                if case .message(let message) = row, message.entry.stableKey == key {
                    return message
                }
            }
            return nil
        }

        private var selectedRow: TimelineMessageRow? {
            target.flatMap { liveRow(for: $0.key) }
        }

        private func react(_ emoji: String) {
            guard let row = selectedRow else {
                dismiss()
                return
            }
            let eligibility = MessageReactionEligibility(
                canReact: MessageActionPolicy(row: row, context: context).canReact,
                isReacting: actions.isReacting(to: row.entry),
                reactions: row.entry.remoteMessage?.reactions ?? [])
            guard eligibility.canToggle(emoji), let toggle = actions.toggleReaction else {
                refresh()
                return
            }
            // The shared keyboard owns recents for its selections; quick native
            // reactions still record here. Neither path records selected removals.
            if overlay?.isShowingReactionPicker != true && !eligibility.isSelected(emoji) {
                let defaults = UserDefaults.standard
                let recent =
                    defaults.string(forKey: MessageReactionPreferences.recentStorageKey)
                    ?? MessageReactionPreferences.defaultRecentStorage
                defaults.set(
                    MessageReactionPreferences.recording(emoji, in: recent),
                    forKey: MessageReactionPreferences.recentStorageKey)
            }
            // Capture only the just-resolved live payload and callback before dismissal
            // refreshes routed actions. Feature controllers retain mutation ownership.
            dismiss()
            toggle(row, emoji)
        }

        private func perform(_ action: MessageMenuAction) {
            guard let row = selectedRow else {
                dismiss()
                return
            }
            guard
                MessageActionPolicy(row: row, context: actions.pinContext(for: row, base: context))
                    .availability(of: action) == .enabled
            else {
                refresh()
                return
            }
            switch action {
            case .copy:
                guard let text = row.entry.text else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                dismiss()
            case .select, .forward:
                guard let message = row.entry.remoteMessage else { return }
                let callback =
                    action == .select
                    ? actions.toggleMessageSelection : actions.forwardMessage
                guard let callback else { return }
                dismiss()
                callback(message)
            case .reply:
                guard let message = row.entry.remoteMessage, let reply = actions.replyToMessage
                else { return }
                dismiss()
                reply(message)
            case .edit:
                guard let message = row.entry.remoteMessage, let edit = actions.editMessage else {
                    return
                }
                dismiss()
                edit(message)
            case .pin, .unpin:
                guard let message = row.entry.remoteMessage, let togglePin = actions.togglePin
                else { return }
                dismiss()
                togglePin(message)
            case .delete:
                guard let message = row.entry.remoteMessage, let delete = actions.deleteMessage
                else { return }
                dismiss()
                delete(message)
            case .thread:
                guard let message = row.entry.remoteMessage, let openThread = actions.openThread
                else { return }
                dismiss()
                openThread(message.id)
            case .reactionDetails:
                guard let message = row.entry.remoteMessage,
                    let openDetails = actions.openReactionDetails
                else { return }
                // Remove the overlay before SwiftUI starts the modal sheet's run loop.
                dismiss(animated: false)
                openDetails(message)
            default:
                break  // Policy keeps unsupported actions visible but disabled.
            }
        }

        private func modifyPending(revoke: Bool) {
            guard let row = selectedRow else {
                dismiss()
                return
            }
            guard case .pending(let pending) = row.entry, !pending.dispatchClaimed,
                actions.modifiablePendingMessageIDs.contains(pending.clientGeneratedID),
                revoke || (pending.body.messageType == .text && pending.forwardRequest == nil),
                let operation = revoke ? actions.revokePendingMessage : actions.blockPendingMessage
            else {
                refresh()
                return
            }
            dismiss()
            operation(pending)
        }

        @objc private func windowGeometryChanged(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            if dismissingOverlay?.window === window { finishDismissal() }
            guard window === overlayWindow else { return }
            refresh()
        }

        @objc private func windowBecameUnavailable(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            if dismissingOverlay?.window === window { finishDismissal() }
            guard window === overlayWindow else { return }
            if notification.name == NSWindow.didResignKeyNotification,
                overlay?.isShowingReactionPicker == true
            {
                // NSPopover may become key during show(). AppKit sends the
                // parent's resignation before publishing the new key window.
                // Resolve that transition on the next turn, and also observe
                // didBecomeKey so a later unrelated window still cancels.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.target != nil else { return }
                    if !NSApp.isActive
                        || (NSApp.keyWindow != nil
                            && self.overlay?.ownsInteractionWindow(NSApp.keyWindow) != true)
                    {
                        self.dismiss(animated: false)
                    }
                }
                return
            }
            dismiss(animated: false)
        }

        @objc private func windowBecameKey(_ notification: Notification) {
            guard target != nil, let window = notification.object as? NSWindow,
                overlay?.ownsInteractionWindow(window) != true
            else { return }
            dismiss(animated: false)
        }

        @objc private func applicationBecameInactive() {
            dismiss(animated: false)
        }

        @objc private func preferencesChanged() {
            refresh()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            MainActor.assumeIsolated {
                if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
                restoreFirstResponder()
                overlay?.clear()
                overlay?.removeFromSuperview()
                dismissingOverlay?.clear()
                dismissingOverlay?.removeFromSuperview()
            }
        }
    }
#endif
