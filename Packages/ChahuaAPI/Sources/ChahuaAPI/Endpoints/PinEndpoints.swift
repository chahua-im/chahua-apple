import Foundation

public struct ListPinsResponse: Decodable, Sendable {
    public let pins: [PinResponse]

    public init(pins: [PinResponse]) {
        self.pins = pins
    }
}

private struct CreatePinBody: Encodable {
    let messageId: String
}

extension ChahuaClient {
    public func listPins(chatID: String) async throws -> ListPinsResponse {
        try await send(
            HTTPRequestSpec(method: .get, path: ["chats", chatID, "pins"]),
            decoding: ListPinsResponse.self
        )
    }

    public func createPin(chatID: String, messageID: String) async throws -> PinResponse {
        try await send(
            HTTPRequestSpec.json(
                .post, ["chats", chatID, "pins"], body: CreatePinBody(messageId: messageID)),
            decoding: PinResponse.self
        )
    }

    public func deletePin(chatID: String, pinID: String) async throws {
        try await send(HTTPRequestSpec(method: .delete, path: ["chats", chatID, "pins", pinID]))
    }
}
