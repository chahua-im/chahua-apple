/// Typed asynchronous contract for the Chahua HTTP API.
///
/// Feature code should depend on this protocol instead of `ChahuaClient` so it can
/// inject deterministic transports. Every chat and message identifier is an opaque
/// server `String`; do not convert identifiers or cursors to numeric types.
public protocol ChahuaAPIClient: Sendable {
    /// Validates and installs a candidate JWT, returning the authenticated account.
    ///
    /// A production `ChahuaClient` performs `GET /users/me` with the candidate
    /// bearer token and installs it only after validation succeeds.
    func authenticate(candidateJWT: String) async throws -> MeResponse

    /// Creates and installs a development session for `uid`.
    ///
    /// This maps to `POST /auth/dev-session` and sends `clientID` as
    /// `X-Client-Id`; callers must keep it out of release-only flows.
    func createDevSession(uid: Int32, clientID: String) async throws -> String

    /// Fetches the currently authenticated account with `GET /users/me`.
    func me() async throws -> MeResponse

    /// Fetches the current attachment size limit with `GET /attachments/config`.
    func attachmentConfig() async throws -> AttachmentConfigResponse

    /// Allocates an attachment ID and presigned PUT URL; allocation is not upload completion.
    func requestAttachmentUpload(
        fileName: String, contentType: String, size: Int64, width: Int, height: Int, order: Int
    ) async throws -> OutgoingUploadAllocation

    /// Fetches one server-ordered page from `GET /chats`.
    ///
    /// Use `ListChatsQuery(archived: false)` for active chats. `nextCursor` in
    /// the result is the input for a later page; this protocol does not merge or
    /// reorder pages.
    func listChats(query: ListChatsQuery) async throws -> ListChatsResponse

    /// Fetches one server-ordered page of subscriptions with `GET /threads`.
    ///
    /// Use `archived: false` for active threads and pass `nextCursor` as
    /// `ListThreadsQuery.before` for the next page.
    func listThreads(query: ListThreadsQuery) async throws -> ListThreadsResponse

    /// Archives the current member's chat and mutes it indefinitely (204).
    func archiveChat(chatID: String) async throws

    /// Restores the current member's chat and clears its mute (204).
    func unarchiveChat(chatID: String) async throws

    /// Archives only this thread subscription, not its parent chat (204).
    func archiveThread(chatID: String, threadID: String) async throws

    /// Restores only this thread subscription, leaving its parent chat unchanged (204).
    func unarchiveThread(chatID: String, threadID: String) async throws

    /// Mutes chat notifications with `PUT /group/{chatID}/mute`.
    ///
    /// A `nil` duration requests the server's indefinite mute; a non-`nil`
    /// duration is measured in seconds.
    func muteChat(chatID: String, durationSeconds: Int?) async throws -> MuteResponse

    /// Unmutes an active chat. The server also clears its archive flag.
    func unmuteChat(chatID: String) async throws

    /// Fetches current membership and DM peer identity with `GET /group/{chatID}`.
    func groupInfo(chatID: String) async throws -> GroupInfoResponse

    /// Searches current group members with authenticated `GET /group/{chatID}/members`.
    func listMembers(chatID: String, query: ListMembersQuery) async throws -> ListMembersResponse

    /// Changes a group member's server-authorized role with `PATCH /group/{chatID}/members/{uid}`.
    func updateGroupMemberRole(chatID: String, uid: Int32, role: GroupRole) async throws -> MemberResponse

    /// Removes a member with `DELETE /group/{chatID}/members/{uid}`.
    func removeGroupMember(chatID: String, uid: Int32) async throws

    /// Fetches the server's DM authorization decision with `GET /friends/{peerUID}`.
    func friendRelationship(peerUID: Int32) async throws -> FriendRelationshipResponse

    /// Fetches a message page from `GET /chats/{chatID}/messages`.
    ///
    /// Use the `olderCursor` and `newerCursor` response fields for paging.
    /// `nextCursor` and `prevCursor` are compatibility fields only.
    func listMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse

    /// Fetches authoritative, current-recipient state with `GET /chats/{chatID}/messages/{messageID}`.
    func getMessage(chatID: String, messageID: String) async throws -> MessageResponse

    /// Replaces the text of an existing message with `PATCH /chats/{chatID}/messages/{messageID}`.
    func updateMessage(chatID: String, messageID: String, body: UpdateMessageBody) async throws -> MessageResponse

    /// Recalls a published message for all participants with `DELETE /chats/{chatID}/messages/{messageID}`.
    func deleteMessage(chatID: String, messageID: String) async throws

    /// Idempotent reaction mutation at `/chats/{chatID}/messages/{messageID}/reactions/{emoji}`.
    func putReaction(chatID: String, messageID: String, emoji: String) async throws
    func deleteReaction(chatID: String, messageID: String, emoji: String) async throws

    /// Chat-scoped pins; thread pin endpoints are not supported by the server.
    func listPins(chatID: String) async throws -> ListPinsResponse
    func createPin(chatID: String, messageID: String) async throws -> PinResponse
    func deletePin(chatID: String, pinID: String) async throws

    /// Sticker library snapshots and flat sticker/pack detail responses.
    func listOwnedStickerPacks() async throws -> [StickerPackSummary]
    func listSubscribedStickerPacks() async throws -> [StickerPackSummary]
    func listFavoriteStickers() async throws -> [MessageStickerResponse]
    func getSticker(id: String) async throws -> StickerDetailResponse
    func getStickerPack(id: String) async throws -> StickerPackDetailResponse

    /// Idempotent PUT/DELETE mutations; success has no response body.
    func setStickerFavorite(id: String, favorite: Bool) async throws
    func setStickerPackSubscription(id: String, subscribed: Bool) async throws

    /// Sends a message with `POST /chats/{chatID}/messages`.
    ///
    /// `clientGeneratedId` in the body identifies the client-side send attempt;
    /// the returned `MessageResponse.id` is the server message identifier.
    func sendMessage(chatID: String, body: CreateMessageBody) async throws -> MessageResponse

    /// Sends a reply with `POST /chats/{chatID}/threads/{threadID}/messages`.
    ///
    /// `threadID` is the root message identifier within `chatID`; the body uses
    /// the same client-generated idempotency identifier as a parent-chat send.
    func sendThreadMessage(chatID: String, threadID: String, body: CreateMessageBody) async throws -> MessageResponse

    /// Advances the current member's read cursor with `POST /chats/{chatID}/read`.
    func markChatRead(chatID: String, messageID: String) async throws -> ReadStateResponse

    /// Rewinds a chat's read cursor with `POST /chats/{chatID}/unread`.
    func markChatUnread(chatID: String) async throws -> ReadStateResponse

    /// Advances a subscribed thread's read cursor without marking its parent chat read.
    func markThreadRead(chatID: String, threadID: String, messageID: String) async throws -> ReadStateResponse
}

public extension ChahuaAPIClient {
    func updateMessage(chatID: String, messageID: String, body: UpdateMessageBody) async throws -> MessageResponse {
        throw APIError.unavailable
    }

    func listPins(chatID: String) async throws -> ListPinsResponse {
        throw APIError.unavailable
    }

    func createPin(chatID: String, messageID: String) async throws -> PinResponse {
        throw APIError.unavailable
    }

    func deletePin(chatID: String, pinID: String) async throws {
        throw APIError.unavailable
    }
}
