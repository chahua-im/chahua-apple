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

    /// Fetches one server-ordered page from `GET /chats`.
    ///
    /// Use `ListChatsQuery(archived: false)` for active chats. `nextCursor` in
    /// the result is the input for a later page; this protocol does not merge or
    /// reorder pages.
    func listChats(query: ListChatsQuery) async throws -> ListChatsResponse

    /// Fetches a message page from `GET /chats/{chatID}/messages`.
    ///
    /// Use the `olderCursor` and `newerCursor` response fields for paging.
    /// `nextCursor` and `prevCursor` are compatibility fields only.
    func listMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse

    /// Sends a message with `POST /chats/{chatID}/messages`.
    ///
    /// `clientGeneratedId` in the body identifies the client-side send attempt;
    /// the returned `MessageResponse.id` is the server message identifier.
    func sendMessage(chatID: String, body: CreateMessageBody) async throws -> MessageResponse
}
