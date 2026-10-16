import Foundation
import QuartzCore

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// One replaceable transaction per display tick. The display link never owns its client.
@MainActor
final class TimelineDisplayScheduler {
    enum TickSource {
        /// Production: tick with the view's display.
        case display
        /// Tick from a main run-loop timer at display cadence. An AppKit display link never ticks
        /// for a window without an active display (e.g. headless CI runners), so host tests select
        /// this before creating timeline controllers.
        case runLoop
    }

    /// Read when a scheduler is created; existing schedulers keep their source.
    static var tickSource = TickSource.display

    @MainActor
    private final class Target: NSObject {
        weak var owner: TimelineDisplayScheduler?
        @objc func tick(_ link: CADisplayLink) { owner?.flush() }
        @objc func fire(_ timer: Timer) { owner?.flush() }
    }

    private let target = Target()
    private let usesRunLoop = TimelineDisplayScheduler.tickSource == .runLoop
    private var link: CADisplayLink?
    private var timer: Timer?
    private var pending: (@MainActor () -> Void)?

    #if os(macOS)
        init(view: NSView) {
            target.owner = self
            guard !usesRunLoop else { return }
            link = view.displayLink(target: target, selector: #selector(Target.tick(_:)))
            link?.isPaused = true
            link?.add(to: .main, forMode: .common)
        }
    #else
        init(view: UIView) {
            target.owner = self
            guard !usesRunLoop else { return }
            link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
            link?.isPaused = true
            link?.add(to: .main, forMode: .common)
        }
    #endif

    func request(_ action: @escaping @MainActor () -> Void) {
        pending = action
        guard usesRunLoop else {
            link?.isPaused = false
            return
        }
        guard timer == nil else { return }
        let timer = Timer(
            timeInterval: 1.0 / 60, target: target, selector: #selector(Target.fire(_:)),
            userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func flush() {
        let action = pending
        pending = nil
        pause()
        action?()
    }

    func cancel() {
        pending = nil
        pause()
    }

    private func pause() {
        link?.isPaused = true
        timer?.invalidate()
        timer = nil
    }

    deinit {
        link?.invalidate()
        timer?.invalidate()
    }
}
