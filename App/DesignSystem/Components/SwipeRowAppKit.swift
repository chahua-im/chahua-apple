#if os(macOS)
import AppKit
import QuartzCore
import SwiftUI

/// SwiftUI's swipeActions cannot expose drag progress or circular action controls.
/// AppKit owns phased wheel events here so vertical scrolling stays in the native
/// responder chain and momentum can never turn into a second release-only commit.
struct SwipeRowAppKit<Content: View>: NSViewRepresentable {
    let id: AnyHashable
    let isRevealed: Bool
    let leadingAction: SwipeRowAction?
    let trailingActions: [SwipeRowAction]
    let isBusy: Bool
    let onRevealChanged: (Bool) -> Void
    let onAction: (String) -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> SwipeRowAppKitContainer {
        SwipeRowAppKitContainer()
    }

    func updateNSView(_ view: SwipeRowAppKitContainer, context: Context) {
        view.setContent(content(), environment: context.environment)
        view.configure(
            id: id, leading: leadingAction, trailing: trailingActions,
            isBusy: isBusy, isRevealed: isRevealed,
            reduceMotion: context.environment.accessibilityReduceMotion,
            isRightToLeft: context.environment.layoutDirection == .rightToLeft,
            onRevealChanged: onRevealChanged, onAction: onAction)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SwipeRowAppKitContainer, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return nsView.contentSize(fitting: width)
    }

    static func dismantleNSView(_ view: SwipeRowAppKitContainer, coordinator: ()) {
        view.detach()
    }
}

@MainActor
final class SwipeRowAppKitContainer: NSView, NSGestureRecognizerDelegate {
    private enum WheelAxis { case idle, pending, horizontal, vertical, cancelled }

    private let leadingClip = NSView()
    private let trailingClip = NSView()
    private let leadingButton = SwipeRowAppKitButton()
    private var trailingButtons: [SwipeRowAppKitButton] = []
    private let hostedContent = SwipeRowAppKitHostingView(rootView: SwipeRowAppKitContent(content: AnyView(EmptyView())))
    private weak var observedScrollView: NSScrollView?
    private var identity: AnyHashable?
    private var leadingAction: SwipeRowAction?
    private var trailingActions: [SwipeRowAction] = []
    private var onRevealChanged: ((Bool) -> Void)?
    private var onAction: ((String) -> Void)?
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
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
        for clip in [leadingClip, trailingClip] {
            clip.wantsLayer = true
            clip.layer?.masksToBounds = true
            clip.setAccessibilityElement(false)
            addSubview(clip)
        }
        leadingButton.target = self
        leadingButton.action = #selector(tappedLeading)
        leadingClip.addSubview(leadingButton)
        hostedContent.owner = self
        hostedContent.sizingOptions = .intrinsicContentSize
        hostedContent.safeAreaRegions = []
        hostedContent.wantsLayer = true
        hostedContent.layer?.masksToBounds = true
        addSubview(hostedContent)
        addGestureRecognizer(mousePan)
    }

    required init?(coder: NSCoder) { nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    func setContent<Content: View>(_ content: Content, environment: EnvironmentValues) {
        hostedContent.rootView.content = AnyView(content.environment(\.self, environment))
    }

    func contentSize(fitting width: CGFloat) -> CGSize {
        if hostedContent.rootView.width != width { hostedContent.rootView.width = width }
        return CGSize(width: width, height: hostedContent.fittingSize.height)
    }

    func configure(
        id: AnyHashable, leading: SwipeRowAction?, trailing: [SwipeRowAction],
        isBusy: Bool, isRevealed: Bool, reduceMotion: Bool, isRightToLeft: Bool,
        onRevealChanged: @escaping (Bool) -> Void, onAction: @escaping (String) -> Void
    ) {
        let nextDirection: CGFloat = isRightToLeft ? -1 : 1
        let identityChanged = identity != id
        let actionsChanged = leadingAction != leading || trailingActions != trailing
        let invalidated = identityChanged || actionsChanged || direction != nextDirection || isBusy
        let lostOwnership = externalReveal && !isRevealed
        let oldRevealCallback = self.onRevealChanged
        let hadReveal = offset != 0 || isDragging || externalReveal
        self.onRevealChanged = onRevealChanged
        self.onAction = onAction
        self.isBusy = isBusy
        self.reduceMotion = reduceMotion
        identity = id
        direction = nextDirection
        leadingAction = leading
        trailingActions = trailing
        externalReveal = isRevealed
        if actionsChanged {
            if let leading { leadingButton.configure(leading) }
            while trailingButtons.count > trailing.count {
                trailingButtons.removeLast().removeFromSuperview()
            }
            while trailingButtons.count < trailing.count {
                let button = SwipeRowAppKitButton()
                button.tag = trailingButtons.count
                button.target = self
                button.action = #selector(tappedTrailing)
                trailingClip.addSubview(button)
                trailingButtons.append(button)
            }
            for (button, action) in zip(trailingButtons, trailing) { button.configure(action) }
        }
        if invalidated {
            close(animated: false, notify: false)
            if hadReveal || isRevealed {
                deferRevealClear(using: identityChanged ? oldRevealCallback : onRevealChanged)
            }
        } else if lostOwnership || (!isRevealed && !isDragging) {
            close(animated: !isDragging, notify: false)
        }
        // A SwiftUI refresh may still contain the pre-gesture false value. Only
        // an observed true -> false transition revokes an in-flight gesture.
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if previousSize != .zero, previousSize != bounds.size {
            close(animated: false, notify: false)
            deferRevealClear(using: onRevealChanged)
        }
        previousSize = bounds.size
        if hostedContent.rootView.width != bounds.width { hostedContent.rootView.width = bounds.width }
        applyOffset()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        observedScrollView = enclosingScrollView
        guard let window, !detached else {
            close(animated: false, notify: false)
            deferRevealClear(using: onRevealChanged)
            return
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowResigned), name: NSWindow.didResignKeyNotification, object: window)
        if let observedScrollView {
            NotificationCenter.default.addObserver(
                self, selector: #selector(scrollStarted),
                name: NSScrollView.willStartLiveScrollNotification, object: observedScrollView)
        }
    }

    func detach() {
        detached = true
        generation += 1
        onRevealChanged = nil
        onAction = nil
        hostedContent.owner = nil
        NotificationCenter.default.removeObserver(self)
        observedScrollView = nil
        close(animated: false, notify: false)
        mousePan.isEnabled = false
    }

    private func deferRevealClear(using callback: ((Bool) -> Void)?) {
        let expectedGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, !detached, generation == expectedGeneration, !isDragging, offset == 0 else { return }
            callback?(false)
        }
    }

    private func canDrag(_ translation: CGFloat) -> Bool {
        guard !isBusy, !detached else { return false }
        return offset != 0 || (translation * direction > 0 ? leadingAction != nil : !trailingActions.isEmpty)
    }

    override func scrollWheel(with event: NSEvent) {
        guard !detached else { super.scrollWheel(with: event); return }
        if !event.momentumPhase.isEmpty {
            // AppKit can deliver momentum after the release, even after an action
            // changes this row's identity. Drain it without updating or committing.
            let consumed = suppressMomentum
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
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
        isArmed = leadingAction != nil && offset >= SwipeRowMetrics.commitBoundary(width: bounds.width)
        applyOffset()
    }

    private func finishDrag() {
        let action = isArmed && !isBusy ? leadingAction?.action : nil
        isDragging = false
        isArmed = false
        if let action {
            performAction(action)
        } else {
            settle(to: SwipeRowMetrics.restingOffset(offset: offset, trailingCount: trailingActions.count),
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
    }

    private func stopAnimations() {
        if let presentation = hostedContent.layer?.presentation() {
            offset = presentation.frame.minX * direction
        }
        for view in [hostedContent, leadingClip, trailingClip, leadingButton] + trailingButtons {
            view.layer?.removeAllAnimations()
        }
        applyOffset()
    }

    private func applyOffset(animated: Bool = false) {
        func place(_ view: NSView, _ frame: CGRect) {
            if animated { view.animator().frame = frame }
            else { view.frame = frame }
        }
        place(hostedContent, CGRect(x: offset * direction, y: 0, width: bounds.width, height: bounds.height))
        let leadingWidth = max(0, offset)
        let trailingWidth = max(0, -offset)
        place(leadingClip, CGRect(x: direction > 0 ? 0 : bounds.width - leadingWidth,
                                  y: 0, width: leadingWidth, height: bounds.height))
        place(trailingClip, CGRect(x: direction > 0 ? bounds.width - trailingWidth : 0,
                                   y: 0, width: trailingWidth, height: bounds.height))
        leadingClip.isHidden = leadingAction == nil
        trailingClip.isHidden = trailingActions.isEmpty
        leadingClip.setAccessibilityHidden(leadingWidth == 0 || leadingAction == nil || isBusy)
        trailingClip.setAccessibilityHidden(trailingWidth == 0 || trailingActions.isEmpty || isBusy)
        let y = (bounds.height - SwipeRowMetrics.diameter) / 2
        let width = max(SwipeRowMetrics.diameter, leadingWidth - SwipeRowMetrics.edgeInset * 2)
        place(leadingButton, CGRect(x: direction > 0 ? SwipeRowMetrics.edgeInset : leadingWidth - SwipeRowMetrics.edgeInset - width,
                                    y: y, width: width, height: SwipeRowMetrics.diameter))
        leadingButton.isEnabled = !isBusy && leadingWidth > 0
        leadingButton.isArmed = isArmed
        for (index, button) in trailingButtons.enumerated() {
            let inset = SwipeRowMetrics.edgeInset + CGFloat(index) * (SwipeRowMetrics.diameter + SwipeRowMetrics.spacing)
            place(button, CGRect(x: direction > 0 ? trailingWidth - inset - SwipeRowMetrics.diameter : inset,
                                 y: y, width: SwipeRowMetrics.diameter, height: SwipeRowMetrics.diameter))
            button.isEnabled = !isBusy && trailingWidth > 0
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if offset != 0, hit === hostedContent || hit.isDescendant(of: hostedContent) { return self }
        return hit
    }

    override func mouseDown(with event: NSEvent) {
        if offset != 0 { close(animated: true, notify: true) }
        else { super.mouseDown(with: event) }
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard !isBusy, !detached, event.type == .leftMouseDown,
              !event.modifierFlags.contains(.control), wheelAxis != .horizontal else { return false }
        let point = convert(event.locationInWindow, from: nil)
        // Buttons retain native click tracking rather than becoming drag handles.
        return hostedContent.frame.contains(point)
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

    @objc private func windowResigned() { close(animated: false, notify: true) }

    @objc private func scrollStarted() {
        if !isDragging, wheelAxis != .pending { close(animated: true, notify: true) }
    }
}

private struct SwipeRowAppKitContent: View {
    var content: AnyView
    var width: CGFloat?

    var body: some View { content.frame(width: width) }
}

private final class SwipeRowAppKitHostingView: NSHostingView<SwipeRowAppKitContent> {
    weak var owner: SwipeRowAppKitContainer?

    override func scrollWheel(with event: NSEvent) {
        if let owner { owner.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }
}

private final class SwipeRowAppKitButton: NSButton {
    private var tint = NSColor.clear
    var isArmed = false {
        didSet { if isArmed != oldValue { needsDisplay = true } }
    }

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
        let configuration = NSImage.SymbolConfiguration(pointSize: SwipeRowMetrics.symbolSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        setAccessibilityLabel(action.title)
        toolTip = action.title
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: SwipeRowMetrics.diameter / 2,
                                yRadius: SwipeRowMetrics.diameter / 2)
        tint.withAlphaComponent(isHighlighted ? 0.75 : 1).setFill()
        path.fill()
        if isArmed {
            NSColor.white.setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                      xRadius: SwipeRowMetrics.diameter / 2, yRadius: SwipeRowMetrics.diameter / 2)
            border.lineWidth = 2
            border.stroke()
        }
        if let image {
            let size = image.size
            image.draw(in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                  width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.5,
                       respectFlipped: true, hints: nil)
        }
    }
}
#endif
