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

    /// Fetches current membership and DM peer identity with `GET /group/{chatID}`.
    func groupInfo(chatID: String) async throws -> GroupInfoResponse

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

    /// Idempotent reaction mutation at `/chats/{chatID}/messages/{messageID}/reactions/{emoji}`.
    func putReaction(chatID: String, messageID: String, emoji: String) async throws
    func deleteReaction(chatID: String, messageID: String, emoji: String) async throws

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

    /// Advances a subscribed thread's read cursor without marking its parent chat read.
    func markThreadRead(chatID: String, threadID: String, messageID: String) async throws -> ReadStateResponse
}

public extension ChahuaAPIClient {
    func updateMessage(chatID: String, messageID: String, body: UpdateMessageBody) async throws -> MessageResponse {
        throw APIError.unavailable
    }
}
