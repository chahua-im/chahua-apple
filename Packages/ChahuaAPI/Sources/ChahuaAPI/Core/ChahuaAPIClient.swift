/// Typed asynchronous contract for the Chahua HTTP API.
///
/// Feature code should depend on this protocol instead of `ChahuaClient` so it can
/// inject deterministic transports. Every chat and message identifier is an opaque
/// server `String`; do not convert identifiers or cursors to numeric types.
public protocol ChahuaAPIClient: Sendable {
    /// Immutable forwarding operations; reuse the same key and source IDs for retries.
    func forwardMessage(chatID: String, messageID: MessageID, body: ForwardMessageBody)
        async throws -> MessageResponse
    func forwardMessages(chatID: String, body: ForwardMessagesBody)
        async throws -> MessageResponse
    func getForwardedMessages(chatID: String, messageID: MessageID, bundleID: String?)
        async throws -> ForwardedMessagesResponse
    func getSavedForwardedMessages(savedMessageID: String, bundleID: String?)
        async throws -> ForwardedMessagesResponse

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

    /// Fetches the authenticated account's policy with `GET /me/presence-settings`.
    func presenceSettings() async throws -> PresenceSettingsResponse

    /// Replaces the policy with `PUT /me/presence-settings`, returning the saved value.
    /// This controls individual online and last-seen sharing, not group counts.
    func updatePresenceSettings(visibility: PresenceVisibility) async throws
        -> PresenceSettingsResponse

    /// Caller-owned GET/PUT /friends/{peerUID}/presence-settings override.
    func friendPresenceSettings(peerUID: Int32) async throws -> FriendPresenceSettingsResponse
    func updateFriendPresenceSettings(peerUID: Int32, override: FriendPresenceOverride)
        async throws -> FriendPresenceSettingsResponse

    /// Reads a DM peer's visible cursor; thread scopes use the optional `threadId` query.
    func readReceipt(chatID: String, threadID: MessageID?) async throws -> ReadReceiptResponse

    /// Authoritative GET/PUT /me/read-receipt-settings policy.
    func readReceiptSettings() async throws -> ReadReceiptSettingsResponse
    func updateReadReceiptSettings(visibility: ReadReceiptVisibility) async throws
        -> ReadReceiptSettingsResponse

    /// Authoritative GET/PUT /friends/{peerUID}/read-receipt-settings refinement.
    func friendReadReceiptSettings(peerUID: Int32) async throws
        -> FriendReadReceiptSettingsResponse
    func updateFriendReadReceiptSettings(peerUID: Int32, override: FriendReadReceiptOverride)
        async throws -> FriendReadReceiptSettingsResponse

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

    /// Group mentions and replies share a newest-first message queue, scoped to the main chat or thread.
    func unreadMentions(chatID: String, threadID: MessageID?) async throws
        -> UnreadMentionIDsResponse

    /// Returns unread reaction targets and the opaque snapshot boundary for acknowledgement.
    func unreadReactions(chatID: String, threadID: MessageID?) async throws
        -> UnreadReactionIDsResponse

    /// Acknowledges the queried snapshot; omit `readThrough` only when leaving the conversation.
    func acknowledgeReactions(chatID: String, threadID: MessageID?, readThrough: String?)
        async throws -> UnreadReactionsAckResponse

    /// Archives the current member's chat without changing notification preferences (204).
    func archiveChat(chatID: String) async throws

    /// Restores the current member's chat without changing notification preferences (204).
    func unarchiveChat(chatID: String) async throws

    /// Archives only this thread subscription, not its parent chat (204).
    func archiveThread(chatID: String, threadID: String) async throws

    /// Restores only this thread subscription, leaving its parent chat unchanged (204).
    func unarchiveThread(chatID: String, threadID: String) async throws

    /// Reads the current user's subscription with `GET /chats/{chatID}/threads/{threadID}/subscribe`.
    func threadSubscriptionStatus(chatID: String, threadID: String) async throws
        -> ThreadSubscriptionStatus

    /// Subscribes to a thread (204); the server also subscribes repliers and mentioned members.
    func subscribeThread(chatID: String, threadID: String) async throws

    func notificationSettings() async throws -> NotificationSettingsResponse
    func updateNotificationSettings(_ request: UpdateNotificationSettingsRequest) async throws
        -> NotificationSettingsResponse
    func updateChatNotificationSetting(chatID: String, request: UpdateNotificationSettingRequest)
        async throws -> ChatNotificationSettingResponse
    func notificationExceptions(kind: ChatKind, after: String?) async throws
        -> NotificationExceptionsResponse
    func clearNotificationExceptions(kind: ChatKind) async throws -> NotificationExceptionsCleared

    /// Fetches current membership and DM peer identity with `GET /group/{chatID}`.
    func groupInfo(chatID: String) async throws -> GroupInfoResponse

    /// Searches current group members with authenticated `GET /group/{chatID}/members`.
    func listMembers(chatID: String, query: ListMembersQuery) async throws -> ListMembersResponse

    /// Changes a group member's server-authorized role with `PATCH /group/{chatID}/members/{uid}`.
    func updateGroupMemberRole(chatID: String, uid: Int32, role: GroupRole) async throws
        -> MemberResponse

    /// Removes a member with `DELETE /group/{chatID}/members/{uid}`.
    func removeGroupMember(chatID: String, uid: Int32) async throws

    /// Fetches the server's DM authorization decision with `GET /friends/{peerUID}`.
    func friendRelationship(peerUID: Int32) async throws -> FriendRelationshipResponse
    func removeFriend(peerUID: Int32) async throws
    func blockUser(uid: Int32) async throws
    func unblockUser(uid: Int32) async throws

    /// Fetches a message page from `GET /chats/{chatID}/messages`.
    ///
    /// Use the `olderCursor` and `newerCursor` response fields for paging.
    /// `nextCursor` and `prevCursor` are compatibility fields only.
    func listMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse

    /// Fetches authoritative, current-recipient state with `GET /chats/{chatID}/messages/{messageID}`.
    func getMessage(chatID: String, messageID: MessageID) async throws -> MessageResponse

    /// Searches a chat's text messages with `GET /chats/{chatID}/messages/search`.
    ///
    /// Results span the chat and its threads; `MessageResponse.replyRootId`
    /// identifies thread replies. Page with `SearchMessagesResponse.nextOffset`.
    /// Servers without message search configured respond with HTTP 503.
    func searchMessages(chatID: String, query: SearchMessagesQuery) async throws
        -> SearchMessagesResponse

    /// Replaces the text of an existing message with `PATCH /chats/{chatID}/messages/{messageID}`.
    func updateMessage(chatID: String, messageID: MessageID, body: UpdateMessageBody) async throws
        -> MessageResponse

    /// Recalls a published message for all participants with `DELETE /chats/{chatID}/messages/{messageID}`.
    func deleteMessage(chatID: String, messageID: MessageID) async throws

    /// Idempotent reaction mutation at `/chats/{chatID}/messages/{messageID}/reactions/{emoji}`.
    func putReaction(chatID: String, messageID: MessageID, emoji: String) async throws
    func deleteReaction(chatID: String, messageID: MessageID, emoji: String) async throws

    /// Fetches every reactor for each emoji with `GET /chats/{chatID}/messages/{messageID}/reactions`.
    func getReactionDetails(chatID: String, messageID: MessageID) async throws
        -> ReactionDetailResponse

    /// Chat-scoped pins; thread pin endpoints are not supported by the server.
    func listPins(chatID: String) async throws -> ListPinsResponse
    func createPin(chatID: String, messageID: MessageID) async throws -> PinResponse
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

    /// Creates a sticker pack with `POST /stickers/packs`.
    func createStickerPack(name: String, description: String?) async throws -> StickerPackSummary

    /// Changes the supplied fields of an owned pack with `PATCH /stickers/packs/{id}`.
    func updateStickerPack(id: String, name: String?, description: String?) async throws
        -> StickerPackSummary

    /// Deletes an owned pack with `DELETE /stickers/packs/{id}`.
    func deleteStickerPack(id: String) async throws

    /// Uploads a new sticker as multipart form data to an owned pack.
    func uploadStickerToPack(
        id: String, upload: StickerUpload, emoji: String, name: String?, description: String?
    ) async throws -> MessageStickerResponse

    /// Removes a sticker from an owned pack with `DELETE /stickers/packs/{id}/stickers/{stickerID}`.
    func removeStickerFromPack(id: String, stickerID: String) async throws

    /// Merges sticker-pack ordering preferences with `PUT /users/me/stickerpack-order`.
    func updateStickerPackOrder(_ order: [StickerPackOrderUpdate]) async throws

    /// Sends a message with `POST /chats/{chatID}/messages`.
    ///
    /// `clientGeneratedId` in the body identifies the client-side send attempt;
    /// the returned `MessageResponse.id` is the server message identifier.
    func sendMessage(chatID: String, body: CreateMessageBody) async throws -> MessageResponse

    /// Sends a reply with `POST /chats/{chatID}/threads/{threadID}/messages`.
    ///
    /// `threadID` is the root message identifier within `chatID`; the body uses
    /// the same client-generated idempotency identifier as a parent-chat send.
    func sendThreadMessage(chatID: String, threadID: String, body: CreateMessageBody) async throws
        -> MessageResponse

    /// Advances the current member's read cursor with `POST /chats/{chatID}/read`.
    func markChatRead(chatID: String, messageID: MessageID) async throws -> ReadStateResponse

    /// Rewinds a chat's read cursor with `POST /chats/{chatID}/unread`.
    func markChatUnread(chatID: String) async throws -> ReadStateResponse

    /// Advances a subscribed thread's read cursor without marking its parent chat read.
    func markThreadRead(chatID: String, threadID: String, messageID: MessageID) async throws
        -> ReadStateResponse

    /// Fetches the current member's cursor and all counters with `GET /chats/{chatID}/unread`.
    func chatReadState(chatID: String) async throws -> ReadStateResponse

    /// Fetches authorized thread state with the chat-scoped `read-state` endpoint.
    func threadReadState(chatID: String, threadID: String) async throws -> ReadStateResponse
}

extension ChahuaAPIClient {
    public func forwardMessage(chatID: String, messageID: MessageID, body: ForwardMessageBody)
        async throws -> MessageResponse
    {
        throw APIError.unavailable
    }

    public func forwardMessages(chatID: String, body: ForwardMessagesBody)
        async throws -> MessageResponse
    {
        throw APIError.unavailable
    }

    public func getForwardedMessages(
        chatID: String, messageID: MessageID, bundleID: String?
    ) async throws -> ForwardedMessagesResponse {
        throw APIError.unavailable
    }

    public func getSavedForwardedMessages(savedMessageID: String, bundleID: String?)
        async throws -> ForwardedMessagesResponse
    {
        throw APIError.unavailable
    }

    public func getForwardedMessages(chatID: String, messageID: MessageID)
        async throws -> ForwardedMessagesResponse
    {
        try await getForwardedMessages(chatID: chatID, messageID: messageID, bundleID: nil)
    }

    public func getSavedForwardedMessages(savedMessageID: String)
        async throws -> ForwardedMessagesResponse
    {
        try await getSavedForwardedMessages(savedMessageID: savedMessageID, bundleID: nil)
    }

    public func chatReadState(chatID: String) async throws -> ReadStateResponse {
        throw APIError.unavailable
    }

    public func threadReadState(chatID: String, threadID: String) async throws -> ReadStateResponse
    {
        throw APIError.unavailable
    }

    public func presenceSettings() async throws -> PresenceSettingsResponse {
        throw APIError.unavailable
    }

    public func updatePresenceSettings(visibility: PresenceVisibility) async throws
        -> PresenceSettingsResponse
    {
        throw APIError.unavailable
    }

    public func friendPresenceSettings(peerUID: Int32) async throws
        -> FriendPresenceSettingsResponse
    {
        throw APIError.unavailable
    }

    public func updateFriendPresenceSettings(peerUID: Int32, override: FriendPresenceOverride)
        async throws -> FriendPresenceSettingsResponse
    {
        throw APIError.unavailable
    }

    public func removeFriend(peerUID: Int32) async throws {
        throw APIError.unavailable
    }

    public func blockUser(uid: Int32) async throws {
        throw APIError.unavailable
    }

    public func unblockUser(uid: Int32) async throws {
        throw APIError.unavailable
    }

    public func createStickerPack(name: String) async throws -> StickerPackSummary {
        try await createStickerPack(name: name, description: nil)
    }

    public func updateStickerPack(id: String, name: String) async throws -> StickerPackSummary {
        try await updateStickerPack(id: id, name: name, description: nil)
    }

    public func updateStickerPack(id: String, description: String) async throws
        -> StickerPackSummary
    {
        try await updateStickerPack(id: id, name: nil, description: description)
    }

    public func uploadStickerToPack(id: String, upload: StickerUpload, emoji: String) async throws
        -> MessageStickerResponse
    {
        try await uploadStickerToPack(
            id: id, upload: upload, emoji: emoji, name: nil, description: nil)
    }

    public func updateMessage(chatID: String, messageID: MessageID, body: UpdateMessageBody)
        async throws -> MessageResponse
    {
        throw APIError.unavailable
    }

    public func searchMessages(chatID: String, query: SearchMessagesQuery) async throws
        -> SearchMessagesResponse
    {
        throw APIError.unavailable
    }

    public func threadSubscriptionStatus(chatID: String, threadID: String) async throws
        -> ThreadSubscriptionStatus
    {
        throw APIError.unavailable
    }

    public func subscribeThread(chatID: String, threadID: String) async throws {
        throw APIError.unavailable
    }

    public func listPins(chatID: String) async throws -> ListPinsResponse {
        throw APIError.unavailable
    }

    public func createPin(chatID: String, messageID: MessageID) async throws -> PinResponse {
        throw APIError.unavailable
    }

    public func deletePin(chatID: String, pinID: String) async throws {
        throw APIError.unavailable
    }
}
