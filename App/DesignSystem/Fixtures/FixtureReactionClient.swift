#if DEBUG || TIMELINE_PROFILING
    import ChahuaAPI
    import Foundation

    /// Local-only server state for the diagnostic timeline. Exercises the production
    /// reaction controller without production credentials, persistence, or networking.
    @MainActor
    final class FixtureReactionClient: ChahuaAPIClient {
        var failNextMutation = false
        private var messages: [String: MessageResponse] = [:]
        private let decoder: JSONDecoder = {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return decoder
        }()
        private let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return encoder
        }()

        func install(_ messages: [MessageResponse]) {
            self.messages = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        }
        func deleteMessage(chatID: String, messageID: String) async throws {
            throw APIError.unavailable
        }
        func getMessage(chatID: String, messageID: String) async throws -> MessageResponse {
            guard let message = messages[messageID], message.chatId == chatID else {
                throw Failure.missingMessage
            }
            var value = try object(message)
            var reactions = value["reactions"] as? [[String: Any]] ?? []
            for index in reactions.indices where reactions[index]["reactedByMe"] == nil {
                reactions[index]["reactedByMe"] = false
            }
            value["reactions"] = reactions
            return try decoder.decode(
                MessageResponse.self, from: JSONSerialization.data(withJSONObject: value))
        }
        func putReaction(chatID: String, messageID: String, emoji: String) async throws {
            try await mutate(chatID: chatID, messageID: messageID, emoji: emoji, adding: true)
        }
        func deleteReaction(chatID: String, messageID: String, emoji: String) async throws {
            try await mutate(chatID: chatID, messageID: messageID, emoji: emoji, adding: false)
        }

        private func mutate(chatID: String, messageID: String, emoji: String, adding: Bool)
            async throws
        {
            try await Task.sleep(for: .milliseconds(250))
            if failNextMutation {
                failNextMutation = false
                throw Failure.rejectedMutation
            }
            let message = try await getMessage(chatID: chatID, messageID: messageID)
            var value = try object(message)
            var reactions = value["reactions"] as? [[String: Any]] ?? []
            if let index = reactions.firstIndex(where: { $0["emoji"] as? String == emoji }) {
                let selected = reactions[index]["reactedByMe"] as? Bool == true
                if selected != adding {
                    reactions[index]["count"] =
                        (reactions[index]["count"] as? Int ?? 0) + (adding ? 1 : -1)
                    reactions[index]["reactedByMe"] = adding
                    var reactors = reactions[index]["reactors"] as? [[String: Any]] ?? []
                    reactors.removeAll { $0["uid"] as? Int == 1 }
                    if adding { reactors.insert(["uid": 1, "name": "Me"], at: 0) }
                    reactions[index]["reactors"] = Array(reactors.prefix(5))
                }
            } else if adding {
                reactions.append([
                    "emoji": emoji, "count": 1, "reactedByMe": true,
                    "reactors": [["uid": 1, "name": "Me"]],
                ])
            }
            value["reactions"] = reactions.filter { ($0["count"] as? Int ?? 0) > 0 }
            messages[messageID] = try decoder.decode(
                MessageResponse.self, from: JSONSerialization.data(withJSONObject: value))
        }

        private func object(_ message: MessageResponse) throws -> [String: Any] {
            guard
                let object = try JSONSerialization.jsonObject(with: encoder.encode(message))
                    as? [String: Any]
            else {
                throw Failure.missingMessage
            }
            return object
        }

        func authenticate(candidateJWT: String) async throws -> MeResponse {
            throw Failure.unexpectedOperation
        }
        func createDevSession(uid: Int32, clientID: String) async throws -> String {
            throw Failure.unexpectedOperation
        }
        func me() async throws -> MeResponse { throw Failure.unexpectedOperation }
        func attachmentConfig() async throws -> AttachmentConfigResponse {
            throw Failure.unexpectedOperation
        }
        func requestAttachmentUpload(
            fileName: String, contentType: String, size: Int64, width: Int, height: Int, order: Int
        ) async throws -> OutgoingUploadAllocation { throw Failure.unexpectedOperation }
        func listOwnedStickerPacks() async throws -> [StickerPackSummary] {
            throw Failure.unexpectedOperation
        }
        func listSubscribedStickerPacks() async throws -> [StickerPackSummary] {
            throw Failure.unexpectedOperation
        }
        func listFavoriteStickers() async throws -> [MessageStickerResponse] {
            throw Failure.unexpectedOperation
        }
        func getSticker(id: String) async throws -> StickerDetailResponse {
            throw Failure.unexpectedOperation
        }
        func getStickerPack(id: String) async throws -> StickerPackDetailResponse {
            throw Failure.unexpectedOperation
        }
        func setStickerFavorite(id: String, favorite: Bool) async throws {
            throw Failure.unexpectedOperation
        }
        func setStickerPackSubscription(id: String, subscribed: Bool) async throws {
            throw Failure.unexpectedOperation
        }
        func createStickerPack(name: String, description: String?) async throws
            -> StickerPackSummary
        {
            throw Failure.unexpectedOperation
        }
        func updateStickerPack(id: String, name: String?, description: String?) async throws
            -> StickerPackSummary
        { throw Failure.unexpectedOperation }
        func deleteStickerPack(id: String) async throws { throw Failure.unexpectedOperation }
        func uploadStickerToPack(
            id: String, upload: StickerUpload, emoji: String, name: String?, description: String?
        ) async throws -> MessageStickerResponse { throw Failure.unexpectedOperation }
        func removeStickerFromPack(id: String, stickerID: String) async throws {
            throw Failure.unexpectedOperation
        }
        func updateStickerPackOrder(_ order: [StickerPackOrderUpdate]) async throws {
            throw Failure.unexpectedOperation
        }
        func listChats(query: ListChatsQuery) async throws -> ListChatsResponse {
            throw Failure.unexpectedOperation
        }
        func archiveChat(chatID: String) async throws { throw Failure.unexpectedOperation }
        func unarchiveChat(chatID: String) async throws { throw Failure.unexpectedOperation }
        func archiveThread(chatID: String, threadID: String) async throws {
            throw Failure.unexpectedOperation
        }
        func unarchiveThread(chatID: String, threadID: String) async throws {
            throw Failure.unexpectedOperation
        }
        func muteChat(chatID: String, durationSeconds: Int?) async throws -> MuteResponse {
            throw Failure.unexpectedOperation
        }
        func unmuteChat(chatID: String) async throws { throw Failure.unexpectedOperation }
        func markChatRead(chatID: String, messageID: String) async throws -> ReadStateResponse {
            throw Failure.unexpectedOperation
        }
        func markChatUnread(chatID: String) async throws -> ReadStateResponse {
            throw Failure.unexpectedOperation
        }
        func markThreadRead(chatID: String, threadID: String, messageID: String) async throws
            -> ReadStateResponse
        { throw Failure.unexpectedOperation }
        func listThreads(query: ListThreadsQuery) async throws -> ListThreadsResponse {
            throw Failure.unexpectedOperation
        }
        func sendThreadMessage(chatID: String, threadID: String, body: CreateMessageBody)
            async throws -> MessageResponse
        { throw Failure.unexpectedOperation }
        func groupInfo(chatID: String) async throws -> GroupInfoResponse {
            throw Failure.unexpectedOperation
        }
        func listMembers(chatID: String, query: ListMembersQuery) async throws
            -> ListMembersResponse
        { throw Failure.unexpectedOperation }
        func updateGroupMemberRole(chatID: String, uid: Int32, role: GroupRole) async throws
            -> MemberResponse
        { throw Failure.unexpectedOperation }
        func removeGroupMember(chatID: String, uid: Int32) async throws {
            throw Failure.unexpectedOperation
        }
        func friendRelationship(peerUID: Int32) async throws -> FriendRelationshipResponse {
            throw Failure.unexpectedOperation
        }
        func listMessages(chatID: String, query: ListMessagesQuery) async throws
            -> ListMessagesResponse
        {
            throw Failure.unexpectedOperation
        }
        func sendMessage(chatID: String, body: CreateMessageBody) async throws -> MessageResponse {
            throw Failure.unexpectedOperation
        }

        private enum Failure: LocalizedError {
            case unexpectedOperation, missingMessage, rejectedMutation
            var errorDescription: String? {
                switch self {
                case .unexpectedOperation:
                    "This endpoint is not part of the local reaction fixture."
                case .missingMessage: "The local fixture message was not found."
                case .rejectedMutation: "The diagnostic server rejected this reaction."
                }
            }
        }
    }
#endif
