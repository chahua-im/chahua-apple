import ChahuaAPI
import Combine
import Foundation

/// One foreground socket for the authenticated dependency graph, not one per window.
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
    private var pongDeadline: Task<Void, Never>?
    private var recovery: Task<Void, Never>?
    private var connection: (any RealtimeConnection)?
    private var ready = false
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
        if wasActive != !activeScenes.isEmpty {
            store.setForegroundActive(!activeScenes.isEmpty)
        }
        if activeScenes.isEmpty { stop() }
        else if !wasActive { failures = 0; startIfNeeded() }
    }

    func removeScene(id: UUID) { setSceneActive(id: id, active: false) }

    private func startIfNeeded() {
        guard runner == nil, let uid, !activeScenes.isEmpty else { return }
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
                let socket = try await provider.openRealtimeConnection()
                guard generation == currentGeneration, !Task.isCancelled else {
                    await socket.close()
                    return
                }
                connection = socket
                ready = false
                armPongDeadline(socket, generation: currentGeneration, attempt: currentAttempt)
                while generation == currentGeneration && !Task.isCancelled {
                    let event = try await socket.receive()
                    guard generation == currentGeneration, attempt == currentAttempt, !Task.isCancelled else { break }
                    if case .pong = event {
                        awaitingPong = false
                        pongDeadline?.cancel()
                        pongDeadline = nil
                        failures = 0
                        if !ready {
                            ready = true
                            startHeartbeat(socket, generation: currentGeneration, attempt: currentAttempt)
                            recovery?.cancel()
                            recovery = Task { [weak self] in
                                guard let self, self.generation == currentGeneration else { return }
                                async let chats: Void = self.store.refreshActiveChats()
                                async let messages: Void = self.store.reconcileVisibleTimelines()
                                _ = await (chats, messages)
                            }
                        }
                    } else {
                        await store.applyRealtimeEvent(event, currentUserID: uid)
                        guard generation == currentGeneration, attempt == currentAttempt, !Task.isCancelled else { return }
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
            pongDeadline?.cancel()
            heartbeat = nil
            pongDeadline = nil
            if let connection { await connection.close() }
            guard generation == currentGeneration, !Task.isCancelled else { return }
            connection = nil
            ready = false
            let seconds = min(30.0, pow(2.0, Double(min(failures, 5))))
            failures += 1
            do { try await sleep(.seconds(seconds * (1 + min(0.2, max(0, jitter()))))) }
            catch { return }
        }
    }

    private func armPongDeadline(_ socket: any RealtimeConnection, generation currentGeneration: Int, attempt currentAttempt: Int) {
        awaitingPong = true
        pongDeadline?.cancel()
        pongDeadline = Task { [weak self, sleep] in
            do { try await sleep(.seconds(10)) } catch { return }
            guard let self, self.generation == currentGeneration, self.attempt == currentAttempt, self.awaitingPong else { return }
            await socket.close()
        }
    }

    private func startHeartbeat(_ socket: any RealtimeConnection, generation currentGeneration: Int, attempt currentAttempt: Int) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self, sleep] in
            while !Task.isCancelled {
                do { try await sleep(.seconds(30)) } catch { return }
                guard let self, self.generation == currentGeneration, self.attempt == currentAttempt else { return }
                self.armPongDeadline(socket, generation: currentGeneration, attempt: currentAttempt)
                do { try await socket.sendPing(state: .active) }
                catch { await socket.close(); return }
            }
        }
    }

    private func stop() {
        generation += 1
        runner?.cancel()
        heartbeat?.cancel()
        pongDeadline?.cancel()
        recovery?.cancel()
        runner = nil
        heartbeat = nil
        pongDeadline = nil
        recovery = nil
        store.cancelRealtimeRecovery()
        if let connection {
            // Presence is advisory. A blocked send must never hold foreground shutdown.
            Task { try? await connection.sendAppState(.inactive) }
            Task { await connection.close() }
        }
        connection = nil
        ready = false
        awaitingPong = false
    }
}
