import ChahuaAPI
import Foundation

/// One database queue per active account, shared by the outbox and account readers.
@MainActor
final class AccountLocalStoreOwner {
    typealias Factory = @Sendable (Int32) async throws -> ChahuaLocalStore

    private let factory: Factory
    private var uid: Int32?
    private var generation: UInt64 = 0
    private var opening: (id: UUID, task: Task<ChahuaLocalStore, Error>)?
    private var openingFence: Task<Void, Never>?
    private(set) var store: ChahuaLocalStore?

    init(factory: @escaping Factory) {
        self.factory = factory
    }

    func fenceNextOpen(through task: Task<Void, Never>) {
        let previous = openingFence
        openingFence = Task {
            await previous?.value
            await task.value
        }
    }

    func setSession(uid: Int32?) {
        guard self.uid != uid else { return }
        self.uid = uid
        generation &+= 1
        if let retired = opening?.task {
            retired.cancel()
            fenceNextOpen(through: Task { _ = await retired.result })
        }
        opening = nil
        store = nil
    }

    func reset(uid: Int32, directory: URL) async throws {
        guard self.uid == uid else { throw CancellationError() }
        let retiring = store
        let pending = opening?.task
        let fence = openingFence
        generation &+= 1
        store = nil
        opening = nil

        // Fence future opens even if authentication changes while deletion is in flight.
        let reset = Task {
            await fence?.value
            let opened = try? await pending?.value
            try await Task.detached {
                try (retiring ?? opened)?.close()
                do {
                    try FileManager.default.removeItem(at: directory)
                } catch {
                    let fileError = error as NSError
                    guard fileError.domain == NSCocoaErrorDomain,
                        fileError.code == CocoaError.fileNoSuchFile.rawValue
                    else { throw error }
                }
            }.value
        }
        fenceNextOpen(through: Task { _ = await reset.result })
        try await reset.value
    }

    func open(uid: Int32) async throws -> ChahuaLocalStore {
        guard self.uid == uid else { throw CancellationError() }
        if let store { return store }
        let current = generation
        let request: (id: UUID, task: Task<ChahuaLocalStore, Error>)
        if let opening {
            request = opening
        } else {
            let factory = factory
            let fence = openingFence
            request = (UUID(), Task {
                await fence?.value
                try Task.checkCancellation()
                return try await factory(uid)
            })
            opening = request
        }
        defer { if opening?.id == request.id { opening = nil } }
        let opened = try await request.task.value
        guard current == generation else { throw CancellationError() }
        store = opened
        return opened
    }
}
