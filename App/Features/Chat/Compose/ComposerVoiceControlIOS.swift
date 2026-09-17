#if os(iOS)
import SwiftUI
import UIKit

// The requested iOS hold/drag interaction deliberately differs from the macOS
// click control. SwiftUI DragGesture has no cancellation callback, so a small
// UIKit touch surface handles cancellation and tracks a single touch in window
// coordinates. SwiftUI still owns the visuals and accessibility actions.
struct ComposerVoiceControlIOS: View {
    @ObservedObject var recorder: ComposerVoiceRecorder
    let isEnabled: Bool
    let canStart: Bool
    let onStart: (Bool) -> Bool
    let onSendVoice: ((URL) async -> Bool)?
    @Environment(\.scenePhase) private var scenePhase
    @State private var holdOrigin: CGPoint?
    @State private var target = HoldTarget.preview

    private enum HoldTarget: Equatable {
        case preview, lock, send
    }

    private static let targetOffset: CGFloat = 64
    private var isHolding: Bool { holdOrigin != nil }
    private var action: ComposerVoiceTouchAction {
        guard scenePhase == .active else { return .disabled }
        switch recorder.phase {
        case .idle: return canStart ? .hold : .disabled
        case .requestingPermission, .recording: return isEnabled ? .stop : .disabled
        case .preview: return isEnabled && onSendVoice != nil ? .send : .disabled
        case .sending: return .disabled
        }
    }

    private var label: LocalizedStringKey {
        switch recorder.phase {
        case .idle: "Record voice message"
        case .requestingPermission, .recording: "Stop recording"
        case .preview: "Send voice message"
        case .sending: "Sending voice message…"
        }
    }

    private var hint: LocalizedStringKey {
        switch recorder.phase {
        case .idle: "Hold to record. Release to preview, slide up to send, or slide left to lock."
        case .requestingPermission, .recording: "Double-tap to stop and preview."
        case .preview: "Double-tap to send the voice message."
        case .sending: "Sending voice message…"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .global)
            controlFace
                .opacity(isHolding ? 0 : 1)
                .overlay {
                    if let holdOrigin {
                        // Keyboard dismissal and the live panel can move the
                        // composer. Keep the targets pinned to touch-down, while
                        // the transparent touch surface retains the same identity.
                        holdTargets
                            .offset(x: holdOrigin.x - frame.midX, y: holdOrigin.y - frame.midY)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .overlay {
                    ComposerVoiceTouchSurface(
                        action: action,
                        onBegan: { beginHold(at: CGPoint(x: frame.midX, y: frame.midY)) },
                        onMoved: updateHold,
                        onEnded: finishHold,
                        onCancelled: cancelHold,
                        onActivate: activate
                    )
                    .accessibilityHidden(true)
                }
        }
        .frame(width: 44, height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityHint(Text(hint))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { activate(action) }
        .disabled(action == .disabled)
        .sensoryFeedback(.selection, trigger: target)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelHold() }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { cancelHold() }
        }
        .onChange(of: recorder.phase) { _, phase in
            if phase != .recording && phase != .requestingPermission { resetHold() }
        }
        .onDisappear { cancelHold() }
    }

    private var controlFace: some View {
        // A real container preserves the touch overlay across phase changes.
        // Group distributes that overlay into each switch branch, dismantling
        // the held touch surface (and cancelling recording) when the icon changes.
        ZStack {
            switch recorder.phase {
            case .idle:
                Image(systemName: "mic")
            case .requestingPermission, .sending:
                ProgressView().controlSize(.small)
            case .recording:
                Image(systemName: "stop.fill")
            case .preview:
                Image(systemName: "paperplane.fill")
            }
        }
        .font(.system(size: 20))
        .foregroundStyle(action != .disabled ? ChahuaTheme.accent : .secondary)
        .frame(width: 44, height: 44)
        .modifier(ChatGlassSurface(cornerRadius: 22, isInteractive: action != .disabled))
    }

    private var holdTargets: some View {
        ZStack {
            targetCircle(.send, symbol: "arrow.up")
                .overlay(alignment: .trailing) {
                    if target == .send {
                        targetCaption("Release to send")
                            .offset(x: -52)
                    }
                }
                .offset(y: -Self.targetOffset)
            targetCircle(.lock, symbol: "lock.fill")
                .overlay(alignment: .topTrailing) {
                    if target == .lock {
                        targetCaption("Release to lock")
                            .offset(y: -32)
                    }
                }
                .offset(x: -Self.targetOffset)
            targetCircle(.preview, symbol: "mic.fill")
                .overlay(alignment: .topTrailing) {
                    if target == .preview {
                        targetCaption("Release to preview")
                            .offset(y: -Self.targetOffset - 52)
                    }
                }
        }
        .frame(width: 44, height: 44)
    }

    private func targetCircle(_ value: HoldTarget, symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(target == value ? Color.white : ChahuaTheme.accent)
            .frame(width: 44, height: 44)
            .background {
                Circle().fill(.regularMaterial)
                Circle().fill(target == value ? ChahuaTheme.accent : .clear)
            }
            .overlay { Circle().strokeBorder(ChahuaTheme.accent.opacity(0.5), lineWidth: 1) }
            .scaleEffect(target == value ? 1.1 : 1)
            .animation(.easeOut(duration: 0.12), value: target)
    }

    private func targetCaption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }

    private func beginHold(at origin: CGPoint) -> Bool {
        guard action == .hold else { return false }
        target = .preview
        holdOrigin = origin
        guard onStart(true) else {
            resetHold()
            return false
        }
        return true
    }

    private func target(for translation: CGSize) -> HoldTarget {
        let left = -translation.width
        let up = -translation.height
        let midpoint = Self.targetOffset / 2
        guard left >= midpoint || up >= midpoint else { return .preview }
        // Match the PWA's midpoint/dominant-axis targets, with LEFT = LOCK.
        return left >= midpoint && left >= up ? .lock : .send
    }

    private func updateHold(_ translation: CGSize) {
        guard isHolding else { return }
        target = target(for: translation)
    }

    private func finishHold(_ translation: CGSize) {
        guard isHolding else { return }
        guard isEnabled, scenePhase == .active, !recorder.isLocked,
              recorder.phase == .recording || recorder.phase == .requestingPermission,
              let onSendVoice else {
            cancelHold()
            return
        }
        let selection = target(for: translation)
        resetHold()
        switch selection {
        case .preview: recorder.finishHold(.preview, using: onSendVoice)
        case .lock: recorder.finishHold(.lock, using: onSendVoice)
        case .send: recorder.finishHold(.send, using: onSendVoice)
        }
    }

    private func cancelHold() {
        guard isHolding else { return }
        resetHold()
        // Cancellation is never a send or a lock. Preserve a usable preview,
        // and invalidate pending permission so it cannot start capture later.
        if !recorder.isLocked { recorder.stop() }
    }

    private func resetHold() {
        holdOrigin = nil
        target = .preview
    }

    private func activate(_ touchAction: ComposerVoiceTouchAction) {
        guard isEnabled, scenePhase == .active else { return }
        switch touchAction {
        case .hold:
            // VoiceOver activation starts a locked recording without a held touch.
            if canStart { _ = onStart(false) }
        case .stop:
            if recorder.phase == .recording || recorder.phase == .requestingPermission {
                recorder.stop()
            }
        case .send:
            if recorder.phase == .preview, let onSendVoice { recorder.send(using: onSendVoice) }
        case .disabled:
            break
        }
    }
}

private enum ComposerVoiceTouchAction {
    case disabled, hold, stop, send
}

private struct ComposerVoiceTouchSurface: UIViewRepresentable {
    let action: ComposerVoiceTouchAction
    let onBegan: () -> Bool
    let onMoved: (CGSize) -> Void
    let onEnded: (CGSize) -> Void
    let onCancelled: () -> Void
    let onActivate: (ComposerVoiceTouchAction) -> Void

    func makeUIView(context: Context) -> TouchView { TouchView() }

    func updateUIView(_ view: TouchView, context: Context) {
        view.action = action
        view.onBegan = onBegan
        view.onMoved = onMoved
        view.onEnded = onEnded
        view.onCancelled = onCancelled
        view.onActivate = onActivate
    }

    static func dismantleUIView(_ view: TouchView, coordinator: ()) {
        view.cancelTracking()
    }

    final class TouchView: UIView {
        var action = ComposerVoiceTouchAction.disabled
        var onBegan: (() -> Bool)?
        var onMoved: ((CGSize) -> Void)?
        var onEnded: ((CGSize) -> Void)?
        var onCancelled: (() -> Void)?
        var onActivate: ((ComposerVoiceTouchAction) -> Void)?
        private var trackedTouch: UITouch?
        private var trackedAction = ComposerVoiceTouchAction.disabled
        private var origin = CGPoint.zero

        init() {
            super.init(frame: .zero)
            backgroundColor = .clear
            isMultipleTouchEnabled = false
            isExclusiveTouch = true
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { nil }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard trackedTouch == nil, action != .disabled,
                  let touch = touches.first, let window else { return }
            trackedTouch = touch
            trackedAction = action
            origin = touch.location(in: window)
            if trackedAction == .hold, onBegan?() != true { clearTracking() }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = trackedTouch, touches.contains(touch), trackedAction == .hold else { return }
            onMoved?(translation(of: touch))
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = trackedTouch, touches.contains(touch) else { return }
            let completedAction = trackedAction
            let delta = translation(of: touch)
            let activates = bounds.contains(touch.location(in: self))
            clearTracking()
            if completedAction == .hold {
                onEnded?(delta)
            } else if activates {
                // Use the action captured at touch-down: a recording stopping
                // during a press must never reinterpret that release as Send.
                onActivate?(completedAction)
            }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            cancelTracking()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { cancelTracking() }
        }

        func cancelTracking() {
            let wasHolding = trackedAction == .hold
            clearTracking()
            if wasHolding { onCancelled?() }
        }

        private func clearTracking() {
            trackedTouch = nil
            trackedAction = .disabled
        }

        private func translation(of touch: UITouch) -> CGSize {
            let point = touch.location(in: window)
            return CGSize(width: point.x - origin.x, height: point.y - origin.y)
        }
    }
}
#endif
