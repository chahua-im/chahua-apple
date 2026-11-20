# Offline cache and weak-network architecture

Account-local offline messaging for the iOS and macOS main app. First sign-in still requires a network connection. The Share extension retains its direct-send path.

## Goals

1. Cold launch shows cached conversations and messages instead of a blank loading screen.
2. The user can browse cached conversations and messages without a network.
3. The user can send messages while offline. The outbox delivers them automatically when the app has a usable connection and the operating system gives it time to run.
4. Sending and browsing degrade gracefully on slow or unstable networks.

Out of scope: offline edit, recall and reactions on published messages. These actions stay online-only.

## Backend constraints

The design does not require backend changes. It accepts these limits:

- History pages use snowflake message IDs (`before`, `after`, `around`, `max` ≤ 100). Responses omit deleted messages.
- `MessageResponse` has no `updatedAt` or revision. No delta endpoint, change feed or ETag exists.
- The WebSocket has no sequence number or replay cursor. Queue overflow closes the connection.

Therefore the cache is **never authoritative**. It supplies a fast first display. Server snapshots then replace the cached data that they cover.

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

Published send settlement commits the canonical message and removes its matching outbox row in one transaction. Accepted audio that is still processing leaves only an in-memory bubble until publication. Clear Message History deletes cache rows only. A later compaction can reclaim free pages, but SQLite can reuse them even if compaction fails.

### Schema

| Table | Key | Content |
|---|---|---|
| `cached_conversation` | `(chat_id, thread_id)` | `ChatListItem`/`ThreadListItem` JSON without peer receipts or unread counts, archive state, activity sort key |
| `cached_list` | list scope (active/archived × chats/threads) | `complete`, `fetched_at` |
| `cached_message` | `(chat_id, message_id)` | Full `MessageResponse` JSON and a reply-to index for redaction |
| `cached_member` | `(chat_id, thread_id, message_id)` | Reference to the canonical message body |
| `cached_segment` | `(chat_id, thread_id, lo)` | Upper boundary and the oldest/latest proof at fetch time |
| `cached_scope` | `(chat_id, thread_id)` | Last accepted policy, settings, send decision and verified-empty state |
| `cached_tombstone` | `(chat_id, message_id)` | Known deleted identity, applied to late records |
| `pending_read` | `(chat_id, thread_id)` | Last confirmed base and queued read target |
| `cache_meta` | singleton | Epoch used to reject cache writes after clear |

An empty `thread_id` means the parent chat timeline. A thread root can appear in both scopes without duplicating its body. Ordered message IDs and boundaries use fixed eight-byte, unsigned big-endian values, not SQLite integers.

## Segments

A **segment** is an ID range that server pages proved contiguous. A timeline window shows rows from one segment only. It never joins two segments across an unknown gap.

1. An accepted page removes omitted membership only in the server-proven bounds, including the exclusive request cursor or an exhausted side. An empty latest page clears that scope and then replays its intervening events. It does not delete a body still referenced in another scope.
2. Baselines and accepted events share one ordered ingress per account. A newer-started overlapping snapshot blocks an older one from overwriting saved history. Cache writes compare the account epoch in the database transaction.
3. A confirmed create extends latest coverage only when the page and create belong to the same uninterrupted socket attempt. The proof is kept in memory. Without proof, the create is a separate known section.
4. Updates and reactions change known bodies without proving coverage. Deletions store tombstones and redact previews. A permission change invalidates affected coverage; confirmed access loss purges the affected chat.

## Read path

| Moment | Behavior |
|---|---|
| Launch | Show each requested list’s first saved page, including a confirmed empty list. Browse more with bounded indexed reads. A first server page updates matching rows; only a complete projection removes absent rows |
| Conversation open | Seed a saved window by target, unread boundary or latest known section. If the target is not saved, keep readable content and show its unavailability |
| Paging | Show more saved rows inside a section. An explicit older or newer saved-section action crosses a gap without implying continuous history |
| Recovery | Replace the saved window with a server baseline at the visible anchor, or with latest if the user follows latest. While following latest, show new live messages without treating the gap to saved rows as continuous history. If the refresh fails, keep readable content visible and retry a bounded number of times while the timeline is active and online |

Invariants:

- A cache-seeded window has explicit disk provenance and no server paging cursors or confirmed live edge.
- Cached rows never acknowledge reads and never change unseen counts. Read tracking starts after the first server baseline.
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
| Display priority | A recovery refresh starts the visible timeline and active projections before archived lists. The first accepted list page updates rows as the remaining pages load |
| Read intent | Send reads for visible server-confirmed rows directly when online. Save the highest eligible target and its last confirmed base when offline or after a transient failure. Before replay, verify scoped read state and the target. A covered, rewound, invalid or deleted target does not send a mark |
| Media | Retain images by size in the account's cache. Expensive or constrained paths use retained frames or thumbnails for automatic display. Attachment metadata supplies originals only, so the app does not download an original to make a thumbnail on a weak path. A user can request full media. Missing offline media shows an unavailable state |

The server does not supply a read-state revision. A read and an unread operation on another device that end at the same cursor cannot always be distinguished.

## Size and clearing

The message cache has no size or age limit. Settings → Storage shows logical message payload bytes separately from media. Clear Message History removes downloaded history, not the database, drafts, attachments, outbox or pending reads. Confirmed sign-out purges all account rows; session expiry and account switches keep them. The account directory keeps its storage protection and is excluded from backup, including SQLite journals and local outbox files.

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
