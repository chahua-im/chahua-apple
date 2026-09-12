# Outbound queue architecture

Status: implemented as a main-app feature in `App/Features/Chat/Outbox`, not a separate package.

## Ownership

A composing message is the **blocked tail of its outbound queue**, not a separate attachment pipeline. Each account has an independent queue per `ConversationKey(chatID, threadID)`. A nil thread identifies only the parent conversation. Persisted sequence numbers determine order; upload completion order does not.

| Component | Responsibility |
|---|---|
| `OutgoingMessageQueue` | Main-actor commands, revision-filtered snapshots/events, session isolation, bounded scheduling and acknowledgement reconciliation |
| `ChahuaLocalStore` | Transactional items, blocked-tail ownership, ordered slots, checkpoints, dispatch claims and migrations in the existing account database |
| `OutgoingImageProcessor` | Cancellable detached photo/video import, ImageIO/AVFoundation inspection, previews and optional image compression |
| `OutgoingAttachmentUploader` | File-backed URLSession PUT, native byte progress and cancellation |
| `OutgoingFileCleanup` | Deferred reclamation of unreferenced account-owned media |
| `ChatDraftStore` | Composer presentation and committed-text persistence, not an independent attachment owner |
| `ChatStore` | Timeline projections and acknowledgement routing, not attachment scheduling |

`AppCompositionRoot` provides the shared account queue. The main actor serializes decisions, not image processing or network I/O. Storage remains in ChahuaAPI's existing GRDB repository; there is no second database, schema owner or new package.

## Durable items and attachment slots

`LocalOutgoingMessage` retains its `clientGeneratedID` from composition through release, retry and confirmation. It records text/caption, reply context, sequence, edit revision, compression option, ordered attachments, blocked state, delivery state and a sticky `dispatchClaimed` flag.

Delivery states remain `queued`, `sending` and `failed`. A failed or restored claimed item is conservatively an uncertain delivery: it cannot be modified or revoked. Confirmation removes the durable item; revocation removes an eligible undispatched tail.

`LocalDraft` projects the blocked item, including its identity and attachments. The legacy draft table retains revision watermarks rather than a second authoritative payload. User-edit revisions and snapshot/checkpoint revisions are separate, so upload progress cannot invalidate a text edit.

Each `LocalOutgoingAttachment` has a stable ID, generation, position, source/prepared/preview paths, filename, MIME type, dimensions, byte count, uploaded attachment ID and error. Durable checkpoints express this progression:

`source installed -> prepared file selected -> uploaded ID saved after successful PUT`

**Allocation and PUT are one retryable client operation, not a server transaction.** Each attempt allocates a fresh ID and immediately uploads the prepared file. Allocation instructions exist only within that attempt; the slot resolves only after successful PUT and durable checkpointing. A failed or interrupted attempt leaves the slot unresolved, and retry allocates again. Existing stored allocation fields are ignored when decoding older slots; prepared files and completed upload IDs remain recoverable. Local previews remain available after success.

For slots `[A, B, C]`, completion order `C, A, B` still produces message IDs `[idA, idB, idC]`. Dispatch requires every slot to be uploaded and error-free; partial attachment messages are never constructed.

## Composition, release and revocation

- `beginComposition` returns or creates the sole blocked tail. Multiple windows share that item.
- Committed text/reply updates and attachment add/remove/reorder/options mutate only composition. IME marked text remains transient in `ComposerInputState`.
- `enqueueText` is the retained submission entry point for both captions and media-only messages. It atomically releases the blocked identity and clears the draft projection; it does not create a second item or restart its uploads.
- Send waits only for local acquisition/import durability, not compression or upload. Temporary Photos/picker/provider URLs are not durable input. The composer disables submission while acquisition is in progress. A failed release leaves composition intact.
- `blockTail` transfers an undispatched released tail back to the composer. `revokeTail` discards an eligible tail. Both require item identity and expected edit revision and serialize against dispatch claims in SQLite.
- A non-tail item cannot be moved into composition or revoked. Once claimed, even a failed request cannot be unsealed; these commands return `dispatchAlreadyClaimed`.
- Slot removal, reordering and compression changes invalidate affected generations. Late workers cannot replace newer content or resurrect a revoked item.

Before release only the composer shows the item; afterward only the pending timeline shows it. Navigation does not revoke composition. Message editing remains a separate server mutation and does not acquire new outbox attachments.

## Scheduling and FIFO

Attachment work is eligible for blocked and released items. Message work is eligible only for the released, ready head. One image preparation and two uploads may run concurrently across conversations, with released work prioritized over composing work. Each conversation has at most one active message request.

Retry preserves FIFO. A failed head prevents successor dispatch; successors stay queued rather than being falsely marked failed. Retrying a later item does not promote it ahead of an older message. Other conversations and attachment preparation remain independent.

Preparation, uploads and sending follow the existing foreground/account lifecycle. Preparation does not depend on WebSocket connectivity and can operate offline. Network failures retain durable work for retry; this feature does not promise indefinite iOS background execution.

Upload progress is transient, throttled to percentage changes rather than written to SQLite on every byte event. Errors preserve the last successful checkpoint and surface retry controls.

## Dispatch and acknowledgement races

The first dispatch claim permanently seals the payload and attachment identities. A timeout or cancellation may mean the server accepted the request. Retry therefore uses the same `clientGeneratedId`, content, reply context and uploaded IDs; it does not renew attachments after claim.

A validated HTTP, WebSocket or history acknowledgement dominates late send errors. Durable deletion finishes against the captured account store even when scene teardown cancels its sender. Session generations prevent late publications from reaching a different account. If local finalization fails, the original durable item remains available for reconciliation or idempotent replay; an in-memory acknowledgement suppresses its pending projection in the active session.

Revocation guarantees only that the message will not be dispatched when revocation wins the claim transaction. Cancelling a PUT is best-effort. A completed or allocated remote attachment may remain orphaned; local revocation does not pretend to delete remote objects.

## Native preparation and durable files

Unsent media lives under the account's Application Support directory, in `Outbox/<slot UUID>/`, not the evictable media cache. Database paths are relative to the account directory and resolve when loaded, including after container relocation. Imports reject external/symlink/nonregular references. Files are atomically installed before committing their database references.

The persisted `compressionEnabled` option selects the current fixed preparation policy:

- Disabled: upload the validated original.
- Enabled: target a longest edge of 1920 pixels, preserve orientation, use PNG for transparency and JPEG otherwise, and replace the original only if the result is less than 75% of its byte size.
- Multi-frame images retain their original bytes rather than flattening animation.
- Videos retain their original bytes regardless of this option. AVFoundation validates playable video and extracts an oriented preview; container extensions are normalized from file headers before loading.
- Local previews use an oriented thumbnail up to 480 pixels; preparation records actual output MIME type, dimensions and byte count.

Changing compression while blocked invalidates prepared/uploaded work and reprocesses the original. Prepared checkpoints survive restart. Any future algorithm change must explicitly account for persisted unprepared work; the current option is a Boolean, not a versioned policy registry.

Cleanup waits for preparation/upload/import activity to settle and a 60-second grace period. It retains referenced sources, prepared files and previews, and only removes older unreferenced account-owned files. This protects acknowledgement handoff and newly installed files awaiting a database reference. Missing referenced files surface as attachment errors, not silent omission.

Recovery resumes from durable boundaries:

- Interrupted preparation starts again from the original.
- Interrupted or failed PUT retries the same prepared file with a fresh allocation.
- Completed PUT checkpoints reuse the uploaded ID.
- Released items restore to the pending timeline; blocked items restore to composition and never auto-release.
- Claimed sends restore conservatively for exact replay, never editable composition.
- Account changes cancel workers, advance generations and activate the destination account's own repository and files.

## Verified backend protocol and limits

1. `GET /attachments/config` returns `maxFileSizeBytes`, checked against the prepared file.
2. `POST /attachments/upload-url` sends filename, contentType, size, purpose `media`, order, width and height.
3. The response supplies attachmentId, uploadUrl and uploadHeaders; allocation URLs currently expire after 15 minutes.
4. PUT uploads the file with those headers. The uploader excludes API bearer credentials, cookies and redirects.
5. The existing chat/thread message endpoint receives the caption and ordered attachmentIds.

Every unresolved upload retry allocates a new ID, including after HTTP 403 or restart. There are no allocation expiry checks or persisted upload URLs. A lost PUT response or local success checkpoint can therefore cause the bytes to be uploaded again under another ID. This deliberately trades extra remote orphans for simpler recovery: the backend has no client allocation idempotency key or explicit renew/delete-unattached endpoint. Completed slots are reused, and claimed message requests never replace their attachment IDs.

Attachment metadata is sorted by allocation-time `order` and ID on the backend. Reordering therefore invalidates moved slots and reallocates them; changing the final message array alone is insufficient. The composer supports up to 20 attachments.

Message replay uses the backend's client-generated-ID conflict handling, which checks chat, sender, text, type, reply and attachment set. The client retains the exact sealed request across uncertain delivery. This is not an exactly-once attachment-allocation guarantee, nor a guarantee of remote orphan cleanup or indefinite unattached retention.

## Presentation and verification

The shared SwiftUI composer accepts photos and videos through Photos, Files, clipboard acquisition and drag/drop. Attaching media opens `ComposerAttachmentDialog`: a fixed count/close/options header, large scrollable previews and a fixed caption/send row. Per-item menus provide retry, removal and reordering; the header menu contains one image-compression option for the entire selection. Videos are sent unchanged. macOS also installs `onPasteCommand`; iOS uses `PasteButton` in the attachment menu.

The caption edits the existing conversation draft. Closing the dialog preserves caption edits and attachments for later review; successful durable release clears the draft and dismisses the dialog, while failure retains both. The inline composer offers a review button for retained attachments rather than a second attachment tray.

The full chat detail pane and caption dialog accept additional media drops. `ComposerAttachmentState` shares acquisition/error state and hands pane drops to the existing composer import transaction, preventing duplicate batches while a drop or import is pending. Gallery drags use an own-process slot type rather than image/file URLs, so moving a tile never imports it again. Hover shows an insertion edge and can scroll the gallery; only a validated drop commits a complete new order. Gallery/session/membership checks reject stale or foreign payloads, and cancelled/no-op drags do not change the queue.

IME composition does not toggle control availability. Submission checks native marked text and the current composition boundary. On macOS, plain Return is intercepted before AppKit ends field editing, avoiding the select-all flash caused by restarting the editor. Candidate-confirmation Return remains native; Shift-Return inserts a newline with native selection and undo behavior.

Pending bubbles consume explicit local references rather than fabricated server attachment responses and offer eligible tail edit/discard actions. Local and delivered attachments use the same `BubbleMediaLayout`, placement and tile chrome, including caption spacing and media-only metadata overlays. Upload progress and Ready/Processing labels are not shown in timeline media; the existing hollow checkmark identifies a pending message, with the normal failure action retained for failed sends.

Verification performed for this implementation:

- Local persistence regression tests: account relocation/isolation, migration, ordered checkpoints, stale-generation rejection, FIFO, concurrent release/claim/revoke and sticky claims.
- macOS app tests, including composer focus/IME and queue acknowledgement/retry behavior.
- iOS Simulator build of the shared composer and native acquisition integration.
- Throwaway loopback smoke using the real queue, ImageIO processor, URLSession uploader and SQLite store: release during preparation, failed PUT/retry, ordered bytes/IDs and FIFO delivery, revocation during upload, uncertain message replay, and restart of a blocked image-only thread draft.
- Fresh-allocation retry smoke: HTTP 500, restart, HTTP 403 and successful PUT used three distinct IDs with identical prepared bytes. Only the successful ID was dispatched; uncertain message replay after another restart allocated nothing and retained the sealed request.
- Native caption-dialog smoke with controlled submission outcomes: carried draft text, preserved caption on cancellation/failure, cleared caption and dismissal on success, and 20-item scrolling without moving the caption row. Three-item and scrolled-gallery rendering inspected on macOS.
- Generated landscape MP4 and rotated portrait MOV imported/prepared with correct display dimensions, decodable previews and byte-identical originals under both image-compression settings; image preparation also produced a decodable result.
- Pending-media smoke: local/delivered sizes and gallery cells match for 1, 2, 3, 6, 7 and 20 attachments; inspected the rendered pending gallery and hollow metadata checkmark.
- Provider/state smoke: pane acquisition opened the caption and appended subsequent media without losing its draft; reorder payloads committed once, rejected stale/foreign membership and skipped no-op/cancelled changes. Edge-hover scrolling stopped on exit. End-to-end pointer-driven drag verification was blocked by macOS input-posting permission and remains a manual check.
- Full Photos/iCloud interaction, iOS keyboard feel and live-backend sending still require manual verification.

## Source references

- [OutgoingMessageQueue](../../App/Features/Chat/Outbox/OutgoingMessageQueue.swift)
- [OutgoingImageProcessor](../../App/Features/Chat/Outbox/OutgoingImageProcessor.swift)
- [OutgoingAttachmentUploader](../../App/Features/Chat/Outbox/OutgoingAttachmentUploader.swift)
- [OutgoingFileCleanup](../../App/Features/Chat/Outbox/OutgoingFileCleanup.swift)
- [LocalStorageModels](../../Packages/ChahuaAPI/Sources/ChahuaAPI/LocalStorage/LocalStorageModels.swift)
- [ChahuaLocalStore](../../Packages/ChahuaAPI/Sources/ChahuaAPI/LocalStorage/ChahuaLocalStore.swift)
- [LocalStorageSchema](../../Packages/ChahuaAPI/Sources/ChahuaAPI/LocalStorage/LocalStorageSchema.swift)
- [AttachmentEndpoints](../../Packages/ChahuaAPI/Sources/ChahuaAPI/Endpoints/AttachmentEndpoints.swift)
- [Realtime architecture](realtime-messaging.md)

Backend references: sibling `chahua/backend/src/handlers/attachments.rs` and `services/messages.rs`. PWA references: sibling `chahua/wetty-chat-mobile/src/components/chat/compose/useComposeAttachments.ts`, `MessageComposeBar.tsx`, `utils/compression.ts` and `api/upload.ts`.
