#if os(iOS)
import BackgroundTasks
import Combine
import Foundation
import OSLog
import UIKit

/// A system launch grants time to the app's existing queue; it never owns an
/// account store, starts a second dispatcher, or marks a scene as foreground.
@MainActor
final class OutboxRefreshScheduler {
    private enum Wake: Equatable {
        case now, at(Date)

        var earliestBeginDate: Date? {
            if case .at(let date) = self { return date }
            return nil
        }
    }

    private enum Submission: Equatable {
        case empty, submitted(Wake), declined(Wake)
    }

    private struct Run {
        let id: UUID
        let task: BGAppRefreshTask
        let worker: Task<Void, Never>
        var startedDraining = false
    }

    private let queue: OutgoingMessageQueue
    private let session: AuthSessionModel
    private let identifier = Bundle.main.bundleIdentifier.map { "\($0).outbox-refresh" }
    private let scheduler = BGTaskScheduler.shared
    private let logger = Logger(subsystem: "app.chahua.chat", category: "outbox-refresh")
    private var registrationAttempted = false
    private var sessionChanges: AnyCancellable?
    private var lifecycleChanges: AnyCancellable?
    private var submission: Submission?
    private var deferredLaunch = false
    private var run: Run?

    init(queue: OutgoingMessageQueue, session: AuthSessionModel) {
        self.queue = queue
        self.session = session
    }

    func register() {
        guard !registrationAttempted, let identifier else { return }
        registrationAttempted = true
        guard scheduler.register(forTaskWithIdentifier: identifier, using: .main, launchHandler: {
            [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let refresh = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.start(refresh)
            }
        }) else {
            logger.error("Outbox refresh registration failed")
            return
        }

        queue.backgroundWorkDidChange = { [weak self] in self?.updateSubmission() }
        sessionChanges = session.$state.sink { [weak self] state in
            guard let self, case .signedOut = state else { return }
            deferredLaunch = false
            cancelSubmission()
        }
        lifecycleChanges = Publishers.MergeMany([
            UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIApplication.backgroundRefreshStatusDidChangeNotification,
            UIApplication.protectedDataDidBecomeAvailableNotification,
            UIScene.didActivateNotification, UIScene.didEnterBackgroundNotification,
        ].map { NotificationCenter.default.publisher(for: $0) }).sink { [weak self] _ in
            guard let self else { return }
            if case .declined = submission { submission = nil }
            updateSubmission()
        }
        updateSubmission()
    }

    private func updateSubmission() {
        if queue.storageState == .ready { deferredLaunch = false }
        guard run == nil, let identifier else { return }
        let wake: Wake
        if let date = queue.automaticBackgroundWakeDate {
            // Round up the converted monotonic deadline to coalesce repeated samples.
            wake = date > Date()
                ? .at(Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.up)))
                : .now
        } else if deferredLaunch {
            wake = .now
        } else {
            // A not-yet-open store is not an empty queue. Preserve a request
            // from a prior process until restoration or sign-out establishes that.
            if queue.storageState == .ready || (queue.storageState == .inactive && submission != nil) {
                cancelSubmission()
            }
            return
        }
        guard submission != .submitted(wake), submission != .declined(wake) else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = wake.earliestBeginDate
        do {
            // Submitting the same identifier replaces any pending request.
            try scheduler.submit(request)
            submission = .submitted(wake)
        } catch {
            submission = .declined(wake)
            logger.notice("Outbox refresh submission declined: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func cancelSubmission() {
        guard let identifier, submission != .empty else { return }
        scheduler.cancel(taskRequestWithIdentifier: identifier)
        submission = .empty
    }

    private func start(_ task: BGAppRefreshTask) {
        guard run == nil else {
            task.setTaskCompleted(success: false)
            return
        }
        // The system consumed the pending request by launching it.
        submission = nil
        // A delivered request proves work was eligible when it was submitted.
        // Carry that proof across protected storage or transient restore failure.
        if case .signedOut = session.state {
            deferredLaunch = false
        } else {
            deferredLaunch = queue.storageState != .ready
        }
        let id = UUID()
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expire(id) }
        }
        let worker = Task { [weak self] in
            guard let self else { return }
            guard await session.activateForBackground() != nil else {
                // Missing/revoked identity is no work. A protected or unverified
                // session is deferred, not a successful drain.
                let signedOut: Bool
                if case .signedOut = session.state { signedOut = true } else { signedOut = false }
                finish(id, success: signedOut && !Task.isCancelled)
                return
            }
            guard !Task.isCancelled else { return }
            run?.startedDraining = true
            let drained = await queue.drainScheduledRefresh()
            finish(id, success: drained && !Task.isCancelled)
        }
        run = Run(id: id, task: task, worker: worker)
    }

    private func expire(_ id: UUID) {
        guard let run, run.id == id else { return }
        run.worker.cancel()
        // Before the queue starts, a shared validation may take longer to
        // return than the OS grant. A draining worker instead completes once
        // the queue has revoked execution and cancelled active transfers.
        if !run.startedDraining { finish(id, success: false) }
    }

    private func finish(_ id: UUID, success: Bool) {
        guard let run, run.id == id else { return }
        self.run = nil
        run.task.expirationHandler = nil
        updateSubmission()
        run.task.setTaskCompleted(success: success)
    }
}
#endif
