# Offline cache and weak-network architecture

Account-local offline messaging for the iOS and macOS main app. First sign-in still requires a network connection. The Share extension retains its direct-send path.

## Goals

1. Cold launch shows cached conversations and messages instead of a blank loading screen.
2. The user can browse cached conversations and messages without a network.
3. The user can send messages while offline. The outbox delivers them automatically when the app has a usable connection and the operating system gives it time to run.
4. Sending and browsing degrade gracefully on slow or unstable networks.

Out of scope: offline edit, recall and reactions on published messages. These actions stay online-only.

## Backend constraints

The cache uses two independent server protocols:

- `GET /chats/difference` supplies an account list baseline and commit-ordered list changes with opaque, account-bound cursors.
- Message sync replays each chat's ordered message log. Its checkpoint is separate from the list cursor and does not prove that a saved window covers a requested history position.
- History pages use snowflake message IDs (`before`, `after`, `around`, `max` ≤ 100). Standard recall is soft deletion. Legacy sockets have no replay checkpoint.

Saved data supplies the first display. A completed list pass establishes list freshness; history needs its own page or certified replay coverage.

## Session start without network

The app-private Keychain record `offline-session-v1` binds the API base URL, SHA-256 digest of the exact stored credential, and the last server-verified profile. A match opens the account and displays the shell as `.localOnly`. The client then validates through authenticated `GET /users/me`, which can refresh the token once. Without a binding, the app waits for successful validation before opening any account database.

| Validation result | Action |
|---|---|
| Success | Replace the cached profile; mark the session validated |
| 401 after one refresh attempt | Existing session-expiry path |
| Transport failure | Keep the session; validate again when connectivity returns |

`.localOnly` permits account storage access. Only `.verified` permits network activity other than the validation request. Refresh and sign-out serialize credential and binding writes. A mismatch cannot open another account’s cache. Expiry hides the account without purging its work.

## Storage

Each account has one `chat.sqlite`, opened through the same GRDB `DatabaseQueue` for drafts, the outbox and downloaded history. Opening the store migrates known versions. Only a valid migration ledger with an unrecognized applied identifier permits erasing and rebuilding that account database. This discards its drafts and outbox. Read, migration, disk and file-protection failures do not authorize an erase.

Outside message sync, published send settlement commits the canonical message and removes its matching outbox row in one transaction. A receipt from the sync stream settles the outbox separately; the batch or page transaction owns the history write. Accepted audio that is still processing leaves only an in-memory bubble until publication. Clear Message History deletes cache rows only. A later compaction can reclaim free pages, but SQLite can reuse them even if compaction fails.

### Schema

| Table | Key | Content |
|---|---|---|
| `cached_conversation` | `(chat_id, thread_id)` | Installed chat/thread JSON, including unread activity and peer receipts, archive state and activity sort key |
| `cached_list` | list scope (active/archived × chats/threads) | `complete`, `fetched_at` |
| `list_sync_state` | singleton | Installed/staging cursors and encoded chat/notification settings |
| `list_sync_stage` | `(chat_id, thread_id)` | Replacement list rows and selected main-message sidecars, hidden from normal reads |
| `cached_message` | `(chat_id, message_id)` | Full `MessageResponse` JSON and a reply-to index for redaction |
| `cached_member` | `(chat_id, thread_id, message_id)` | Reference to the canonical message body |
| `cached_segment` | `(chat_id, thread_id, lo)` | Upper boundary and the oldest/latest proof at fetch time |
| `cached_scope` | `(chat_id, thread_id)` | Last accepted policy, settings, send decision and verified-empty state |
| `cached_tombstone` | `(chat_id, message_id)` | Known deleted identity, applied to late records |
| `sync_checkpoint` | `chat_id` | Opaque position applied through the chat’s ordered change log, shared by the main timeline and threads |
| `sync_latest` | `(chat_id, thread_id)` | Scope has a checkpointed latest segment or a confirmed empty tail |
| `pending_read` | `(chat_id, thread_id)` | Last confirmed base and queued read target |
| `cache_meta` | singleton | Epoch used to reject cache writes after clear |

An empty `thread_id` means the parent chat timeline. A thread root can appear in both scopes without duplicating its body. Ordered message IDs and boundaries use fixed eight-byte, unsigned big-endian values, not SQLite integers.

## Account list sync

One account task coalesces list appearances, reconnect, foreground resume, path restoration and invalidations. HTTP does not wait for message-sync negotiation. Automatic requests require a verified session and usable path; explicit retry can bypass the path hint, not authentication.

A nil cursor starts a native baseline. Every reset starts empty staging with the returned cursor, including unknown reset reasons. Follow that cursor through enumeration and catch-up, including empty incomplete pages. Keep the installed list visible until the final complete page replaces its key set atomically. Restart resumes the durable staging cursor first. A second reset without page progress saves its new cursor and stops with retry.

Each response commits rows, removals, settings, sidecars and its next cursor in one transaction through `AccountHistoryCache`. Full expected state and account epoch checks also apply to manual nil requests. Local mutation, read, receipt, notification and privacy revisions fence stale responses in the ordered writer. Publish only after commit. A write error retains the prior projection and cursor.

An installed delta replaces keys, not archive buckets. Removing a main chat removes its child list rows; removing a thread does not revoke its parent. Missing parents in an ordinary delta do not imply removal. Revocation and deletion also purge or redact staging. Settings apply to visible installed content during a rebuild and are checked again at promotion.

Only an authenticated 404 from this route selects legacy list scans. Clear native cursors and staging before a legacy scan writes. Remember unsupported status for the connection attempt and probe again on reconnect. Transport, authentication, decoding and storage errors do not select legacy. Pull-to-refresh requests a new baseline; failure retry resumes the last durable cursor.

Local reads retain the first-page size of 50 and activity ordering. Requery the displayed row count after an accepted reorder, removal or promotion, with fresh boundaries. Archived rows load on demand. HTTP completion does not exhaust local paging.

Native message sync holds new sidebar previews until the resume list refresh installs the current projection. History replay and access revocations continue without waiting for HTTP. Keep only the newest deferred message per conversation; publish it after its batch commits and only if its ID is newer than the installed preview. Edits and deletions of the selected message still apply. If list refresh fails, hold candidates until initial replay completes, then publish one newest preview per conversation. Disconnect, visibility reset and revocation discard the affected candidates.

Only a top-level sidecar matching the chat's selected latest message can seed history. Prefer an existing canonical body; otherwise save one isolated message segment after visibility and tombstone checks. A list cursor never creates message-sync checkpoints or continuous-history proof. At live edge, retain that saved row at the bottom with loading or network retry above it. Online unread entry still seeks a missing read anchor through normal history; offline entry can show the seed.

### Server rollout boundary

Deploy the list-stamp migration before enabling clients. Retention follows the server's pruned global floor, not a client token-age rule. Follow pages sequentially without a client page-count ceiling.

Before rollout, check target data for subscribed membership-system thread roots. Normal thread creation uses text roots; historical or imported system roots need the server's history-visibility predicate in both legacy and difference projections. Apple redaction is not server authorization.

External hard deletion or visibility changes must produce server tombstones or a purge/reset. Filtered message replay alone does not remove missing IDs. Monitor `chats.difference` timing and global-head commit contention during reconnect bursts; bounded response size does not bound all projection database work.


## Segments

A **segment** is an ID range that server pages proved contiguous. A timeline window shows rows from one segment only. It never joins two segments across an unknown gap.

1. An accepted page removes omitted membership only in the server-proven bounds, including the exclusive request cursor or an exhausted side. An empty latest page clears that scope and then replays its intervening events. It does not delete a body still referenced in another scope.
2. Baselines and accepted events share one ordered ingress per account. A newer-started overlapping snapshot blocks an older one from overwriting saved history. Cache writes compare the account epoch in the database transaction.
3. A sync batch writes creates, edits and deletions in the same transaction as its checkpoint. The stored cursor must match the batch’s starting cursor. An arrival extends the tail only for a certified scope. Otherwise it joins an overlapping range or remains separate. Legacy sockets retain their in-memory latest-edge proof for that connection only.
4. Updates and reactions change known bodies without proving coverage. Deletions store tombstones and redact previews. A permission change invalidates affected coverage; confirmed access loss purges the affected chat.
5. A sync page stores its rows and latest proof in one transaction only if the page’s checkpoint still matches the stored cursor. A replay gap keeps eligible rows but removes their proof; a visibility reset purges the cached chat instead.

## Read path

| Moment | Behavior |
|---|---|
| Launch | Show the requested scope's first installed page, including a known empty list. Browse more with bounded indexed reads. Keep that list during baseline staging; publish installed deltas only after durable commit |
| Conversation open | Seed a saved window by target, unread boundary or latest known section. If the target is not saved, keep readable content and show its unavailability |
| Paging | Show more saved rows inside a section. An explicit older or newer saved-section action crosses a gap without implying continuous history |
| Recovery | While negotiation and replay run, keep the saved rows and their position. If replay covers the chat and the saved tail covers the requested position, promote it without a history request. Otherwise replace it at the visible anchor, or at latest if the user follows latest. If the refresh fails, keep readable content visible and retry a bounded number of times while the timeline is active and online |

Invariants:

- A provisional window has disk provenance and no server paging cursors or confirmed live edge.
- Provisional rows never acknowledge reads or change unseen counts. Read tracking starts after a server baseline or a promoted tail, subject to the normal viewport rules.
- Pending rows still come from the outbox and deduplicate against cached rows by `clientGeneratedId`.

## Offline behavior

The composition root owns one network path monitor. Its unknown state permits a bounded attempt; an unsatisfied path pauses automatic work. A usable path is a wake signal, not proof that the server or socket works. A user can retry an interactive request even when the path hint is stale.

| Surface or action | Offline behavior |
|---|---|
| Conversation list | Cached rows with an offline status in the existing connection-status slot; no load-failure row while cached rows exist |
| Timeline without cache | "Not available offline" state; loads automatically when the network returns |
| Send text, media, voice, sticker, forward, reply | Submit to the outbox for a destination with a saved write decision. An unknown or denied destination can retain a draft but cannot submit. Offline forwarding sends known source IDs; a whole thread requires complete saved coverage |
| Remove a pending message | Allow local removal of preparing, queued and failed rows. Warn when delivery is uncertain. Removal never recalls a server message |
| Edit, recall, reactions on published messages | Disabled, with an explanation |
| Media without cached bytes | Unavailable-offline placeholder |

## Outbox changes

- **Activation:** local validation enables persistence; server validation enables dispatch. Dispatch can reuse a fresh online permission check for the same destination until path loss or permission invalidation. A saved local decision permits enqueue only.
- **Background draining:** macOS can drain submitted work whenever the process runs. On iOS, the app can request one finite background grant when it becomes inactive and schedule one refresh while actionable submitted work remains. Either grant drains the same queue in FIFO order. Expiration cancels transfers, retains upload checkpoints and preserves the original ID of any uncertain create. iOS delivers at the next opportunity the system permits; it does not promise delivery while suspended or after force-quit.
- **Retry timing:** exponential delivery backoff adds 0–20% jitter, with a 60-second local cap. A server `Retry-After` deadline overrides an earlier local deadline and survives restart, manual retry and background launch.

## Weak-network behavior

| Area | Behavior |
|---|---|
| Reconnect | A usable path wakes validation, a sleeping socket retry, pending reads and the outbox. It does not replace a healthy socket. Delivery does not require a socket |
| Requests | Displayed list and history pages use a 15-second request timeout. Creates retain the configured bounded timeout and explicit outbox retries. Attachment uploads use their separate credential-free session and resume from saved checkpoints |
| Display priority | List HTTP and visible-history recovery run independently. Native list pages are sequential for the account; archived local scopes load on demand |
| Read intent | Send reads for visible server-confirmed rows directly when online. Save the highest eligible target and its last confirmed base when offline or after a transient failure. Before replay, verify scoped read state and the target. A covered, rewound, invalid or deleted target does not send a mark |
| Media | Retain images by size in the account's cache. Expensive or constrained paths use retained frames or thumbnails for automatic display. Attachment metadata supplies originals only, so the app does not download an original to make a thumbnail on a weak path. A user can request full media. Missing offline media shows an unavailable state |

The server does not supply a read-state revision. A read and an unread operation on another device that end at the same cursor cannot always be distinguished.

## Size and clearing

The message cache has no size or age limit. Settings → Storage shows logical message payload bytes separately from media. Clear Message History removes downloaded history, not the database, drafts, attachments, outbox or pending reads.

Reset Local Database requires confirmation. It stops account-local writes, replaces the active account’s database, and removes its outbox files. It resets this account’s local preferences and app-wide display and playback preferences. It keeps the Keychain session and offline account binding. It does not change server settings, push setup, or the separate media cache. The reset can recover from a database that fails to open.

Confirmed sign-out purges all account rows; session expiry and account switches keep them. The account directory keeps its storage protection and is excluded from backup, including SQLite journals and local outbox files.

## Source references

- [AuthSessionModel](../../App/Features/Authentication/AuthSessionModel.swift)
- [ConnectivityMonitor](../../App/ConnectivityMonitor.swift)
- [ChahuaClient](../../Packages/ChahuaAPI/Sources/ChahuaAPI/Core/ChahuaClient.swift)
- [AccountLocalStoreOwner](../../App/AccountLocalStoreOwner.swift)
- [LocalStorageSchema](../../Packages/ChahuaAPI/Sources/ChahuaAPI/LocalStorage/LocalStorageSchema.swift)
- [ChatStore](../../App/Features/Chat/Shared/ChatStore.swift)
- [ConversationTimelineModel](../../App/Features/Chat/Conversation/Timeline/Model/ConversationTimelineModel.swift) and [TimelineWindow](../../App/Features/Chat/Conversation/Timeline/Model/TimelineWindow.swift)
- [OutgoingMessageQueue](../../App/Features/Chat/Outbox/OutgoingMessageQueue.swift) and [OutboxBackgroundExecution](../../App/Features/Chat/Outbox/OutboxBackgroundExecution.swift)
- [RealtimeCoordinator](../../App/Features/Chat/Shared/RealtimeCoordinator.swift)
- [AppMediaContext](../../App/DesignSystem/Media/AppMediaContext.swift)
