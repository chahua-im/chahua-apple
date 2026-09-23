import ChahuaAPI
import Combine
import Foundation

/// One session socket shared by all windows; scene activity controls presence, not its lifetime.
@MainActor
final class RealtimeCoordinator: ObservableObject {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let provider: any RealtimeConnectionProviding
    private let store: ChatStore
    private let onInvalidToken: @MainActor @Sendable () async -> Void
    private let sleep: Sleep
    private let jitter: @Sendable () -> Double
    private var uid: Int32?
    private var activeScenes = Set<UUID>()
    private var generation = 0
    private var attempt = 0
    private var runner: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var stableConnection: Task<Void, Never>?
    private var pendingSend: Task<Void, Never>?
    private var pongDeadline: Task<Void, Never>?
    private var recovery: Task<Void, Never>?
    private var connection: (any RealtimeConnection)?
    private var appState: RealtimeAppState { activeScenes.isEmpty ? .inactive : .active }
    private var awaitingPong = false
    private var failures = 0

    init(
        provider: any RealtimeConnectionProviding,
        store: ChatStore,
        onInvalidToken: @escaping @MainActor @Sendable () async -> Void,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...0.2) }
    ) {
        self.provider = provider
        self.store = store
        self.onInvalidToken = onInvalidToken
        self.sleep = sleep
        self.jitter = jitter
    }

    func setSession(uid: Int32?) {
        guard self.uid != uid else { return }
        stop()
        self.uid = uid
        failures = 0
        store.reset()
        store.outgoingQueue.requestSession(uid: uid)
        startIfNeeded()
    }

    func setSceneActive(id: UUID, active: Bool) {
        let wasActive = !activeScenes.isEmpty
        if active { activeScenes.insert(id) } else { activeScenes.remove(id) }
        let isActive = !activeScenes.isEmpty
        guard wasActive != isActive else { return }
        store.setForegroundActive(isActive)
        if let connection {
            enqueuePresence(
                .appState(appState), on: connection, generation: generation, attempt: attempt)
        }
        if isActive {
            startIfNeeded()
            if connection != nil { startRecovery(generation: generation) }
        } else {
            // Match the PWA's visibility/focus contract: inactive presence permits push
            // notifications while retaining event delivery and stateful heartbeats.
            // iOS may suspend the process; resume uses the same timeout/reconnect path,
            // not an intentional disconnect or background-execution entitlement.
            recovery?.cancel()
            recovery = nil
            store.cancelRealtimeRecovery()
        }
    }

    func removeScene(id: UUID) { setSceneActive(id: id, active: false) }

    private func startIfNeeded() {
        guard runner == nil, let uid else { return }
        let currentGeneration = generation
        runner = Task { [weak self] in
            await self?.run(uid: uid, generation: currentGeneration)
        }
    }

    private func run(uid: Int32, generation currentGeneration: Int) async {
        while generation == currentGeneration && !Task.isCancelled {
            attempt += 1
            let currentAttempt = attempt
            do {
                // Opening authenticates only. Read activity after the asynchronous
                // handshake so a focus change during opening cannot advertise active.
                let socket = try await provider.openRealtimeConnection()
                guard generation == currentGeneration, !Task.isCancelled else {
                    await socket.close()
                    return
                }
                connection = socket
                enqueuePresence(
                    .appState(appState), on: socket, generation: currentGeneration,
                    attempt: currentAttempt)
                startHeartbeat(socket, generation: currentGeneration, attempt: currentAttempt)
                startStableReset(generation: currentGeneration, attempt: currentAttempt)
                startRecovery(generation: currentGeneration)
                while generation == currentGeneration && !Task.isCancelled {
                    let event = try await socket.receive()
                    guard generation == currentGeneration, attempt == currentAttempt,
                        !Task.isCancelled
                    else { break }
                    if case .pong = event {
                        awaitingPong = false
                        pongDeadline?.cancel()
                        pongDeadline = nil
                    } else {
                        await store.applyRealtimeEvent(event, currentUserID: uid)
                        guard generation == currentGeneration, attempt == currentAttempt,
                            !Task.isCancelled
                        else { return }
                    }
                }
            } catch {
                guard generation == currentGeneration, !Task.isCancelled else { return }
                if case APIError.invalidToken = error {
                    stop()
                    await onInvalidToken()
                    return
                }
            }
            guard generation == currentGeneration, !Task.isCancelled else { return }
            heartbeat?.cancel()
            stableConnection?.cancel()
            pendingSend?.cancel()
            pongDeadline?.cancel()
            heartbeat = nil
            stableConnection = nil
            pendingSend = nil
            pongDeadline = nil
            awaitingPong = false
            let disconnected = connection
            connection = nil
            await disconnected?.close()
            guard generation == currentGeneration, !Task.isCancelled else { return }
            let seconds = min(30.0, pow(2.0, Double(min(failures, 5))))
            failures += 1
            let delay = min(30.0, seconds * (1 + min(0.2, max(0, jitter()))))
            do { try await sleep(.seconds(delay)) } catch { return }
        }
    }

    private enum PresenceFrame {
        case appState(RealtimeAppState)
        case ping
    }

    /// Serialize state changes with pings. Cancelling a transport send closes its
    /// socket, so focus transitions must enqueue rather than cancel pending sends.
    @discardableResult
    private func enqueuePresence(
        _ frame: PresenceFrame,
        on socket: any RealtimeConnection,
        generation currentGeneration: Int,
        attempt currentAttempt: Int
    ) -> Task<Void, Never> {
        let previous = pendingSend
        let task = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled,
                self.generation == currentGeneration, self.attempt == currentAttempt,
                self.connection != nil
            else { return }
            do {
                switch frame {
                case .appState(let state):
                    try await socket.sendAppState(state)
                case .ping:
                    // A simultaneous heartbeat must never reset an outstanding
                    // deadline; both timers can wake together after suspension.
                    guard !self.awaitingPong else {
                        await socket.close()
                        return
                    }
                    self.armPongDeadline(
                        socket, generation: currentGeneration, attempt: currentAttempt)
                    try await socket.sendPing(state: self.appState)
                }
            } catch {
                await socket.close()
            }
        }
        pendingSend = task
        return task
    }

    private func startRecovery(generation currentGeneration: Int) {
        guard uid != nil, !activeScenes.isEmpty else { return }
        recovery?.cancel()
        recovery = Task { [weak self] in
            guard let self, !Task.isCancelled, self.generation == currentGeneration,
                !self.activeScenes.isEmpty
            else { return }
            async let chats: Void = self.store.refreshActiveConversations()
            async let archived: Void = self.store.refreshArchivedConversations()
            async let messages: Void = self.store.reconcileVisibleTimelines()
            _ = await (chats, archived, messages)
        }
    }

    private func startStableReset(generation currentGeneration: Int, attempt currentAttempt: Int) {
        stableConnection?.cancel()
        stableConnection = Task { [weak self, sleep] in
            do { try await sleep(.seconds(5)) } catch { return }
            guard let self, !Task.isCancelled,
                self.generation == currentGeneration, self.attempt == currentAttempt
            else { return }
            self.failures = 0
        }
    }

    private func armPongDeadline(
        _ socket: any RealtimeConnection, generation currentGeneration: Int,
        attempt currentAttempt: Int
    ) {
        awaitingPong = true
        pongDeadline?.cancel()
        pongDeadline = Task { [weak self, sleep] in
            do { try await sleep(.seconds(10)) } catch { return }
            guard let self, !Task.isCancelled, self.generation == currentGeneration,
                self.attempt == currentAttempt, self.awaitingPong
            else { return }
            await socket.close()
        }
    }

    private func startHeartbeat(
        _ socket: any RealtimeConnection, generation currentGeneration: Int,
        attempt currentAttempt: Int
    ) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self, sleep] in
            while !Task.isCancelled {
                do { try await sleep(.seconds(10)) } catch { return }
                guard let self, !Task.isCancelled, self.generation == currentGeneration,
                    self.attempt == currentAttempt
                else { return }
                await self.enqueuePresence(
                    .ping, on: socket, generation: currentGeneration, attempt: currentAttempt
                ).value
            }
        }
    }

    private func stop() {
        generation += 1
        runner?.cancel()
        heartbeat?.cancel()
        stableConnection?.cancel()
        pendingSend?.cancel()
        pongDeadline?.cancel()
        recovery?.cancel()
        runner = nil
        heartbeat = nil
        stableConnection = nil
        pendingSend = nil
        pongDeadline = nil
        recovery = nil
        store.cancelRealtimeRecovery()
        if let connection {
            // Only session teardown closes intentionally; no racing inactive send.
            Task { await connection.close() }
        }
        connection = nil
        awaitingPong = false
    }
}
