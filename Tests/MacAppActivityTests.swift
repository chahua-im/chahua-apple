#if os(macOS)
    import AppKit
    import XCTest
    @testable import chahua_apple

    @MainActor
    final class MacAppActivityTests: XCTestCase {
        func testIdleBoundaryInputResumptionAndIdempotentAttach() async throws {
            let window = try await makeVisibleWindow()
            let id = UUID()
            var now: TimeInterval = 1000
            var idle: TimeInterval = 5000
            var foreground: [UUID: Bool] = [:]
            var activity: [Bool] = []
            let monitor = MacAppActivityMonitor(
                onForegroundChanged: { foreground[$0] = $1 },
                onUserActivityChanged: { activity.append($0) },
                idleTime: { idle }, uptime: { now })
            defer {
                monitor.stop()
                window.close()
            }
            monitor.attach(window: window, id: id)
            XCTAssertEqual(foreground[id], true)
            XCTAssertEqual(activity, [true])
            XCTAssertTrue(monitor.isSamplingActivity)

            now = 1299.999
            monitor.sampleActivity()
            XCTAssertEqual(activity, [true])
            // Re-rendering the same bridge must not give an idle computer another five minutes.
            monitor.attach(window: window, id: id)
            now = 1300
            monitor.sampleActivity()
            XCTAssertEqual(activity, [true, false])
            XCTAssertEqual(foreground[id], true, "Idle does not change native window eligibility")
            monitor.sampleActivity()
            XCTAssertEqual(activity, [true, false])

            idle = 0.25
            monitor.sampleActivity()
            XCTAssertEqual(activity, [true, false, true])
            now = 1600
            idle = 300
            monitor.sampleActivity()
            XCTAssertEqual(activity, [true, false, true, false])
        }

        func testChildWindowFocusOverridesOldIdleWithoutRoutineNotificationResets() async throws {
            let root = try await makeVisibleWindow()
            defer { root.close() }
            let child = try await makeVisibleWindow(x: 340)
            root.addChildWindow(child, ordered: .above)
            root.makeKeyAndOrderFront(nil)
            let id = UUID()
            var now: TimeInterval = 0
            var activity: [Bool] = []
            let monitor = MacAppActivityMonitor(
                onForegroundChanged: { _, _ in },
                onUserActivityChanged: { activity.append($0) },
                idleTime: { 5000 }, uptime: { now })
            defer {
                monitor.stop()
                root.removeChildWindow(child)
                child.close()
            }
            monitor.attach(window: root, id: id)
            now = 300
            monitor.sampleActivity()
            XCTAssertEqual(activity, [true, false])
            NotificationCenter.default.post(
                name: NSWindow.didChangeOcclusionStateNotification, object: root)
            NotificationCenter.default.post(
                name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
            XCTAssertEqual(activity, [true, false])

            now = 400
            child.makeKeyAndOrderFront(nil)
            XCTAssertTrue(child.isKeyWindow)
            XCTAssertEqual(
                activity, [true, false, true], "A native child owns its root scene's focus")
            monitor.sampleActivity()
            XCTAssertEqual(activity.last, true, "An old OS idle sample must not undo focusing")
            now = 699.999
            monitor.sampleActivity()
            XCTAssertEqual(activity.last, true)
            now = 700
            monitor.sampleActivity()
            XCTAssertEqual(activity.last, false)
            let count = activity.count
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: child)
            NotificationCenter.default.post(name: NSWindow.didExposeNotification, object: root)
            monitor.sampleActivity()
            XCTAssertEqual(
                activity.count, count, "Duplicate key/expose notifications are not activity")
        }

        func testReopeningClosedNativeWindowRestoresForegroundActivity() async throws {
            let window = try await makeVisibleWindow()
            var foreground = false
            var now: TimeInterval = 0
            var active = false
            let monitor = MacAppActivityMonitor(
                onForegroundChanged: { _, value in foreground = value },
                onUserActivityChanged: { active = $0 },
                idleTime: { 5000 }, uptime: { now })
            defer {
                monitor.stop()
                window.close()
            }
            monitor.attach(window: window, id: UUID())
            now = 300
            monitor.sampleActivity()
            XCTAssertFalse(active)
            window.close()
            XCTAssertFalse(foreground)
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<50 {
                if foreground { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(foreground)
            XCTAssertTrue(active, "Reopening must override the old computer-idle sample")
            XCTAssertTrue(monitor.isSamplingActivity)
        }

        func testWillCloseCannotResurrectWindowOrDeactivateAnotherWindow() async throws {
            let first = try await makeVisibleWindow()
            defer { first.close() }
            let second = try await makeVisibleWindow(x: 340)
            let firstID = UUID()
            let secondID = UUID()
            var now: TimeInterval = 0
            var idleReads = 0
            var foreground: [UUID: Bool] = [:]
            var activity: [Bool] = []
            let monitor = MacAppActivityMonitor(
                onForegroundChanged: { foreground[$0] = $1 },
                onUserActivityChanged: { activity.append($0) },
                idleTime: {
                    idleReads += 1
                    return 5000
                }, uptime: { now })
            defer {
                monitor.stop()
                second.close()
            }
            monitor.attach(window: first, id: firstID)
            monitor.attach(window: second, id: secondID)
            XCTAssertEqual(foreground[firstID], true)
            XCTAssertEqual(foreground[secondID], true)
            now = 300
            monitor.sampleActivity()
            XCTAssertEqual(activity.last, false)

            // Exercise AppKit's pre-change timing using an actual, still-visible native window.
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: first)
            XCTAssertTrue(first.isVisible)
            XCTAssertEqual(foreground[firstID], false)
            XCTAssertEqual(foreground[secondID], true)
            XCTAssertTrue(monitor.isSamplingActivity)
            NotificationCenter.default.post(name: NSWindow.didExposeNotification, object: first)
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: first)
            monitor.sampleActivity()
            XCTAssertEqual(foreground[firstID], false)
            XCTAssertEqual(foreground[secondID], true)
            XCTAssertEqual(activity.last, false)
            monitor.detach(id: firstID)
            first.close()
            XCTAssertEqual(foreground[secondID], true)

            second.orderOut(nil)
            monitor.sampleActivity()
            XCTAssertEqual(foreground[secondID], false)
            XCTAssertFalse(monitor.isSamplingActivity)
            let readsBefore = idleReads
            NotificationCenter.default.post(name: NSWindow.didExposeNotification, object: second)
            monitor.sampleActivity()
            XCTAssertEqual(foreground[secondID], false)
            XCTAssertEqual(idleReads, readsBefore, "Ineligible windows must not poll system idle")
        }

        func testWorkspaceAndApplicationIneligibilityStopsPollingImmediately() async throws {
            let window = try await makeVisibleWindow()
            let id = UUID()
            var now: TimeInterval = 0
            var idleReads = 0
            var foreground: [UUID: Bool] = [:]
            var activity: [Bool] = []
            let monitor = MacAppActivityMonitor(
                onForegroundChanged: { foreground[$0] = $1 },
                onUserActivityChanged: { activity.append($0) },
                idleTime: {
                    idleReads += 1
                    return 5000
                }, uptime: { now })
            defer {
                monitor.stop()
                window.close()
            }
            monitor.attach(window: window, id: id)
            let workspace = NSWorkspace.shared.notificationCenter
            let transitions: [(Notification.Name, Notification.Name)] = [
                (
                    NSWorkspace.sessionDidResignActiveNotification,
                    NSWorkspace.sessionDidBecomeActiveNotification
                ),
                (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
                (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
            ]
            for (loss, gain) in transitions {
                now += 300
                monitor.sampleActivity()
                XCTAssertEqual(activity.last, false)
                workspace.post(name: loss, object: NSWorkspace.shared)
                XCTAssertEqual(foreground[id], false)
                XCTAssertFalse(monitor.isSamplingActivity)
                let readsBefore = idleReads
                NotificationCenter.default.post(
                    name: NSWindow.didExposeNotification, object: window)
                monitor.sampleActivity()
                XCTAssertEqual(foreground[id], false)
                XCTAssertEqual(idleReads, readsBefore)
                workspace.post(name: gain, object: NSWorkspace.shared)
                XCTAssertEqual(foreground[id], true)
                XCTAssertEqual(activity.last, true)
                XCTAssertTrue(monitor.isSamplingActivity)
                monitor.sampleActivity()
                XCTAssertEqual(activity.last, true)
            }

            let notifications = NotificationCenter.default
            for (loss, gain) in [
                (
                    NSApplication.willResignActiveNotification,
                    NSApplication.didBecomeActiveNotification
                ),
                (NSApplication.didHideNotification, NSApplication.didUnhideNotification),
                (NSWindow.willMiniaturizeNotification, NSWindow.didDeminiaturizeNotification),
            ] {
                let object: Any =
                    loss == NSWindow.willMiniaturizeNotification ? window : NSApplication.shared
                notifications.post(name: loss, object: object)
                XCTAssertEqual(foreground[id], false)
                XCTAssertFalse(monitor.isSamplingActivity)
                let readsBefore = idleReads
                monitor.sampleActivity()
                XCTAssertEqual(idleReads, readsBefore)
                notifications.post(name: gain, object: object)
                XCTAssertEqual(foreground[id], true)
                XCTAssertTrue(monitor.isSamplingActivity)
            }
        }

        func testWindowMarkerMovesAndDismantlesWithoutLeakingRegistration() async throws {
            let first = try await makeVisibleWindow()
            defer { first.close() }
            let second = try await makeVisibleWindow(x: 340)
            let id = UUID()
            var foreground: [UUID: Bool] = [:]
            let monitor = MacAppActivityMonitor(
                onForegroundChanged: { foreground[$0] = $1 },
                onUserActivityChanged: { _ in })
            defer {
                monitor.stop()
                second.close()
            }
            let marker = MacActivityWindowMarker.MarkerView(monitor: monitor, sceneID: id)
            try XCTUnwrap(first.contentView).addSubview(marker)
            XCTAssertEqual(foreground[id], true)
            XCTAssertNil(marker.hitTest(.zero))
            try XCTUnwrap(second.contentView).addSubview(marker)
            XCTAssertEqual(foreground[id], true)
            first.close()
            XCTAssertEqual(
                foreground[id], true, "The marker now belongs to the other native window")
            MacActivityWindowMarker.dismantleNSView(marker, coordinator: ())
            XCTAssertEqual(foreground[id], false)
            XCTAssertFalse(monitor.isSamplingActivity)
        }

        func testStopAndDeinitReleaseObserversAndTimer() async throws {
            let window = try await makeVisibleWindow()
            defer { window.close() }
            let id = UUID()
            var foreground: [UUID: Bool] = [:]
            var callbacks = 0
            var monitor: MacAppActivityMonitor? = MacAppActivityMonitor(
                onForegroundChanged: {
                    foreground[$0] = $1
                    callbacks += 1
                },
                onUserActivityChanged: { _ in callbacks += 1 })
            monitor?.attach(window: window, id: id)
            XCTAssertEqual(foreground[id], true)
            weak var releasedMonitor = monitor
            monitor?.stop()
            XCTAssertEqual(foreground[id], false)
            XCTAssertEqual(monitor?.isSamplingActivity, false)
            let callbacksBefore = callbacks
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
            monitor?.attach(window: window, id: id)
            monitor?.sampleActivity()
            monitor?.stop()
            XCTAssertEqual(callbacks, callbacksBefore)
            monitor = nil
            XCTAssertNil(releasedMonitor)

            // The run-loop's repeating timer must never keep its monitor alive by itself.
            monitor = MacAppActivityMonitor(
                onForegroundChanged: { _, _ in }, onUserActivityChanged: { _ in })
            monitor?.attach(window: window, id: UUID())
            weak var timerOwner = monitor
            monitor = nil
            XCTAssertNil(timerOwner)
        }

        private func makeVisibleWindow(x: CGFloat = 40) async throws -> NSWindow {
            let origin = NSScreen.main?.visibleFrame.origin ?? .zero
            let window = NSWindow(
                contentRect: NSRect(x: origin.x + x, y: origin.y + 40, width: 240, height: 180),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            NSApplication.shared.unhide(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<50 {
                if NSApplication.shared.isActive, window.isVisible,
                    window.occlusionState.contains(.visible)
                {
                    return window
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            window.close()
            throw XCTSkip(
                "Native activity tests require an active GUI session and visible AppKit windows")
        }
    }
#endif
