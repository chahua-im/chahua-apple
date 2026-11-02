#if os(macOS)
    import AppKit
    import QuartzCore
    import SwiftUI

    /// SwiftUI owns row content, sizing and accessibility. AppKit only draws the
    /// exposed circular controls and arbitrates phased wheel events, which SwiftUI
    /// gestures cannot distinguish from momentum or forward to native scrolling.
    struct SwipeRowAppKit<Content: View>: View {
        let id: AnyHashable
        let isRevealed: Bool
        let leadingAction: SwipeRowAction?
        let trailingActions: [SwipeRowAction]
        let isBusy: Bool
        let onRevealChanged: (Bool) -> Void
        let onAction: (String) -> Void
        @ViewBuilder let content: () -> Content
        @State private var contentOffset: CGFloat = 0

        var body: some View {
            content()
                .offset(x: contentOffset)
                .overlay {
                    SwipeRowAppKitBridge(
                        id: id, isRevealed: isRevealed,
                        leadingAction: leadingAction, trailingActions: trailingActions,
                        isBusy: isBusy, onRevealChanged: onRevealChanged, onAction: onAction,
                        onOffsetChanged: { offset, animated in
                            guard contentOffset != offset else { return }
                            var transaction = Transaction(
                                animation: animated
                                    ? .easeOut(duration: SwipeRowMetrics.animationDuration) : nil)
                            transaction.disablesAnimations = !animated
                            withTransaction(transaction) { contentOffset = offset }
                        })
                }
                .clipped()
        }
    }

    private struct SwipeRowAppKitBridge: NSViewRepresentable {
        let id: AnyHashable
        let isRevealed: Bool
        let leadingAction: SwipeRowAction?
        let trailingActions: [SwipeRowAction]
        let isBusy: Bool
        let onRevealChanged: (Bool) -> Void
        let onAction: (String) -> Void
        let onOffsetChanged: (CGFloat, Bool) -> Void

        func makeNSView(context: Context) -> SwipeRowAppKitContainer {
            SwipeRowAppKitContainer()
        }

        func updateNSView(_ view: SwipeRowAppKitContainer, context: Context) {
            view.configure(
                id: id, leading: leadingAction, trailing: trailingActions,
                isBusy: isBusy, isRevealed: isRevealed,
                reduceMotion: context.environment.accessibilityReduceMotion,
                isRightToLeft: context.environment.layoutDirection == .rightToLeft,
                onRevealChanged: onRevealChanged, onAction: onAction,
                onOffsetChanged: onOffsetChanged)
        }

        static func dismantleNSView(_ view: SwipeRowAppKitContainer, coordinator: ()) {
            view.detach()
        }
    }

    @MainActor
    final class SwipeRowAppKitContainer: NSView, NSGestureRecognizerDelegate {
        private enum WheelAxis { case idle, pending, horizontal, vertical, cancelled }

        private var leadingClip: NSView?
        private var trailingClip: NSView?
        private var leadingButton: SwipeRowAppKitButton?
        private var trailingButtons: [SwipeRowAppKitButton] = []
        private var leadingNeedsConfiguration = true
        private var trailingNeedsConfiguration = true
        private weak var observedScrollView: NSScrollView?
        private weak var gestureHost: NSView?
        private var identity: AnyHashable?
        private var leadingAction: SwipeRowAction?
        private var trailingActions: [SwipeRowAction] = []
        private var onRevealChanged: ((Bool) -> Void)?
        private var onAction: ((String) -> Void)?
        private var onOffsetChanged: ((CGFloat, Bool) -> Void)?
        private var publishedOffset: CGFloat?
        private var offsetHandoffGeneration = 0
        private var isUpdatingView = false
        private var isBusy = false
        private var reduceMotion = false
        private var direction: CGFloat = 1
        private var offset: CGFloat = 0
        private var dragStartOffset: CGFloat = 0
        private var isDragging = false
        private var isArmed = false
        private var externalReveal = false
        private var wheelAxis = WheelAxis.idle
        private var wheelTranslation = CGPoint.zero
        private var suppressMomentum = false
        private var previousSize = CGSize.zero
        private var generation = 0
        private var detached = false
        // The overlay passes closed-row clicks through. A public ancestor observes
        // mouse drags without reparenting content or inspecting SwiftUI internals.
        private lazy var mousePan: NSPanGestureRecognizer = {
            let recognizer = NSPanGestureRecognizer(target: self, action: #selector(mousePanned))
            recognizer.delegate = self
            recognizer.buttonMask = 1
            // A click is delivered normally if the pan fails; a recognized drag must
            // not activate the SwiftUI navigation button underneath the pointer.
            recognizer.delaysPrimaryMouseButtonEvents = true
            return recognizer
        }()

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            // Native clipping is needed only for revealed controls. Closed List
            // rows create no action views and request no backing layers until needed.
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { nil }

        deinit { NotificationCenter.default.removeObserver(self) }

        func configure(
            id: AnyHashable, leading: SwipeRowAction?, trailing: [SwipeRowAction],
            isBusy: Bool, isRevealed: Bool, reduceMotion: Bool, isRightToLeft: Bool,
            onRevealChanged: @escaping (Bool) -> Void, onAction: @escaping (String) -> Void,
            onOffsetChanged: @escaping (CGFloat, Bool) -> Void
        ) {
            let wasUpdatingView = isUpdatingView
            isUpdatingView = true
            defer { isUpdatingView = wasUpdatingView }
            let nextDirection: CGFloat = isRightToLeft ? -1 : 1
            let identityChanged = identity != id
            if identityChanged {
                offsetHandoffGeneration += 1
                publishedOffset = nil
            }
            let leadingChanged = leadingAction != leading
            let trailingChanged = trailingActions != trailing
            let actionsChanged = leadingChanged || trailingChanged
            let directionChanged = direction != nextDirection
            let busyChanged = self.isBusy != isBusy
            let invalidated =
                identityChanged || actionsChanged || directionChanged || isBusy
            let lostOwnership = externalReveal && !isRevealed
            let oldRevealCallback = self.onRevealChanged
            let hadReveal = offset != 0 || isDragging || externalReveal
            self.onRevealChanged = onRevealChanged
            self.onAction = onAction
            self.onOffsetChanged = onOffsetChanged
            self.isBusy = isBusy
            self.reduceMotion = reduceMotion
            identity = id
            direction = nextDirection
            externalReveal = isRevealed
            if leadingChanged { leadingNeedsConfiguration = true }
            if trailingChanged { trailingNeedsConfiguration = true }
            leadingAction = leading
            trailingActions = trailing
            if invalidated {
                if hadReveal || identityChanged || actionsChanged || directionChanged || busyChanged
                {
                    close(animated: false, notify: false)
                }
                if hadReveal || isRevealed {
                    deferRevealClear(using: identityChanged ? oldRevealCallback : onRevealChanged)
                }
                if identityChanged, isRevealed {
                    // A remounted List bridge starts closed even if SwiftUI kept
                    // this row's reveal ID and offset state while it was offscreen.
                    deferRevealClear(using: onRevealChanged)
                }
            } else if lostOwnership || (!isRevealed && !isDragging && offset != 0) {
                close(animated: !isDragging, notify: false)
            }
            // A SwiftUI refresh may still contain the pre-gesture false value. Only
            // an observed true -> false transition revokes an in-flight gesture.
            // Offset settling already updates the controls. Unchanged closed rows
            // must not restart a close animation or schedule another layout pass.
            if identityChanged || actionsChanged || directionChanged || busyChanged {
                needsLayout = true
            }
        }

        override func layout() {
            let wasUpdatingView = isUpdatingView
            isUpdatingView = true
            defer { isUpdatingView = wasUpdatingView }
            super.layout()
            if previousSize != .zero, previousSize != bounds.size {
                close(animated: false, notify: false)
                deferRevealClear(using: onRevealChanged)
            }
            previousSize = bounds.size
            applyOffset()
        }

        override func viewDidMoveToWindow() {
            let wasUpdatingView = isUpdatingView
            isUpdatingView = true
            defer { isUpdatingView = wasUpdatingView }
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            detachGestures()
            observedScrollView = enclosingScrollView
            guard let window, !detached else {
                close(animated: false, notify: false)
                deferRevealClear(using: onRevealChanged)
                return
            }
            // NSScrollView (or the window's content view outside a list) is public
            // and contains both the original SwiftUI content and this overlay.
            gestureHost = observedScrollView ?? window.contentView
            gestureHost?.addGestureRecognizer(mousePan)
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowResigned), name: NSWindow.didResignKeyNotification,
                object: window)
            if let observedScrollView {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(scrollStarted),
                    name: NSScrollView.willStartLiveScrollNotification, object: observedScrollView)
            }
        }

        private func detachGestures() {
            gestureHost?.removeGestureRecognizer(mousePan)
            gestureHost = nil
            observedScrollView = nil
        }

        func detach() {
            detached = true
            generation += 1
            onRevealChanged = nil
            onAction = nil
            onOffsetChanged = nil
            offsetHandoffGeneration += 1
            NotificationCenter.default.removeObserver(self)
            detachGestures()
            close(animated: false, notify: false)
            mousePan.isEnabled = false
        }

        private func deferRevealClear(using callback: ((Bool) -> Void)?) {
            let expectedGeneration = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, !detached, generation == expectedGeneration, !isDragging,
                    offset == 0
                else { return }
                callback?(false)
            }
        }

        private func canDrag(_ translation: CGFloat) -> Bool {
            guard !isBusy, !detached else { return false }
            return offset != 0
                || (translation * direction > 0 ? leadingAction != nil : !trailingActions.isEmpty)
        }

        override func scrollWheel(with event: NSEvent) {
            guard !detached else {
                super.scrollWheel(with: event)
                return
            }
            if !event.momentumPhase.isEmpty {
                // AppKit can deliver momentum after the release, even after an action
                // changes this row's identity. Drain it without updating or committing.
                let consumed = suppressMomentum
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
                {
                    suppressMomentum = false
                }
                if !consumed { super.scrollWheel(with: event) }
                return
            }
            guard event.hasPreciseScrollingDeltas, !event.phase.isEmpty else {
                super.scrollWheel(with: event)
                return
            }
            if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                if isDragging { close(animated: false, notify: true) }
                wheelAxis = .pending
                wheelTranslation = .zero
                suppressMomentum = false
            }
            if event.phase.contains(.cancelled) {
                let consumed = wheelAxis == .horizontal || wheelAxis == .cancelled
                if isDragging { close(animated: true, notify: true) }
                wheelAxis = .idle
                suppressMomentum = consumed
                if !consumed { super.scrollWheel(with: event) }
                return
            }
            if wheelAxis == .pending || wheelAxis == .horizontal {
                wheelTranslation.x += event.scrollingDeltaX
                wheelTranslation.y += event.scrollingDeltaY
            }
            if wheelAxis == .pending {
                let x = abs(wheelTranslation.x)
                let y = abs(wheelTranslation.y)
                if max(x, y) >= 3 {
                    if x > y * 1.2, canDrag(wheelTranslation.x) {
                        wheelAxis = .horizontal
                        beginDrag()
                    } else {
                        wheelAxis = .vertical
                        close(animated: true, notify: true)
                    }
                }
            }
            let consumed = wheelAxis == .horizontal || wheelAxis == .cancelled
            if wheelAxis == .horizontal, isDragging { updateDrag(translation: wheelTranslation.x) }
            if event.phase.contains(.ended) {
                if wheelAxis == .horizontal, isDragging { finishDrag() }
                suppressMomentum = consumed
                wheelAxis = .idle
            }
            if !consumed { super.scrollWheel(with: event) }
        }

        private func beginDrag() {
            generation += 1
            stopAnimations()
            isDragging = true
            isArmed = false
            dragStartOffset = offset
            onRevealChanged?(true)
        }

        private func updateDrag(translation: CGFloat) {
            offset = SwipeRowMetrics.dragOffset(
                proposed: dragStartOffset + translation * direction, width: bounds.width,
                hasLeading: leadingAction != nil, trailingCount: trailingActions.count)
            isArmed =
                leadingAction != nil
                && offset >= SwipeRowMetrics.commitBoundary(width: bounds.width)
            applyOffset()
            publishOffset(animated: false)
        }

        private func finishDrag() {
            let action = isArmed && !isBusy ? leadingAction?.action : nil
            isDragging = false
            isArmed = false
            if let action {
                performAction(action)
            } else {
                settle(
                    to: SwipeRowMetrics.restingOffset(
                        offset: offset, trailingCount: trailingActions.count),
                    animated: true, notify: true)
            }
        }

        private func performAction(_ action: String) {
            let actionIdentity = identity
            let callback = onAction
            close(animated: true, notify: true)
            guard !detached, identity == actionIdentity else { return }
            callback?(action)
        }

        private func close(animated: Bool, notify: Bool) {
            generation += 1
            let hadReveal = offset != 0 || isDragging || externalReveal
            if wheelAxis == .horizontal {
                wheelAxis = .cancelled
                suppressMomentum = true
            }
            isDragging = false
            isArmed = false
            if mousePan.state == .began || mousePan.state == .changed {
                mousePan.isEnabled = false
                mousePan.isEnabled = true
            }
            settle(to: 0, animated: animated, notify: notify && hadReveal)
        }

        private func settle(to target: CGFloat, animated: Bool, notify: Bool) {
            stopAnimations()
            offset = target
            if animated, !reduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = SwipeRowMetrics.animationDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    applyOffset(animated: true)
                }
            } else {
                applyOffset()
            }
            if notify { onRevealChanged?(target != 0) }
            publishOffset(animated: animated && !reduceMotion)
        }

        private func stopAnimations() {
            let leadingPresentation = leadingClip?.layer?.presentation()
            let trailingPresentation = trailingClip?.layer?.presentation()
            if leadingPresentation != nil || trailingPresentation != nil {
                let leadingWidth = leadingPresentation?.bounds.width ?? 0
                offset =
                    leadingWidth > 0 ? leadingWidth : -(trailingPresentation?.bounds.width ?? 0)
            }
            leadingClip?.layer?.removeAllAnimations()
            trailingClip?.layer?.removeAllAnimations()
            leadingButton?.layer?.removeAllAnimations()
            for button in trailingButtons {
                button.layer?.removeAllAnimations()
            }
            applyOffset()
            publishOffset(animated: false)
        }

        private func publishOffset(animated: Bool) {
            let physicalOffset = offset * direction
            guard publishedOffset != physicalOffset else { return }
            publishedOffset = physicalOffset
            offsetHandoffGeneration += 1
            let handoff = offsetHandoffGeneration
            if isUpdatingView {
                let updatedIdentity = identity
                DispatchQueue.main.async { [weak self] in
                    guard let self, !detached, offsetHandoffGeneration == handoff,
                        identity == updatedIdentity, publishedOffset == physicalOffset
                    else { return }
                    onOffsetChanged?(physicalOffset, animated)
                }
            } else {
                onOffsetChanged?(physicalOffset, animated)
            }
        }

        private func makeControlsClip() -> NSView {
            wantsLayer = true
            layer?.masksToBounds = true
            let clip = NSView()
            clip.wantsLayer = true
            clip.layer?.masksToBounds = true
            clip.setAccessibilityElement(false)
            addSubview(clip)
            return clip
        }

        private func prepareLeadingControls() {
            guard let leadingAction else { return }
            if leadingClip == nil { leadingClip = makeControlsClip() }
            if leadingButton == nil {
                let button = SwipeRowAppKitButton()
                button.target = self
                button.action = #selector(tappedLeading)
                leadingClip?.addSubview(button)
                leadingButton = button
            }
            if leadingNeedsConfiguration {
                leadingButton?.configure(leadingAction)
                leadingNeedsConfiguration = false
            }
        }

        private func prepareTrailingControls() {
            guard !trailingActions.isEmpty else { return }
            if trailingClip == nil { trailingClip = makeControlsClip() }
            guard trailingNeedsConfiguration else { return }
            while trailingButtons.count > trailingActions.count {
                trailingButtons.removeLast().removeFromSuperview()
            }
            while trailingButtons.count < trailingActions.count {
                let button = SwipeRowAppKitButton()
                button.tag = trailingButtons.count
                button.target = self
                button.action = #selector(tappedTrailing)
                trailingClip?.addSubview(button)
                trailingButtons.append(button)
            }
            for (button, action) in zip(trailingButtons, trailingActions) {
                button.configure(action)
            }
            trailingNeedsConfiguration = false
        }

        private func applyOffset(animated: Bool = false) {
            func place(_ view: NSView?, _ frame: CGRect) {
                guard let view else { return }
                if animated { view.animator().frame = frame } else { view.frame = frame }
            }
            let leadingWidth = max(0, offset)
            let trailingWidth = max(0, -offset)
            // Configure from the latest actions only when that side becomes visible;
            // layout, accessibility and closed-row hit testing must not materialize it.
            if leadingWidth > 0 { prepareLeadingControls() }
            if trailingWidth > 0 { prepareTrailingControls() }
            place(
                leadingClip,
                CGRect(
                    x: direction > 0 ? 0 : bounds.width - leadingWidth,
                    y: 0, width: leadingWidth, height: bounds.height))
            place(
                trailingClip,
                CGRect(
                    x: direction > 0 ? bounds.width - trailingWidth : 0,
                    y: 0, width: trailingWidth, height: bounds.height))
            leadingClip?.isHidden = leadingAction == nil
            trailingClip?.isHidden = trailingActions.isEmpty
            leadingClip?.setAccessibilityHidden(leadingWidth == 0 || leadingAction == nil || isBusy)
            trailingClip?.setAccessibilityHidden(
                trailingWidth == 0 || trailingActions.isEmpty || isBusy)
            let y = (bounds.height - SwipeRowMetrics.diameter) / 2
            let width = max(SwipeRowMetrics.diameter, leadingWidth - SwipeRowMetrics.edgeInset * 2)
            place(
                leadingButton,
                CGRect(
                    x: direction > 0
                        ? SwipeRowMetrics.edgeInset
                        : leadingWidth - SwipeRowMetrics.edgeInset - width,
                    y: y, width: width, height: SwipeRowMetrics.diameter))
            leadingButton?.isEnabled = !isBusy && leadingWidth > 0
            for (index, button) in trailingButtons.enumerated() {
                let inset =
                    SwipeRowMetrics.edgeInset + CGFloat(index)
                    * (SwipeRowMetrics.diameter + SwipeRowMetrics.spacing)
                place(
                    button,
                    CGRect(
                        x: direction > 0 ? trailingWidth - inset - SwipeRowMetrics.diameter : inset,
                        y: y, width: SwipeRowMetrics.diameter, height: SwipeRowMetrics.diameter))
                button.isEnabled = !isBusy && trailingWidth > 0
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !detached, !isHidden, bounds.contains(convert(point, from: superview)),
                let hit = super.hitTest(point)
            else { return nil }
            // Wheel events must reach the phase arbiter even when the content is
            // closed. Unconsumed vertical events continue through nextResponder.
            if NSApp.currentEvent?.type == .scrollWheel { return self }
            if hit is NSButton { return hit }
            // A revealed row consumes the closing click, never navigation. In the
            // closed state ordinary clicks pass to the original SwiftUI content.
            return offset != 0 ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            if offset != 0 {
                close(animated: true, notify: true)
            } else {
                super.mouseDown(with: event)
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent
        ) -> Bool {
            guard !isBusy, !detached, window != nil, !isHidden,
                event.type == .leftMouseDown,
                !event.modifierFlags.contains(.control), wheelAxis != .horizontal
            else { return false }
            let point = convert(event.locationInWindow, from: nil)
            // Buttons retain native click tracking rather than becoming drag handles.
            let contentFrame = CGRect(
                x: offset * direction, y: 0, width: bounds.width, height: bounds.height)
            return bounds.contains(point) && visibleRect.contains(point)
                && contentFrame.contains(point)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
            let translation = mousePan.translation(in: self)
            return abs(translation.x) > abs(translation.y) * 1.2 && canDrag(translation.x)
        }

        @objc private func mousePanned(_ recognizer: NSPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                beginDrag()
                updateDrag(translation: recognizer.translation(in: self).x)
            case .changed:
                if isDragging { updateDrag(translation: recognizer.translation(in: self).x) }
            case .ended:
                if isDragging {
                    updateDrag(translation: recognizer.translation(in: self).x)
                    finishDrag()
                }
            case .cancelled, .failed:
                if isDragging { close(animated: true, notify: true) }
            default: break
            }
        }

        @objc private func tappedLeading() {
            guard !isBusy, offset > 0, let action = leadingAction?.action else { return }
            performAction(action)
        }

        @objc private func tappedTrailing(_ button: NSButton) {
            guard !isBusy, offset < 0, trailingActions.indices.contains(button.tag) else { return }
            let action = trailingActions[button.tag].action
            performAction(action)
        }

        @objc private func windowResigned() {
            let wasUpdatingView = isUpdatingView
            isUpdatingView = true
            defer { isUpdatingView = wasUpdatingView }
            // A responder/window notification may be nested in SwiftUI's native
            // reconciliation. Close the surface now, publish ownership afterward.
            close(animated: false, notify: false)
            deferRevealClear(using: onRevealChanged)
        }

        @objc private func scrollStarted() {
            let wasUpdatingView = isUpdatingView
            isUpdatingView = true
            defer { isUpdatingView = wasUpdatingView }
            if !isDragging, wheelAxis != .pending {
                close(animated: true, notify: false)
                deferRevealClear(using: onRevealChanged)
            }
        }
    }

    private final class SwipeRowAppKitButton: NSButton {
        private var tint = NSColor.clear

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            isBordered = false
            title = ""
            imagePosition = .imageOnly
            setButtonType(.momentaryChange)
        }

        required init?(coder: NSCoder) { nil }

        func configure(_ action: SwipeRowAction) {
            tint = NSColor(action.tint)
            let configuration = NSImage.SymbolConfiguration(
                pointSize: SwipeRowMetrics.symbolSize, weight: .semibold
            )
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            setAccessibilityLabel(action.title)
            toolTip = action.title
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(
                roundedRect: bounds, xRadius: SwipeRowMetrics.diameter / 2,
                yRadius: SwipeRowMetrics.diameter / 2)
            tint.withAlphaComponent(isHighlighted ? 0.75 : 1).setFill()
            path.fill()
            if let image {
                let size = image.size
                image.draw(
                    in: CGRect(
                        x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                        width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.5,
                    respectFlipped: true, hints: nil)
            }
        }
    }
#endif
