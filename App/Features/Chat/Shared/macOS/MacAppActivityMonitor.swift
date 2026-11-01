#if os(macOS)
    import AppKit
    import CoreGraphics
    import SwiftUI

    /// Native window eligibility and permission-free, system-wide computer idle time.
    @MainActor
    final class MacAppActivityMonitor: NSObject {
        private final class WindowState {
            weak var window: NSWindow?
            var isClosing = false
            var isMiniaturizing = false
            var isForeground = false
            var reportedForeground: Bool?

            init(window: NSWindow) {
                self.window = window
            }
        }

        private let onForegroundChanged: (UUID, Bool) -> Void
        private let onUserActivityChanged: (Bool) -> Void
        private let idleTime: () -> TimeInterval
        private let uptime: () -> TimeInterval
        private let workspaceNotifications: NotificationCenter
        private var windows: [UUID: WindowState] = [:]
        private weak var keyWindow: NSWindow?
        private var appIsActive: Bool
        private var appIsHidden: Bool
        private var sessionIsActive: Bool
        private var screensAreAwake: Bool
        private var computerIsAwake = true
        private var lastActivationAt: TimeInterval?
        private var userIsActive: Bool?
        private var timer: Timer?
        private var isStopped = false

        var isSamplingActivity: Bool { timer != nil }

        init(
            onForegroundChanged: @escaping (UUID, Bool) -> Void,
            onUserActivityChanged: @escaping (Bool) -> Void,
            idleTime: @escaping () -> TimeInterval = {
                CGEventSource.secondsSinceLastEventType(
                    .combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
            },
            uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        ) {
            self.onForegroundChanged = onForegroundChanged
            self.onUserActivityChanged = onUserActivityChanged
            self.idleTime = idleTime
            self.uptime = uptime
            workspaceNotifications = NSWorkspace.shared.notificationCenter
            appIsActive = NSApplication.shared.isActive
            appIsHidden = NSApplication.shared.isHidden
            keyWindow = NSApplication.shared.keyWindow
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            sessionIsActive = session?[kCGSessionOnConsoleKey as String] as? Bool ?? false
            screensAreAwake = CGDisplayIsAsleep(CGMainDisplayID()) == 0
            super.init()

            let notifications = NotificationCenter.default
            for name in [
                NSApplication.didBecomeActiveNotification,
                NSApplication.willResignActiveNotification,
                NSApplication.didResignActiveNotification,
                NSApplication.didHideNotification,
                NSApplication.didUnhideNotification,
            ] {
                notifications.addObserver(
                    self, selector: #selector(applicationChanged(_:)), name: name, object: nil)
            }
            for name in [
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.willMiniaturizeNotification, NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didExposeNotification, NSWindow.willCloseNotification,
            ] {
                notifications.addObserver(
                    self, selector: #selector(windowChanged(_:)), name: name, object: nil)
            }
            for name in [
                NSWorkspace.sessionDidBecomeActiveNotification,
                NSWorkspace.sessionDidResignActiveNotification,
                NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
            ] {
                workspaceNotifications.addObserver(
                    self, selector: #selector(workspaceChanged(_:)), name: name, object: nil)
            }
        }

        func attach(window: NSWindow, id: UUID) {
            guard !isStopped else { return }
            if windows[id]?.window === window { return }
            detach(id: id)
            windows[id] = WindowState(window: window)
            refreshForeground()
        }

        func detach(id: UUID) {
            guard let state = windows.removeValue(forKey: id) else { return }
            if state.reportedForeground == true { onForegroundChanged(id, false) }
            updateTimer()
        }

        /// Also callable directly with injected clocks to exercise the exact idle boundary.
        func sampleActivity() {
            guard !isStopped else { return }
            refreshForeground()
            guard windows.values.contains(where: { $0.isForeground }) else { return }
            let now = uptime()
            let sinceActivation = lastActivationAt.map { max(0, now - $0) } ?? .infinity
            let effectiveIdle = min(idleTime(), sinceActivation)
            publishUserActivity(effectiveIdle < 300)
        }

        /// Terminal teardown for the owner; a stopped monitor does not accept attachments.
        func stop() {
            guard !isStopped else { return }
            isStopped = true
            NotificationCenter.default.removeObserver(self)
            workspaceNotifications.removeObserver(self)
            timer?.invalidate()
            timer = nil
            for (id, state) in windows where state.reportedForeground == true {
                onForegroundChanged(id, false)
            }
            windows.removeAll()
        }

        @objc private func applicationChanged(_ notification: Notification) {
            switch notification.name {
            case NSApplication.didBecomeActiveNotification:
                appIsActive = true
            case NSApplication.willResignActiveNotification,
                NSApplication.didResignActiveNotification:
                appIsActive = false
            case NSApplication.didHideNotification:
                appIsHidden = true
            case NSApplication.didUnhideNotification:
                appIsHidden = false
            default:
                return
            }
            refreshForeground()
        }

        @objc private func workspaceChanged(_ notification: Notification) {
            switch notification.name {
            case NSWorkspace.sessionDidBecomeActiveNotification:
                sessionIsActive = true
            case NSWorkspace.sessionDidResignActiveNotification:
                sessionIsActive = false
            case NSWorkspace.screensDidSleepNotification:
                screensAreAwake = false
            case NSWorkspace.screensDidWakeNotification:
                screensAreAwake = true
            case NSWorkspace.willSleepNotification:
                computerIsAwake = false
            case NSWorkspace.didWakeNotification:
                computerIsAwake = true
            default:
                return
            }
            refreshForeground()
        }

        @objc private func windowChanged(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            var gainedKey = false
            if notification.name == NSWindow.didBecomeKeyNotification {
                gainedKey = keyWindow !== window
                keyWindow = window
            } else if notification.name == NSWindow.didResignKeyNotification, keyWindow === window {
                keyWindow = nil
            }
            var isRegistered = false
            for state in windows.values where state.window === window {
                isRegistered = true
                switch notification.name {
                case NSWindow.willCloseNotification:
                    // willClose arrives while isVisible and occlusionState may still say visible.
                    // Late expose/occlusion notifications must not resurrect a closing window.
                    state.isClosing = true
                case NSWindow.didBecomeKeyNotification:
                    // A closed WindowGroup may reuse its NSWindow without moving the marker.
                    // Only a real key gain can reopen it; late expose/occlusion cannot.
                    if gainedKey, window.isKeyWindow, window.isVisible {
                        state.isClosing = false
                    }
                case NSWindow.willMiniaturizeNotification, NSWindow.didMiniaturizeNotification:
                    state.isMiniaturizing = true
                case NSWindow.didDeminiaturizeNotification:
                    state.isMiniaturizing = false
                default:
                    break
                }
            }
            guard isRegistered || gainedKey else { return }
            refreshForeground(activationWindow: gainedKey ? window : nil)
        }

        private func refreshForeground(activationWindow: NSWindow? = nil) {
            guard !isStopped else { return }
            let appIsEligible =
                appIsActive && !appIsHidden && sessionIsActive && screensAreAwake && computerIsAwake
            var shouldActivate = false
            for state in windows.values {
                let eligible: Bool
                if let window = state.window {
                    eligible =
                        appIsEligible && !state.isClosing && !state.isMiniaturizing
                        && window.isVisible && !window.isMiniaturized
                        && window.occlusionState.contains(.visible)
                    if eligible
                        && (!state.isForeground || owns(window: activationWindow, root: window))
                    {
                        shouldActivate = true
                    }
                } else {
                    eligible = false
                }
                state.isForeground = eligible
            }
            if shouldActivate {
                // Opening/focusing is activity even when the last system input sample is old.
                // Only real eligibility/key gains refresh this epoch, never routine updates.
                lastActivationAt = uptime()
                publishUserActivity(true)
            }
            for (id, state) in windows where state.reportedForeground != state.isForeground {
                state.reportedForeground = state.isForeground
                onForegroundChanged(id, state.isForeground)
            }
            updateTimer()
        }

        private func owns(window: NSWindow?, root: NSWindow) -> Bool {
            var candidate = window
            while let current = candidate {
                if current === root { return true }
                candidate = current.sheetParent ?? current.parent
            }
            return false
        }

        private func publishUserActivity(_ active: Bool) {
            guard userIsActive != active else { return }
            userIsActive = active
            onUserActivityChanged(active)
        }

        private func updateTimer() {
            let shouldSample = !isStopped && windows.values.contains(where: { $0.isForeground })
            guard shouldSample else {
                timer?.invalidate()
                timer = nil
                return
            }
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sampleActivity() }
            }
            timer.tolerance = 0.1
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        deinit {
            timer?.invalidate()
            NotificationCenter.default.removeObserver(self)
            workspaceNotifications.removeObserver(self)
        }
    }

    // SwiftUI scenePhase cannot identify a native window's close/minimize/occlusion lifecycle,
    // nor distinguish multiple windows belonging to one scene. This inert AppKit view supplies
    // that identity without intercepting hit tests or installing an input/event monitor.
    struct MacActivityWindowMarker: NSViewRepresentable {
        let monitor: MacAppActivityMonitor
        let sceneID: UUID

        func makeNSView(context: Context) -> MarkerView {
            MarkerView(monitor: monitor, sceneID: sceneID)
        }

        func updateNSView(_ view: MarkerView, context: Context) {
            view.configure(monitor: monitor, sceneID: sceneID)
        }

        static func dismantleNSView(_ view: MarkerView, coordinator: ()) {
            view.disconnect()
        }

        final class MarkerView: NSView {
            private var monitor: MacAppActivityMonitor
            private var sceneID: UUID
            private weak var attachedWindow: NSWindow?

            init(monitor: MacAppActivityMonitor, sceneID: UUID) {
                self.monitor = monitor
                self.sceneID = sceneID
                super.init(frame: .zero)
            }

            required init?(coder: NSCoder) { nil }
            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                resolve()
            }

            func configure(monitor: MacAppActivityMonitor, sceneID: UUID) {
                if self.monitor !== monitor || self.sceneID != sceneID {
                    disconnect()
                    self.monitor = monitor
                    self.sceneID = sceneID
                }
                resolve()
            }

            func disconnect() {
                monitor.detach(id: sceneID)
                attachedWindow = nil
            }

            private func resolve() {
                guard attachedWindow !== window else { return }
                disconnect()
                guard let window else { return }
                attachedWindow = window
                monitor.attach(window: window, id: sceneID)
            }
        }
    }
#endif
