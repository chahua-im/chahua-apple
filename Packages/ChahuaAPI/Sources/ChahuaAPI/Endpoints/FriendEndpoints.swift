import Foundation

extension ChahuaClient {
    public func removeFriend(peerUID: Int32) async throws {
        try await send(HTTPRequestSpec(method: .delete, path: ["friends", String(peerUID)]))
    }

    public func blockUser(uid: Int32) async throws {
        try await send(HTTPRequestSpec.json(.post, ["blocks"], body: BlockUserBody(uid: uid)))
    }

    public func unblockUser(uid: Int32) async throws {
        try await send(HTTPRequestSpec(method: .delete, path: ["blocks", String(uid)]))
    }
}

private struct BlockUserBody: Encodable {
    let uid: Int32
}
