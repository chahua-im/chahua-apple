#if os(iOS)
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// SwiftUI's independent button, hold and drag gestures cannot irrevocably share
/// touch ownership or distinguish a finger from a pointer. One recognizer on the
/// row host does both; the SwiftUI markers below only supply geometry and actions.
@MainActor
final class MessageRowGestureCoordinator {
    private weak var view: UIView?
    private var markers: [ObjectIdentifier: Registration] = [:]
    private var nextOrder = 0
    private let recognizer = MessageRowTouchRecognizer(target: nil, action: nil)

    init(view: UIView) {
        self.view = view
        recognizer.coordinator = self
        view.addGestureRecognizer(recognizer)
    }

    /// The cell also calls this before reuse, replacement or detachment, since a
    /// hosting controller can outlive the message represented by its root view.
    func cancel() {
        recognizer.cancelSession()
    }

    fileprivate func register(_ marker: MessageRowGestureMarker) {
        let id = ObjectIdentifier(marker)
        guard markers[id] == nil else { return }
        if case .row = marker.role { cancel() }
        nextOrder += 1
        markers[id] = Registration(marker: marker, order: nextOrder)
    }

    fileprivate func unregister(_ marker: MessageRowGestureMarker) {
        let id = ObjectIdentifier(marker)
        markers.removeValue(forKey: id)
        if recognizer.session?.references(id) == true { cancel() }
    }

    fileprivate func disabled(_ marker: MessageRowGestureMarker) {
        if recognizer.session?.references(ObjectIdentifier(marker)) == true { cancel() }
    }

    fileprivate func capture(touch: UITouch, event: UIEvent) -> MessageRowTouchSession? {
        guard let view, view.window != nil, !nativeTextOwnsTouch(touch, in: view) else { return nil }
        let input: MessageRowTouchSession.Input
        switch touch.type {
        case .direct:
            input = .finger
        case .indirectPointer:
            if event.buttonMask.contains(.secondary) {
                input = .secondaryPointer
            } else if event.buttonMask.contains(.primary) {
                input = .primaryPointer
            } else {
                return nil
            }
        default:
            return nil
        }

        let point = touch.location(in: view)
        var row: (id: ObjectIdentifier, configuration: MessageRowSwipeConfiguration, order: Int)?
        var bubble: (id: ObjectIdentifier, rect: CGRect, open: (CGRect) -> Void, order: Int)?
        var tap: (id: ObjectIdentifier, rect: CGRect, action: () -> Void, order: Int)?
        for (id, registration) in markers {
            guard let marker = registration.marker, let rect = marker.region(containing: point, in: view) else { continue }
            switch marker.role {
            case .row(let configuration):
                if row == nil || registration.order > row!.order {
                    row = (id, configuration, registration.order)
                }
            case .bubble(let open):
                if bubble == nil || prefers(rect, order: registration.order, over: bubble!.rect, order: bubble!.order) {
                    bubble = (id, rect, open, registration.order)
                }
            case .tap(let action):
                if let action, tap == nil || prefers(rect, order: registration.order, over: tap!.rect, order: tap!.order) {
                    tap = (id, rect, action, registration.order)
                }
            case nil:
                break
            }
        }
        // A disabled reply action still registers a row: read-only conversations
        // retain bubble menus and navigation through quote/media/reaction targets.
        guard let row else { return nil }
        switch input {
        case .finger:
            guard row.configuration.isEnabled || bubble != nil || tap != nil else { return nil }
        case .primaryPointer:
            guard tap != nil else { return nil }
        case .secondaryPointer:
            guard bubble != nil else { return nil }
        }
        return MessageRowTouchSession(
            touch: touch, input: input, origin: point, rowID: row.id, swipe: row.configuration,
            bubbleID: bubble?.id, bubbleRect: bubble?.rect, open: bubble?.open,
            tapID: tap?.id, tapRect: tap?.rect, action: tap?.action
        )
    }

    fileprivate func nativeTextOwnsTouch(_ touch: UITouch, in root: UIView) -> Bool {
        var ancestor = touch.view
        while let current = ancestor {
            if current is UITextField { return true }
            if current === root { break }
            ancestor = current.superview
        }
        // Selection handles need not be descendants of the UITextView itself.
        // Yield the entire row while it contains an editable/selected text view,
        // using public text state rather than UIKit's private handle class names.
        return containsNativeTextOwnership(root)
    }

    fileprivate func canContinue(_ session: MessageRowTouchSession) -> Bool {
        guard let view, view.window != nil, markers[session.rowID]?.marker != nil else { return false }
        return !nativeTextOwnsTouch(session.touch, in: view)
    }

    fileprivate func windowRect(for rect: CGRect) -> CGRect? {
        guard let view, let window = view.window else { return nil }
        return view.convert(rect, to: window)
    }

    private func containsNativeTextOwnership(_ view: UIView) -> Bool {
        if let text = view as? UITextView, text.isEditable || text.selectedRange.length > 0 { return true }
        for child in view.subviews where !child.isHidden && child.alpha > 0 {
            if containsNativeTextOwnership(child) { return true }
        }
        return false
    }

    private func prefers(_ rect: CGRect, order: Int, over other: CGRect, order otherOrder: Int) -> Bool {
        let area = rect.width * rect.height
        let otherArea = other.width * other.height
        return area < otherArea || (area == otherArea && order > otherOrder)
    }

    private struct Registration {
        weak var marker: MessageRowGestureMarker?
        let order: Int
    }
}

struct MessageRowGestureSource: UIViewRepresentable {
    let isEnabled: Bool
    let onChange: (CGFloat) -> Void
    let onFinish: () -> Void
    let onReply: () -> Void

    func makeUIView(context: Context) -> MessageRowGestureMarker { MessageRowGestureMarker() }

    func updateUIView(_ view: MessageRowGestureMarker, context: Context) {
        view.configure(.row(.init(isEnabled: isEnabled, onChange: onChange, onFinish: onFinish, onReply: onReply)))
    }

    static func dismantleUIView(_ view: MessageRowGestureMarker, coordinator: ()) { view.stop() }
}

struct MessageBubbleHoldSource: UIViewRepresentable {
    let open: (CGRect) -> Void

    func makeUIView(context: Context) -> MessageRowGestureMarker { MessageRowGestureMarker() }
    func updateUIView(_ view: MessageRowGestureMarker, context: Context) { view.configure(.bubble(open)) }
    static func dismantleUIView(_ view: MessageRowGestureMarker, coordinator: ()) { view.stop() }
}

struct MessageRowTapSource: UIViewRepresentable {
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeUIView(context: Context) -> MessageRowGestureMarker { MessageRowGestureMarker() }
    func updateUIView(_ view: MessageRowGestureMarker, context: Context) { view.configure(.tap(isEnabled ? action : nil)) }
    static func dismantleUIView(_ view: MessageRowGestureMarker, coordinator: ()) { view.stop() }
}

final class MessageRowGestureMarker: UIView {
    fileprivate enum Role {
        case row(MessageRowSwipeConfiguration)
        case bubble((CGRect) -> Void)
        case tap((() -> Void)?)
    }

    fileprivate private(set) var role: Role?
    private weak var coordinator: MessageRowGestureCoordinator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshRegistration()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        refreshRegistration()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshRegistration()
    }

    fileprivate func configure(_ role: Role) {
        let previous = self.role
        self.role = role
        refreshRegistration()
        switch (previous, role) {
        case (.row(let old), .row(let new)) where old.isEnabled && !new.isEnabled:
            coordinator?.disabled(self)
        case (.tap(.some), .tap(nil)):
            coordinator?.disabled(self)
        default:
            break
        }
    }

    fileprivate func stop() {
        role = nil
        detach()
    }

    fileprivate func region(containing point: CGPoint, in host: UIView) -> CGRect? {
        guard role != nil, window != nil, isDescendant(of: host), bounds.contains(convert(point, from: host)) else { return nil }
        var ancestor: UIView? = self
        while let current = ancestor {
            guard !current.isHidden, current.alpha > 0 else { return nil }
            if current.clipsToBounds && !current.bounds.contains(current.convert(point, from: host)) { return nil }
            if current === host { return convert(bounds, to: host) }
            ancestor = current.superview
        }
        return nil
    }

    private func refreshRegistration() {
        guard role != nil, window != nil else {
            detach()
            return
        }
        var responder: UIResponder? = self
        var owner: TimelineBubbleHostingController?
        while let current = responder {
            if let host = current as? TimelineBubbleHostingController {
                owner = host
                break
            }
            responder = current.next
        }
        let next = owner?.rowGestures
        guard coordinator !== next else { return }
        detach()
        coordinator = next
        next?.register(self)
    }

    private func detach() {
        let previous = coordinator
        coordinator = nil
        previous?.unregister(self)
    }
}

fileprivate struct MessageRowSwipeConfiguration {
    let isEnabled: Bool
    let onChange: (CGFloat) -> Void
    let onFinish: () -> Void
    let onReply: () -> Void
}

fileprivate final class MessageRowTouchSession {
    enum Input { case finger, primaryPointer, secondaryPointer }
    enum Owner { case undecided, swipe, contextMenu, tap, scroll, native, cancelled }

    let touch: UITouch
    let input: Input
    let origin: CGPoint
    let rowID: ObjectIdentifier
    let swipe: MessageRowSwipeConfiguration
    let bubbleID: ObjectIdentifier?
    let bubbleRect: CGRect?
    let open: ((CGRect) -> Void)?
    let tapID: ObjectIdentifier?
    let tapRect: CGRect?
    let action: (() -> Void)?
    var owner = Owner.undecided
    var displacement: CGFloat = 0
    var deliveredContext = false

    init(
        touch: UITouch, input: Input, origin: CGPoint, rowID: ObjectIdentifier, swipe: MessageRowSwipeConfiguration,
        bubbleID: ObjectIdentifier?, bubbleRect: CGRect?, open: ((CGRect) -> Void)?,
        tapID: ObjectIdentifier?, tapRect: CGRect?, action: (() -> Void)?
    ) {
        self.touch = touch
        self.input = input
        self.origin = origin
        self.rowID = rowID
        self.swipe = swipe
        self.bubbleID = bubbleID
        self.bubbleRect = bubbleRect
        self.open = open
        self.tapID = tapID
        self.tapRect = tapRect
        self.action = action
    }

    func references(_ id: ObjectIdentifier) -> Bool { rowID == id || bubbleID == id || tapID == id }
}

fileprivate final class MessageRowTouchRecognizer: UIGestureRecognizer {
    weak var coordinator: MessageRowGestureCoordinator?
    private(set) var session: MessageRowTouchSession?
    private var holdTimer: Timer?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        addTarget(self, action: #selector(deliverRecognition))
        allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
        requiresExclusiveTouchType = true
        cancelsTouchesInView = true
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard session == nil, touches.count == 1, let touch = touches.first,
            let captured = coordinator?.capture(touch: touch, event: event)
        else {
            cancelSession()
            return
        }
        session = captured
        guard captured.input == .finger, captured.open != nil else { return }
        let timer = Timer(timeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.holdDeadline() }
        }
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let session, touches.contains(session.touch) else { return }
        move(to: session.touch.location(in: view))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let captured = session, touches.contains(captured.touch) else { return }
        let point = captured.touch.location(in: view)
        // Release position is authoritative even if UIKit omitted a final move:
        // crossing then retreating below 60 must never send a reply.
        move(to: point)
        guard session === captured else { return }
        invalidateHold()
        switch captured.owner {
        case .swipe, .contextMenu:
            state = .ended
        case .undecided:
            if captured.input == .secondaryPointer, let rect = captured.bubbleRect, rect.contains(point), captured.open != nil {
                captured.owner = .contextMenu
                state = .recognized
            } else if captured.input != .secondaryPointer, let rect = captured.tapRect, rect.contains(point), captured.action != nil {
                captured.owner = .tap
                state = .recognized
            } else {
                // A stationary, unregistered text/control tap is not a row
                // gesture. Failing without delaying delivery preserves native
                // links, double-tap selection and the pending-message retry UI.
                abandon(.native)
            }
        case .tap, .scroll, .native, .cancelled:
            break
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        cancelSession()
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let session else { return super.canPrevent(preventedGestureRecognizer) }
        switch session.owner {
        case .swipe, .contextMenu, .tap:
            return super.canPrevent(preventedGestureRecognizer)
        default:
            return false
        }
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        if state == .began || state == .changed || state == .ended { return false }
        guard let session else { return super.canBePrevented(by: preventingGestureRecognizer) }
        switch session.owner {
        case .undecided:
            if let scroll = preventingGestureRecognizer.view as? UIScrollView,
                preventingGestureRecognizer === scroll.panGestureRecognizer
            {
                let point = session.touch.location(in: view)
                let dx = point.x - session.origin.x
                let dy = point.y - session.origin.y
                // No failure dependency or simultaneous-recognition blanket:
                // native scrolling may win immediately on vertical movement.
                // Horizontal pans must wait for this row's >5pt intent decision.
                // Use the touch itself: UIScrollView may reset its pan's
                // translation when beginning, before this recognizer is called.
                return abs(dy) >= abs(dx)
            }
            // Eager SwiftUI/native button tracking must not kill an undecided
            // swipe. Native stationary text gestures still finish when this
            // recognizer fails on release; active selection is excluded above.
            return false
        case .swipe, .contextMenu, .tap:
            return false
        default:
            return super.canBePrevented(by: preventingGestureRecognizer)
        }
    }

    override func reset() {
        let interrupted = session
        session = nil
        invalidateHold()
        super.reset()
        if interrupted?.owner == .swipe { interrupted?.swipe.onFinish() }
    }

    func cancelSession() {
        abandon(.cancelled)
    }

    /// UIKit delivers actions after it has resolved recognition and cancelled
    /// native tracking. Calling row actions directly from touchesEnded would run
    /// them before that arbitration, or even after another recognizer won.
    @objc private func deliverRecognition() {
        guard let captured = session else { return }
        switch state {
        case .began, .changed:
            if captured.owner == .swipe {
                captured.swipe.onChange(captured.displacement)
            } else if captured.owner == .contextMenu {
                deliverContext(captured)
            }
        case .ended:
            session = nil
            invalidateHold()
            switch captured.owner {
            case .swipe:
                let reply = captured.displacement >= 60 ? captured.swipe.onReply : nil
                captured.swipe.onFinish()
                reply?()
            case .contextMenu:
                deliverContext(captured)
            case .tap:
                captured.action?()
            default:
                break
            }
        case .cancelled, .failed:
            abandon(.cancelled)
        default:
            break
        }
    }

    private func deliverContext(_ captured: MessageRowTouchSession) {
        guard !captured.deliveredContext, let rect = captured.bubbleRect,
            let windowRect = coordinator?.windowRect(for: rect)
        else { return }
        captured.deliveredContext = true
        captured.open?(windowRect)
    }

    private func move(to point: CGPoint) {
        guard let captured = session else { return }
        if captured.owner == .undecided {
            guard coordinator?.canContinue(captured) == true else {
                abandon(.native)
                return
            }
            let dx = point.x - captured.origin.x
            let dy = point.y - captured.origin.y
            guard abs(dx) > 5 || abs(dy) > 5 else { return }
            invalidateHold()
            guard abs(dx) > abs(dy) else {
                abandon(.scroll)
                return
            }
            guard captured.input == .finger, captured.swipe.isEnabled else {
                abandon(.cancelled)
                return
            }
            // Lock even a rightward drag at zero displacement: retreating or
            // pausing can never resurrect this touch's tap/hold eligibility.
            captured.owner = .swipe
            captured.displacement = min(max(-dx, 0), 80)
            state = .began
        } else if captured.owner == .swipe {
            captured.displacement = min(max(captured.origin.x - point.x, 0), 80)
            state = .changed
        } else {
            return
        }
    }

    private func holdDeadline() {
        invalidateHold()
        guard state == .possible, let captured = session, captured.owner == .undecided,
            captured.input == .finger
        else { return }
        let point = captured.touch.location(in: view)
        move(to: point)
        guard session === captured, captured.owner == .undecided,
            let rect = captured.bubbleRect, rect.contains(point), captured.open != nil
        else { return }
        captured.owner = .contextMenu
        state = .began
    }

    private func abandon(_ owner: MessageRowTouchSession.Owner) {
        let interrupted = session
        let wasSwiping = interrupted?.owner == .swipe
        interrupted?.owner = owner
        session = nil
        invalidateHold()
        if state == .began || state == .changed {
            state = .cancelled
        } else if state == .possible {
            state = .failed
        }
        if wasSwiping { interrupted?.swipe.onFinish() }
    }

    private func invalidateHold() {
        holdTimer?.invalidate()
        holdTimer = nil
    }
}
#endif
