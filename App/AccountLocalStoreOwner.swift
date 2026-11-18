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
    private(set) var store: ChahuaLocalStore?

    init(factory: @escaping Factory) {
        self.factory = factory
    }

    func setSession(uid: Int32?) {
        guard self.uid != uid else { return }
        self.uid = uid
        generation &+= 1
        opening?.task.cancel()
        opening = nil
        store = nil
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
            request = (UUID(), Task { try await factory(uid) })
            opening = request
        }
        defer { if opening?.id == request.id { opening = nil } }
        let opened = try await request.task.value
        guard current == generation else { throw CancellationError() }
        store = opened
        return opened
    }
}
