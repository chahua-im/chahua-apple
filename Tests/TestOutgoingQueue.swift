import ChahuaAPI
import Foundation
@testable import chahua_apple

private final class TestOutgoingStorage: Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chahua-tests-\(UUID().uuidString)")
    deinit { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
func testOutgoingQueue(apiClient: any ChahuaAPIClient) -> OutgoingMessageQueue {
    let storage = TestOutgoingStorage()
    return OutgoingMessageQueue(apiClient: apiClient, localStoreFactory: { uid in
        try await Task.detached {
            try ChahuaLocalStore(directory: storage.directory.appendingPathComponent(String(uid)))
        }.value
    }, onInvalidToken: {})
}
