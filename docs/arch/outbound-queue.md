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

`LocalOutgoingMessage` retains its `clientGeneratedID` from composition through release, retry and confirmation. The latest submitted intent owns text, edit revision and optional ordered `LocalEditAttachment` selection; a nil selection means the original local slots. Server-backed selection slots retain real `AttachmentResponse` values without fabricating local paths.

Delivery states remain `queued`, `sending` and `failed`. Migration v8 adds an immutable frozen create request/revision, confirmed message and publication state, cancellation intent, acknowledged revision, replayable claimed PATCH and mutation-retry classification. Confirmation retains the row until clean finalization; active editor leases defer that finalization. Cancellation removes unclaimed items or hides claimed items as tombstones pending authoritative server deletion.

Sticker sends persist a complete `MessageStickerResponse` snapshot in the nullable `sticker` column added by migration v5. Nil retains the existing text/attachment contract. The snapshot supplies both the `.sticker` request's `stickerId` and pending media after restart; sticker requests have no text or attachments and retain the same identity and reply through retries.

`LocalDraft` projects the blocked item, including its identity and attachments. The legacy draft table retains revision watermarks rather than a second authoritative payload. User-edit revisions and snapshot/checkpoint revisions are separate, so upload progress cannot invalidate a text edit.

Each `LocalOutgoingAttachment` has a stable ID, generation, position, source/prepared/preview paths, filename, MIME type, dimensions, byte count, uploaded attachment ID and error. Durable checkpoints express this progression:

`source installed -> prepared file selected -> uploaded ID saved after successful PUT`

**Allocation and PUT are one retryable client operation, not a server transaction.** Each attempt allocates a fresh ID and immediately uploads the prepared file. Allocation instructions exist only within that attempt; the slot resolves only after successful PUT and durable checkpointing. A failed or interrupted attempt leaves the slot unresolved, and retry allocates again. Existing stored allocation fields are ignored when decoding older slots; prepared files and completed upload IDs remain recoverable. Local previews remain available after success.

For slots `[A, B, C]`, completion order `C, A, B` still produces message IDs `[idA, idB, idC]`. Reordering those slots to `[C, A, B]` instead submits `[idC, idA, idB]` without uploading any unchanged content again. Dispatch requires every slot to be uploaded and error-free; partial attachment messages are never constructed.

## Composition, release and revocation

- `beginComposition` returns or creates the sole blocked tail. Multiple windows share that item.
- Committed ordinary draft text/reply and attachment operations mutate only composition. IME marked text remains transient in `ComposerInputState`.
- `enqueueText` is the retained submission entry point for both captions and media-only messages. It atomically releases the blocked identity and clears the draft projection; it does not create a second item or restart its uploads.
- `enqueueSticker` creates a released item without consuming the blocked text/attachment composition. It places that composition after the sticker while preserving its identity, revisions and upload checkpoints. `ChatDraftStore.submitSticker` flushes committed edits, fences account changes and clears only the submitted reply after successful durable enqueue. Stickers are cancellation-only, never editable text/media.
- Send waits only for local acquisition/import durability, not compression or upload. Temporary Photos/picker/provider URLs are not durable input. The composer disables submission while acquisition is in progress. A failed release leaves composition intact.
- `editOutgoing` and `cancelOutgoing` target a released item by conversation, client identity and expected revision, not queue position. Edits preserve reply and sequence and change only latest intent; claimed requests remain frozen. Cancellation commits intent before stopping work and never restores cancelled content.
- Tail ownership checks apply only to ordinary composition and its attachment operations. Text/media queued edits use a separate leased `PendingEditSession`; forwarded, file, audio and sticker items cannot enter that editor.
- Source and compression changes invalidate affected content generations; removal retires the slot. Reordering changes only durable positions, preserving prepared files, completed upload IDs, in-flight preparation/PUTs and progress. A worker checkpoint merges into the latest position by slot ID and content generation, so late completion cannot restore an old order, replace newer content or resurrect a removed/revoked item.

Before release only the composer shows the item; afterward the pending timeline owns latest intent exactly once, overlaying any older confirmed row with the same client identity. Entering a queued edit settles IME text, flushes ordinary text/reply, discards ordinary attachments and recording, and leaves the queued send running. Successful local intent commit or edit cancellation reveals ordinary text/reply again; there is no attachment save-and-restore policy. Unsubmitted session imports are transient and do not restore after process death.

## Scheduling and FIFO

Attachment work is eligible for blocked/released items and leased editor imports, sharing the existing preparation/upload bounds. Create work remains FIFO per conversation; confirmed rows and cancellation tombstones cannot block successors. Each item has a separate serialized PATCH/DELETE worker, so realtime confirmation can begin mutation while its original HTTP create response is held.

A failed unconfirmed create still blocks successors until explicit retry. Mutations retry transport failures and HTTP 408/429/500/502/503/504 with a one-second exponential delay capped at 30 seconds while foreground/authenticated. Persisted retryable mutation failures resume on foreground/restore; permanent failures require explicit retry. Cancellation takes precedence over PATCH and never starts another PATCH afterward.

Preparation, uploads and sending follow the existing foreground/account lifecycle. Preparation does not depend on WebSocket connectivity and can operate offline. Network failures retain durable work for retry; this feature does not promise indefinite iOS background execution.

Upload progress is transient, throttled to percentage changes rather than written to SQLite on every byte event. Errors preserve the last successful checkpoint and surface retry controls.

## Dispatch and acknowledgement races

The first dispatch claim freezes the entire create request, including ordered uploaded IDs, original reply and revision. Legacy claimed rows are frozen transactionally before edit/claim/restore; malformed rows fail rather than synthesize a different request. Every POST retry replays that frozen body/client ID even after latest intent changes.

HTTP, WebSocket and history ingress share `IncomingOutgoingDisposition`: unrelated messages use normal reducers; consumed deliveries belong to queue events; suppressed messages cannot replace pending intent or cancelled content. `delivered`, `updated` and `deleted` events reuse existing timeline/list/reply-redaction handoffs without recursively re-entering ingress. Session-scoped completed-deletion identities suppress held responses after durable tombstone removal.

Local cancellation also suppresses a previously visible confirmed identity, including while DELETE is held or failed. `ConversationMessageStore` retains conversation-scoped cancelled client IDs until reset; timelines omit both versions and list-cache previews redact content without changing canonical deletion, read or pin state. Later list/history updates cannot restore that content. Account retirement drains finite repository operations and registered item transitions before reopening storage, but never waits for cancelled network transports; their byte leases remain valid until completion.

PATCH claims capture exact text, ordered attachment IDs and revision; replay a persisted claim before newer intent. DELETE succeeds on 404/410 as well as normal success. Cancelled unknown creates are never resent merely to discover a server ID. Audio deletion waits for actual publication, with foreground/reconnect message probes rather than assuming the initial create response means publication. Failed recall remains hidden with a reachable Retry above the composer. Known server results recover local acknowledgement persistence instead of reissuing a completed create.

## Native preparation and durable files

Unsent media lives under the account's Application Support directory, in `Outbox/<slot UUID>/`, not the evictable media cache. Database paths are relative to the account directory and resolve when loaded, including after container relocation. Imports reject external/symlink/nonregular references. Files are atomically installed before committing their database references.

The persisted `compressionEnabled` option selects the current fixed preparation policy:

- Disabled: upload the validated original.
- Enabled: preserve orientation and aspect ratio without upscaling or cropping. The compressed candidate simultaneously caps the short side at 1400 pixels, area at 8,000,000 pixels and long side at 16000 pixels, with dimensions floored. Prefer bundled libwebp, then JPEG for opaque pixels or PNG for transparent pixels. WebP quality is 0.6; JPEG quality is 0.8. Failed codecs fall through without flattening transparency; no AVIF encoding is attempted. Replace the original only if the selected result is less than 75% of its byte size; otherwise retain the original bytes and dimensions. Original inputs, including AVIF, and existing prepared checkpoints retain their formats.
- Multi-frame images retain their original bytes rather than flattening animation.
- Videos retain their original bytes regardless of this option. AVFoundation validates playable video and extracts an oriented preview; container extensions are normalized from file headers before loading.
- Local previews use an oriented thumbnail up to 480 pixels; preparation records actual output MIME type, dimensions and byte count.

Changing compression while blocked invalidates prepared/uploaded work and reprocesses the original. Prepared checkpoints survive restart. Any future algorithm change must explicitly account for persisted unprepared work; the current option is a Boolean, not a versioned policy registry.

`Shared/StillImagePreparation.swift` supplies the same still-image policy to the app and iOS Share extension. The extension defaults **Compress images** on and retains acquired provider originals for opt-out. Changing this option cancels the current work, clears uploaded attachment IDs and starts preparation/upload for the new setting; late completions cannot replace the current IDs. The server size limit applies after image preparation, including when an oversized source can shrink below the limit. Videos retain their acquisition-time limit and original bytes. Extension files are temporary rather than durable outbox entries.

Cleanup retains the union of files needed by composition, latest durable intent, active create/upload work and editor leases, with the existing grace period for unreferenced account-owned files. Deselecting borrowed editor media does not stop the outgoing item's uploads; cancelling an editor releases only its own imports. Successful submit transfers selected imports into durable intent before releasing the lease. Missing referenced files remain attachment errors, never silent omission.

Recovery resumes from durable boundaries:

- Interrupted preparation starts again from the original.
- Interrupted or failed PUT retries the same prepared file with a fresh allocation.
- Completed PUT checkpoints reuse the uploaded ID.
- Released items restore to the pending timeline; blocked items restore to composition and never auto-release.
- Claimed sends retain frozen creates; confirmed mutations retain their exact claimed PATCH or hidden DELETE intent. No cancelled unknown create becomes dispatchable.
- Restart has no editor leases: clean confirmed rows hand off/finalize, pending mutations remain, and incomplete editor workspaces are reclaimed.
- Account changes invalidate editors/workers, advance generations and activate the destination account's own repository and files.

## Backend protocol and deployment limits

1. `GET /attachments/config` returns `maxFileSizeBytes`, checked against the prepared file.
2. `POST /attachments/upload-url` sends filename, contentType, size, purpose `media`, order, width and height.
3. The response supplies attachmentId, uploadUrl and uploadHeaders; allocation URLs currently expire after 15 minutes.
4. PUT uploads the file with those headers. The uploader excludes API bearer credentials, cookies and redirects.
5. The existing chat/thread message endpoint receives the caption and ordered attachmentIds.

Every unresolved upload retry allocates a new ID, including after HTTP 403 or restart. There are no allocation expiry checks or persisted upload URLs. A lost PUT response or local success checkpoint can therefore cause the bytes to be uploaded again under another ID. This deliberately trades extra remote orphans for simpler recovery: the backend has no client allocation idempotency key or explicit renew/delete-unattached endpoint. Completed slots are reused, and claimed message requests never replace their attachment IDs.

The final message `attachmentIds` sequence is authoritative. Chat/thread creation and message PATCH persist its ordinals into attachment `order` while associating the existing IDs; metadata is then sorted by stored `order` and ID. Allocation-time `order` is only an initial hint and may become stale during preparation or PUT. The composer supports up to 20 attachments.

**Coordinated backend and Apple deployment is required for reorder reuse.** Deploy the backend's authoritative association-order handling before enabling this Apple behavior. Older servers retain allocation-time order and cannot honor reordered existing IDs through another endpoint; an Apple-only deployment would silently deliver the wrong order. No new backend endpoint or backend schema migration is needed. The PWA's existing removal/reuse behavior does not establish reorder support: its composer has no reorder operation.

Message replay uses the backend's client-generated-ID conflict handling, which checks chat, sender, text, type, reply and the ordered attachment IDs. The client retains the exact sealed request across uncertain delivery; replaying the same ID with another attachment order conflicts rather than changing the delivered message. This is not an exactly-once attachment-allocation guarantee, nor a guarantee of remote orphan cleanup or indefinite unattached retention.

## Presentation and verification

The shared SwiftUI composer accepts photos and videos through Photos, Files, clipboard acquisition and drag/drop. Attaching media opens `ComposerAttachmentDialog`: a fixed count/close/options header, large scrollable previews and a fixed caption/send row. Per-item menus provide retry, removal and reordering; the header menu contains one image-compression option for the entire selection. Videos are sent unchanged. macOS also installs `onPasteCommand`; iOS uses `PasteButton` in the attachment menu.

During ordinary composition, the caption edits the existing conversation draft. Closing with X atomically discards the blocked composition's attachment slots while preserving caption and reply text; dismissal waits for persistence, and failure leaves the sheet open with an error. Imports and attachment mutations share a conversation lock, and retired-slot checkpoints cannot restore discarded media. Interactive sheet dismissal is disabled so it cannot bypass this abort. Successful durable release clears the draft and dismisses without cancellation. The inline review button remains available for drafts restored after navigation or restart, not as the result of closing with X. Queued editing instead binds these controls to the leased session described above.

On macOS, the caption uses a native scrolling text view that grows from one to six lines and confines longer text to its own viewport. The sheet and gallery do not scroll with the caption. The main composer and caption request keyboard focus once on enabled entry, placing the caret at the restored draft's end instead of selecting all text. Delayed permission loading cannot reclaim focus after intervening user input; ordinary updates do not reset selection or marked text.

On iOS, the caption/send row reserves a bottom safe-area inset above the software keyboard. The remaining gallery viewport can shrink without a minimum height, and image/backdrop layers are explicitly bounded so portrait media cannot push the editor offscreen. Single previews aspect-fit and remain centered. A Hide keyboard control resigns the caption editor without discarding text; closing the sheet does not automatically refocus the underlying chat editor.

The full chat detail pane and caption dialog accept additional media drops. `ComposerAttachmentState` shares acquisition/error state and hands pane drops to the existing composer import transaction, preventing duplicate batches while a drop or import is pending. Gallery drags use an own-process slot type rather than image/file URLs, so moving a tile never imports it again. Hover shows an insertion edge and can scroll the gallery; only a validated drop commits a complete new order. Gallery/session/membership checks reject stale or foreign payloads, and cancelled/no-op drags do not change the queue.

IME composition does not toggle control availability. Submission checks native marked text and the current composition boundary. On macOS, plain Return is intercepted before AppKit ends field editing, avoiding the select-all flash caused by restarting the editor. Candidate-confirmation Return remains native; Shift-Return inserts a newline with native selection and undo behavior.

Pending bubbles render ordered local/server intent slots through the shared native media layout and offer Edit for writable nonforwarded text/media, and Recall for any writable queued type, including middle and claimed items. Local and delivered attachments retain common placement/tile chrome, caption spacing and media-only metadata overlays. The pending editor reuses the existing gallery/dialog for media import, removal and reordering; uploaded server slots have no compression/upload retry work. Files, voice and stickers remain unavailable in edit mode. Close cancels directly; changed pending edits use the shared discard decision on Escape.

The shared sticker picker shows favorites and deduplicated owned/subscribed packs in a 260-point panel with a bottom pack strip. Selecting a sticker sends immediately through the outbox without consuming typed text or attachments. Timeline sticker taps open a shared pack sheet; selecting another grid item changes the preview rather than sending. `StickerLibrary`, owned and reset by `ChatStore`, shares favorite/subscription state, applies account pack ordering and fences stale loads and mutations. Unsubscribed pack details remain browsable in an open sheet.

Sticker images use the existing bounded account media cache. A single guarded request supplies drawable first-frame pixels and lazy ImageIO GIF/WebP animation; animation cache identity does not depend on thumbnail size, and a cached first frame survives resizing and view recreation. Availability means actual pixels, not merely an image container. Pending media without cached pixels shows a spinner; terminal download/decode failures show an error only when no usable frame remains. Native scroll visibility observation resumes lazy cells that first appeared outside the viewport.

WebM previews use noninteractive WebKit video with signed URLs preserved and an account-scoped nonpersistent data store. Offscreen playback pauses without discarding the document; recreated views display a poster from the same bounded image cache while playback loads. Cold previews use a native spinner rather than clipped loading text. iOS/iPadOS 17.0–17.3 show an explicit unsupported-version error because [WebKit added WebM support in 17.4](https://webkit.org/blog/15063/webkit-features-in-safari-17-4/#media). VP9-alpha compositing remains subject to [WebKit's platform limitation](https://bugs.webkit.org/show_bug.cgi?id=275908).

Verification performed for this implementation:

- Local persistence regression tests: account relocation/isolation, migration, ordered checkpoints, stale-generation rejection, FIFO, concurrent release/claim/revoke and sticky claims.
- macOS app tests, including composer focus/IME and queue acknowledgement/retry behavior.
- iOS Simulator build of the shared composer and native acquisition integration.
- Sticker regressions: persisted snapshots, parent/thread routing, failed-send restart/retry, typed draft and attachment preservation, reply consumption, and sticker edit/revoke boundaries.
- Native sticker loopback smoke: picker activation, pending sticker opening by real sticker ID, pack browsing after unsubscribe, refresh/mutation races, failed mutations, account-reset fencing, WebM playback/pause and broken-media rendering.
- Native media regressions cover held loading, drawable error states, GIF/WebP frame movement, memory/disk remounts, resizing, stale callbacks, account isolation, and scroll-driven acquisition. A loopback WebM smoke verifies offscreen pause, retained-document resume, and immediate cached-poster remount.
- Throwaway loopback smoke using the real queue, ImageIO processor, URLSession uploader and SQLite store: release during preparation, failed PUT/retry, ordered bytes/IDs and FIFO delivery, revocation during upload, uncertain message replay, and restart of a blocked image-only thread draft.
- Fresh-allocation retry smoke: HTTP 500, restart, HTTP 403 and successful PUT used three distinct IDs with identical prepared bytes. Only the successful ID was dispatched; uncertain message replay after another restart allocated nothing and retained the sealed request.
- Native caption-dialog smoke with controlled submission outcomes: carried draft text, preserved caption on cancellation/failure, cleared caption and dismissal on success, and 20-item scrolling without moving the caption row. Three-item and scrolled-gallery rendering inspected on macOS.
- Generated landscape MP4 and rotated portrait MOV imported/prepared with correct display dimensions, decodable previews and byte-identical originals under both image-compression settings; image preparation also produced a decodable result.
- Pending-media smoke: local/delivered sizes and gallery cells match for 1, 2, 3, 6, 7 and 20 attachments; inspected the rendered pending gallery and hollow metadata checkmark.
- Provider/state smoke: pane acquisition opened the caption and appended subsequent media without losing its draft; reorder payloads committed once, rejected stale/foreign membership and skipped no-op/cancelled changes. Edge-hover scrolling stopped on exit. End-to-end pointer-driven drag verification was blocked by macOS input-posting permission and remains a manual check.
- Still-image smoke: shared preparation produces decodable WebP for opaque and transparent images, preserves alpha and color, and retains sizing and original-byte opt-out. Native JPEG/PNG encoders also roundtrip correctly. Chromium smoke exercises the matching PWA policy, verifies WebP is the first attempt, and exercises JPEG/PNG fallbacks with WebP unavailable.
- Share-model loopback smoke: oversized source compresses below the upload limit, opt-out uploads hash-identical provider bytes, rapid option changes discard stale IDs, and switching during a held PUT prevents its late completion from replacing the current upload. The actual shared SwiftUI view was rendered on a macOS host; physical-device Share-sheet interaction remains manual.
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
