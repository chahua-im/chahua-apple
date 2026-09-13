#if os(macOS)
import AppKit
import ChahuaAPI

/// Owns the popup independently of reused cells. Native rendering avoids the
/// measured per-row NSHostingView layout and AttributeGraph work in this timeline.
@MainActor
final class TimelineInteractionController: NSObject {
    weak var timelineView: NSView?
    var onRoutedActionsChanged: (() -> Void)?

    private struct Target {
        let key: ConversationMessageStableKey
        let source: CGRect
    }

    private let model: ConversationTimelineModel
    private var actions = TimelineBubbleActions()
    private var context = MessageInteractionContext()
    private var mediaContext: AppMediaContext?
    private var target: Target?
    private var overlay: TimelineActionOverlayView?
    private weak var overlayWindow: NSWindow?
    private weak var previousFirstResponder: NSResponder?
    private var keyMonitor: Any?

    init(model: ConversationTimelineModel) {
        self.model = model
        super.init()
        let notifications = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                     NSWindow.didChangeBackingPropertiesNotification] {
            notifications.addObserver(self, selector: #selector(windowGeometryChanged(_:)), name: name, object: nil)
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            notifications.addObserver(self, selector: #selector(windowBecameUnavailable(_:)), name: name, object: nil)
        }
        notifications.addObserver(self, selector: #selector(preferencesChanged), name: UserDefaults.didChangeNotification, object: nil)
    }

    func configure(actions: TimelineBubbleActions, context: MessageInteractionContext, mediaContext: AppMediaContext?) {
        self.actions = actions
        self.context = context
        self.mediaContext = mediaContext
        refresh()
        onRoutedActionsChanged?()
    }

    var routedActions: TimelineBubbleActions {
        var result = actions
        result.interactionContext = context
        result.openContextMenu = target == nil ? { [weak self] row, source in
            guard let self, let timelineView = self.timelineView else { return }
            self.open(row: row, source: source, in: timelineView)
        } : nil
        if !context.canWrite { result.toggleReaction = nil }
        if target != nil || !context.canWrite { result.replyToMessage = nil }
        return result
    }

    func open(row: TimelineMessageRow, source: CGRect, in timelineView: NSView) {
        guard target == nil, row.entry.messageType != .system,
              let window = timelineView.window, let content = window.contentView, let overlayHost = content.superview,
              !timelineView.isHiddenOrHasHiddenAncestor,
              let live = liveRow(for: row.entry.stableKey), live.entry.messageType != .system
        else { return }
        self.timelineView = timelineView
        target = Target(key: live.entry.stableKey, source: source)
        previousFirstResponder = window.firstResponder
        overlayWindow = window
        let overlay = TimelineActionOverlayView()
        overlay.onDismiss = { [weak self] in self?.dismiss() }
        overlay.onReaction = { [weak self] emoji in self?.react(emoji) }
        overlay.onAction = { [weak self] action in self?.perform(action) }
        overlay.onBlock = { [weak self] in self?.modifyPending(revoke: false) }
        overlay.onRevoke = { [weak self] in self?.modifyPending(revoke: true) }
        self.overlay = overlay
        overlay.frame = timelineView.convert(timelineView.bounds, to: overlayHost)
        overlay.alphaValue = 0
        // SwiftUI owns window.contentView in the app. AppKit forbids adding
        // children directly to that hosting view; use its native common parent
        // and constrain the overlay to the converted timeline bounds instead.
        overlayHost.addSubview(overlay, positioned: .above, relativeTo: content)
        refresh()
        guard self.overlay === overlay else { return }
        window.makeFirstResponder(overlay)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.target != nil, event.window === self.overlayWindow,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty
                else { return false }
                if event.keyCode == 53 {
                    self.dismiss()
                    return true
                }
                if event.keyCode == 48 {
                    self.overlay?.focusNext(backward: event.modifierFlags.contains(.shift))
                    return true
                }
                return false
            }
            return consumed ? nil : event
        }
        NSAnimationContext.runAnimationGroup { animation in
            animation.duration = 0.15
            overlay.animator().alphaValue = 1
        }
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
            dismiss()
            return
        }
        overlay.frame = timelineView.convert(timelineView.bounds, to: overlayHost)
        let sourceInContent = content.isFlipped ? target.source : CGRect(
            x: target.source.minX, y: content.bounds.maxY - target.source.maxY,
            width: target.source.width, height: target.source.height)
        let localSource = overlay.convert(sourceInContent, from: content)
        overlay.configure(
            row: row, currentUserID: model.currentUserID, context: context,
            actions: actions, mediaContext: mediaContext,
            source: localSource, hasSource: target.source != .zero)
    }

    func dismiss() {
        guard target != nil || overlay != nil else { return }
        target = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        let dismissedOverlay = overlay
        overlay = nil
        dismissedOverlay?.deactivate()
        restoreFirstResponder()
        previousFirstResponder = nil
        overlayWindow = nil
        if let dismissedOverlay {
            NSAnimationContext.runAnimationGroup({ animation in
                animation.duration = 0.15
                dismissedOverlay.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    dismissedOverlay.clear()
                    dismissedOverlay.removeFromSuperview()
                }
            })
        }
        onRoutedActionsChanged?()
    }

    private func restoreFirstResponder() {
        guard let window = overlayWindow else { return }
        var restored = false
        if let view = previousFirstResponder as? NSView, view.window === window {
            restored = window.makeFirstResponder(view)
        } else if let controller = previousFirstResponder as? NSViewController,
                  controller.isViewLoaded, controller.view.window === window {
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
            if case .message(let message) = row, message.entry.stableKey == key { return message }
        }
        return nil
    }

    private var selectedRow: TimelineMessageRow? {
        target.flatMap { liveRow(for: $0.key) }
    }

    private func react(_ emoji: String) {
        guard let row = selectedRow else { dismiss(); return }
        let eligibility = MessageReactionEligibility(
            canReact: MessageActionPolicy(row: row, context: context).canReact,
            isReacting: actions.pendingReactionMessageIDs.contains(row.entry.serverID ?? ""),
            reactions: row.entry.remoteMessage?.reactions ?? [])
        guard eligibility.canToggle(emoji), let toggle = actions.toggleReaction else { refresh(); return }
        if !eligibility.isSelected(emoji) {
            let defaults = UserDefaults.standard
            let recent = defaults.string(forKey: MessageReactionPreferences.recentStorageKey)
                ?? MessageReactionPreferences.defaultRecentStorage
            defaults.set(MessageReactionPreferences.recording(emoji, in: recent), forKey: MessageReactionPreferences.recentStorageKey)
        }
        // Capture only the just-resolved live payload and callback before dismissal
        // refreshes routed actions. Feature controllers retain mutation ownership.
        dismiss()
        toggle(row, emoji)
    }

    private func perform(_ action: MessageMenuAction) {
        guard let row = selectedRow else { dismiss(); return }
        guard MessageActionPolicy(row: row, context: context).availability(of: action) == .enabled else {
            refresh()
            return
        }
        switch action {
        case .copy:
            guard let text = row.entry.text else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            dismiss()
        case .reply:
            guard let message = row.entry.remoteMessage, let reply = actions.replyToMessage else { return }
            dismiss()
            reply(message)
        case .edit:
            guard let message = row.entry.remoteMessage, let edit = actions.editMessage else { return }
            dismiss()
            edit(message)
        default:
            break // Policy keeps unsupported actions visible but disabled.
        }
    }

    private func modifyPending(revoke: Bool) {
        guard let row = selectedRow else { dismiss(); return }
        guard case .pending(let pending) = row.entry, !pending.dispatchClaimed,
              actions.modifiablePendingMessageIDs.contains(pending.clientGeneratedID),
              let operation = revoke ? actions.revokePendingMessage : actions.blockPendingMessage
        else { refresh(); return }
        dismiss()
        operation(pending)
    }

    @objc private func windowGeometryChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === overlayWindow else { return }
        refresh()
    }

    @objc private func windowBecameUnavailable(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === overlayWindow else { return }
        dismiss()
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
        }
    }
}
#endif
