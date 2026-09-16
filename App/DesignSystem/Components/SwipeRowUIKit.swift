#if os(iOS)
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// SwiftUI's swipeActions owns rectangular backgrounds and hides drag progress.
/// This iOS-only container is needed for circular controls, continuous capsule
/// stretching, release-only commits, and directional arbitration with List's pan.
/// The actual row content and its accessibility actions remain SwiftUI.
struct SwipeRowUIKit<Content: View>: UIViewRepresentable {
    let id: AnyHashable
    let isRevealed: Bool
    let leadingAction: SwipeRowAction?
    let trailingActions: [SwipeRowAction]
    let isBusy: Bool
    let onRevealChanged: (Bool) -> Void
    let onAction: (String) -> Void
    @ViewBuilder let content: () -> Content

    func makeUIView(context: Context) -> SwipeRowUIKitContainer {
        SwipeRowUIKitContainer()
    }

    func updateUIView(_ view: SwipeRowUIKitContainer, context: Context) {
        view.setContent(content(), environment: context.environment)
        view.configure(
            id: id, leading: leadingAction, trailing: trailingActions,
            isBusy: isBusy, isRevealed: isRevealed,
            reduceMotion: context.environment.accessibilityReduceMotion,
            isRightToLeft: context.environment.layoutDirection == .rightToLeft,
            onRevealChanged: onRevealChanged, onAction: onAction)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SwipeRowUIKitContainer, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiView.contentSize(fitting: width)
    }

    static func dismantleUIView(_ view: SwipeRowUIKitContainer, coordinator: ()) {
        view.detach()
    }
}

final class SwipeRowUIKitContainer: UIView, UIGestureRecognizerDelegate {
    private let leadingClip = UIView()
    private let trailingClip = UIView()
    private let leadingButton = UIButton(type: .system)
    private var trailingButtons: [UIButton] = []
    private var hostedContent: (UIView & UIContentView)?
    private weak var observedScrollView: UIScrollView?
    private var identity: AnyHashable?
    private var leadingAction: SwipeRowAction?
    private var trailingActions: [SwipeRowAction] = []
    private var isBusy = false
    private var reduceMotion = false
    private var direction: CGFloat = 1
    private var offset: CGFloat = 0
    private var dragStartOffset: CGFloat = 0
    private var isDragging = false
    private var isArmed = false
    private var previousWidth: CGFloat = 0
    private var onRevealChanged: ((Bool) -> Void)?
    private var onAction: ((String) -> Void)?
    private lazy var feedback = UIImpactFeedbackGenerator(style: .medium)
    private lazy var pan: SwipeRowUIKitPanRecognizer = {
        let recognizer = SwipeRowUIKitPanRecognizer(target: self, action: #selector(panned))
        recognizer.delegate = self
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.canStart = { [weak self] translation in
            guard let self, !isBusy else { return false }
            if offset != 0 { return true }
            return translation * direction > 0 ? leadingAction != nil : !trailingActions.isEmpty
        }
        return recognizer
    }()
    private lazy var dismissTap: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(tappedContent))
        recognizer.delegate = self
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        return recognizer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        leadingClip.clipsToBounds = true
        trailingClip.clipsToBounds = true
        addSubview(leadingClip)
        addSubview(trailingClip)
        leadingClip.addSubview(leadingButton)
        leadingButton.addTarget(self, action: #selector(tappedLeading), for: .touchUpInside)
        addGestureRecognizer(pan)
        addGestureRecognizer(dismissTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setContent<Content: View>(_ content: Content, environment: EnvironmentValues) {
        // UIHostingConfiguration supplies native self-sizing without inventing a
        // child view-controller hierarchy for every SwiftUI List row.
        let configuration = UIHostingConfiguration {
            content.environment(\.self, environment)
        }.margins(.all, 0)
        if let hostedContent {
            hostedContent.configuration = configuration
        } else {
            let hostedContent = configuration.makeContentView()
            hostedContent.backgroundColor = .clear
            hostedContent.clipsToBounds = true
            addSubview(hostedContent)
            self.hostedContent = hostedContent
        }
    }

    func contentSize(fitting width: CGFloat) -> CGSize {
        let height = hostedContent?.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height ?? 0
        return CGSize(width: width, height: height)
    }

    func configure(
        id: AnyHashable, leading: SwipeRowAction?, trailing: [SwipeRowAction],
        isBusy: Bool, isRevealed: Bool, reduceMotion: Bool, isRightToLeft: Bool,
        onRevealChanged: @escaping (Bool) -> Void, onAction: @escaping (String) -> Void
    ) {
        let nextDirection: CGFloat = isRightToLeft ? -1 : 1
        let identityChanged = identity != id
        let actionsChanged = leadingAction != leading || trailingActions != trailing
        let directionChanged = direction != nextDirection
        self.onRevealChanged = onRevealChanged
        self.onAction = onAction
        self.isBusy = isBusy
        self.reduceMotion = reduceMotion
        identity = id
        direction = nextDirection
        leadingAction = leading
        trailingActions = trailing
        if actionsChanged {
            if let leading { configure(leadingButton, action: leading) }
            while trailingButtons.count > trailing.count {
                trailingButtons.removeLast().removeFromSuperview()
            }
            while trailingButtons.count < trailing.count {
                let button = UIButton(type: .system)
                button.tag = trailingButtons.count
                button.addTarget(self, action: #selector(tappedTrailing), for: .touchUpInside)
                trailingClip.addSubview(button)
                trailingButtons.append(button)
            }
            for (button, action) in zip(trailingButtons, trailing) { configure(button, action: action) }
        }
        leadingButton.isEnabled = !isBusy
        for button in trailingButtons { button.isEnabled = !isBusy }
        if identityChanged || directionChanged || (actionsChanged && isDragging) {
            close(animated: false, notify: false)
        } else if isBusy || !isRevealed {
            close(animated: !isDragging, notify: false)
        }
        setNeedsLayout()
    }

    private func configure(_ button: UIButton, action: SwipeRowAction) {
        button.setImage(UIImage(systemName: action.symbol), for: .normal)
        button.setPreferredSymbolConfiguration(.init(pointSize: SwipeRowMetrics.symbolSize, weight: .semibold), forImageIn: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor(action.tint)
        button.layer.cornerRadius = SwipeRowMetrics.diameter / 2
        button.accessibilityLabel = action.title
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        observedScrollView?.panGestureRecognizer.removeTarget(self, action: #selector(scrolled))
        observedScrollView = nil
        guard window != nil else {
            close(animated: false, notify: false)
            return
        }
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? UIScrollView {
                observedScrollView = scrollView
                scrollView.panGestureRecognizer.addTarget(self, action: #selector(scrolled))
                break
            }
            ancestor = view.superview
        }
    }

    func detach() {
        onRevealChanged = nil
        onAction = nil
        close(animated: false, notify: false)
        observedScrollView?.panGestureRecognizer.removeTarget(self, action: #selector(scrolled))
        observedScrollView = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if previousWidth > 0, previousWidth != bounds.width {
            close(animated: false, notify: false)
            // Geometry can change during a SwiftUI update; clear shared reveal
            // ownership outside that update, without closing a newly reused row.
            let resizedIdentity = identity
            DispatchQueue.main.async { [weak self] in
                guard let self, identity == resizedIdentity, offset == 0 else { return }
                onRevealChanged?(false)
            }
        }
        previousWidth = bounds.width
        hostedContent?.bounds = bounds
        hostedContent?.center = CGPoint(x: bounds.midX, y: bounds.midY)
        applyOffset()
    }

    private func applyOffset() {
        hostedContent?.transform = CGAffineTransform(translationX: offset * direction, y: 0)
        let leadingWidth = max(0, offset)
        let trailingWidth = max(0, -offset)
        leadingClip.frame = CGRect(
            x: direction > 0 ? 0 : bounds.width - leadingWidth, y: 0,
            width: leadingWidth, height: bounds.height)
        trailingClip.frame = CGRect(
            x: direction > 0 ? bounds.width - trailingWidth : 0, y: 0,
            width: trailingWidth, height: bounds.height)
        leadingClip.isHidden = leadingAction == nil
        trailingClip.isHidden = trailingActions.isEmpty
        leadingClip.accessibilityElementsHidden = leadingWidth == 0 || leadingClip.isHidden || isBusy
        trailingClip.accessibilityElementsHidden = trailingWidth == 0 || trailingClip.isHidden || isBusy
        let y = (bounds.height - SwipeRowMetrics.diameter) / 2
        let stretchedWidth = max(SwipeRowMetrics.diameter, leadingWidth - SwipeRowMetrics.edgeInset * 2)
        leadingButton.frame = CGRect(
            x: direction > 0 ? SwipeRowMetrics.edgeInset : leadingWidth - SwipeRowMetrics.edgeInset - stretchedWidth,
            y: y, width: stretchedWidth, height: SwipeRowMetrics.diameter)
        for (index, button) in trailingButtons.enumerated() {
            let inset = SwipeRowMetrics.edgeInset + CGFloat(index) * (SwipeRowMetrics.diameter + SwipeRowMetrics.spacing)
            button.frame = CGRect(
                x: direction > 0 ? trailingWidth - inset - SwipeRowMetrics.diameter : inset,
                y: y, width: SwipeRowMetrics.diameter, height: SwipeRowMetrics.diameter)
        }
    }

    private func updateDrag(translation: CGFloat) {
        let proposed = dragStartOffset + translation * direction
        offset = SwipeRowMetrics.dragOffset(
            proposed: proposed, width: bounds.width,
            hasLeading: leadingAction != nil, trailingCount: trailingActions.count)
        let shouldArm = leadingAction != nil && offset >= SwipeRowMetrics.commitBoundary(width: bounds.width)
        if shouldArm != isArmed {
            isArmed = shouldArm
            if shouldArm { feedback.impactOccurred() }
            else { feedback.prepare() }
        }
        applyOffset()
    }

    private func stopAnimations() {
        if let presentation = hostedContent?.layer.presentation() {
            offset = presentation.affineTransform().tx * direction
        }
        hostedContent?.layer.removeAllAnimations()
        leadingClip.layer.removeAllAnimations()
        trailingClip.layer.removeAllAnimations()
        leadingButton.layer.removeAllAnimations()
        for button in trailingButtons { button.layer.removeAllAnimations() }
        applyOffset()
    }

    private func settle(to target: CGFloat, animated: Bool, notify: Bool) {
        offset = target
        if animated, !reduceMotion {
            UIView.animate(
                withDuration: SwipeRowMetrics.animationDuration, delay: 0,
                options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction]
            ) { self.applyOffset() }
        } else {
            stopAnimations()
            offset = target
            applyOffset()
        }
        if notify { onRevealChanged?(target != 0) }
    }

    private func close(animated: Bool, notify: Bool) {
        let wasDragging = isDragging
        isDragging = false
        isArmed = false
        if wasDragging {
            pan.isEnabled = false
            pan.isEnabled = true
        }
        guard offset != 0 else {
            if !animated {
                stopAnimations()
                offset = 0
                applyOffset()
            }
            return
        }
        settle(to: 0, animated: animated, notify: notify)
    }

    @objc private func panned(_ recognizer: SwipeRowUIKitPanRecognizer) {
        switch recognizer.state {
        case .began:
            guard !isBusy else { return }
            stopAnimations()
            isDragging = true
            dragStartOffset = offset
            isArmed = false
            feedback.prepare()
            onRevealChanged?(true)
            updateDrag(translation: recognizer.translation.x)
        case .changed:
            guard isDragging else { return }
            updateDrag(translation: recognizer.translation.x)
        case .ended:
            guard isDragging else { return }
            updateDrag(translation: recognizer.translation.x)
            let committedAction = isArmed ? leadingAction?.action : nil
            isDragging = false
            isArmed = false
            if let committedAction, !isBusy {
                settle(to: 0, animated: true, notify: true)
                onAction?(committedAction)
            } else {
                let target = SwipeRowMetrics.restingOffset(offset: offset, trailingCount: trailingActions.count)
                settle(to: target, animated: true, notify: true)
            }
        case .cancelled, .failed:
            guard isDragging else { return }
            isDragging = false
            isArmed = false
            settle(to: 0, animated: true, notify: true)
        default:
            break
        }
    }

    @objc private func tappedLeading() {
        guard !isBusy, offset > 0, let leadingAction else { return }
        close(animated: true, notify: true)
        onAction?(leadingAction.action)
    }

    @objc private func tappedTrailing(_ button: UIButton) {
        guard !isBusy, offset < 0, trailingActions.indices.contains(button.tag) else { return }
        let action = trailingActions[button.tag].action
        close(animated: true, notify: true)
        onAction?(action)
    }

    @objc private func tappedContent() { close(animated: true, notify: true) }

    @objc private func scrolled() {
        if observedScrollView?.panGestureRecognizer.state == .began, !isDragging {
            close(animated: true, notify: true)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard !UIAccessibility.isVoiceOverRunning else { return false }
        if gestureRecognizer === dismissTap {
            guard offset != 0, let touchedView = touch.view else { return false }
            return !touchedView.isDescendant(of: leadingClip) && !touchedView.isDescendant(of: trailingClip)
        }
        return !isBusy
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        otherGestureRecognizer is UIScreenEdgePanGestureRecognizer
    }
}

/// Fail vertical motion before the enclosing scroll view starts, rather than
/// attaching a SwiftUI DragGesture that claims both axes and blocks List refresh.
private final class SwipeRowUIKitPanRecognizer: UIGestureRecognizer {
    var canStart: ((CGFloat) -> Bool)?
    private(set) var translation: CGPoint = .zero
    private var initialLocation: CGPoint = .zero
    private var trackedTouch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard trackedTouch == nil, touches.count == 1, let touch = touches.first else {
            state = state == .began || state == .changed ? .cancelled : .failed
            return
        }
        trackedTouch = touch
        initialLocation = touch.location(in: view)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        updateTranslation(trackedTouch)
        if state == .possible {
            let horizontal = abs(translation.x)
            let vertical = abs(translation.y)
            guard max(horizontal, vertical) >= 7 else { return }
            guard horizontal > vertical * 1.25, canStart?(translation.x) == true else {
                state = .failed
                return
            }
            state = .began
        } else if state == .began || state == .changed {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        updateTranslation(trackedTouch)
        state = state == .began || state == .changed ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = state == .began || state == .changed ? .cancelled : .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard state == .began || state == .changed || state == .ended else { return false }
        return super.canPrevent(preventedGestureRecognizer)
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        if state == .began || state == .changed || state == .ended { return false }
        guard state == .possible, let trackedTouch else {
            return super.canBePrevented(by: preventingGestureRecognizer)
        }
        if preventingGestureRecognizer is UIScreenEdgePanGestureRecognizer { return true }
        if let scroll = preventingGestureRecognizer.view as? UIScrollView,
            preventingGestureRecognizer === scroll.panGestureRecognizer
        {
            // Match timeline arbitration: no scroll failure dependency. Inspect
            // the touch, since a scroll pan may reset its translation on begin.
            let point = trackedTouch.location(in: view)
            return abs(point.y - initialLocation.y) >= abs(point.x - initialLocation.x)
        }
        // Eager SwiftUI Button tracking must not kill an undecided horizontal
        // swipe. Stationary taps pass through when this recognizer fails on lift.
        return false
    }

    override func reset() {
        trackedTouch = nil
        initialLocation = .zero
        translation = .zero
        super.reset()
    }

    private func updateTranslation(_ touch: UITouch) {
        let point = touch.location(in: view)
        translation = CGPoint(x: point.x - initialLocation.x, y: point.y - initialLocation.y)
    }
}
#endif
