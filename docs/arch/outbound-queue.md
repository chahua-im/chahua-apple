# Outbound queue architecture

The main app owns this outbox. The Share extension sends directly and is outside app FIFO ordering.

## Ownership

`AppCompositionRoot` owns one `AccountLocalStoreOwner`, shared by the queue and account-local readers. Its `chat.sqlite` is scoped by API base URL and user ID. The database holds drafts, submitted work and the [offline cache](offline-cache.md). Only a positively unrecognized applied migration permits a reset during open; ordinary history clear does not delete drafts or submissions. A published send installs its canonical message and removes the outbox row in one transaction.

`draft` stores the current composition by `(chat_id, thread_id)`, including text, reply, link inputs, attachments and compression. `outgoing_message` stores submitted work by client-generated UUID and unique conversation position. An empty SQL thread ID denotes the parent chat. The draft is independent of FIFO; submission moves its current attachment slots and clears the draft in one transaction. File plus caption inserts adjacent file and text entries. Notification replies, forwards, voice and stickers do not consume or reorder a draft.

The v10 migration discards legacy drafts and outbox entries once, including interrupted sends and pending edits/recalls. It keeps the database, credentials, media caches and other accounts intact. A discarded uncertain send may already exist on the server. Unreferenced files under the account's `Outbox/` directory are reclaimed through the normal cleanup path.

## Scheduling and editing

The lowest position always owns the conversation's next create. It blocks successors while preparing, held by an editor, sending or failed. Other conversations progress independently. One database constraint prevents more than one Sending row per conversation. Uploads may run ahead of their create position under shared preparation/upload bounds.

| Visible phase | Durable state | What the user can do |
|---|---|---|
| Preparing | Pending, unresolved attachments | Edit ordinary text/media and remove the local entry |
| Queued | Pending, ready for claim | Edit ordinary text/media and remove the local entry |
| Sending | Sending | Wait for the active attempt; no edit or removal |
| Failed | Failed with typed stage and reason | Retry or remove; preparation failures can also be corrected in the editor |

Voice, stickers and forwards are immutable. An editor takes a synchronous lease before presenting editable content, keeping its item out of the create and new upload schedulers. Matching in-flight checkpoints merge without changing the selection. Reorder keeps completed IDs; source and compression changes retire the prior generation. Saving commits before releasing the hold; closing without saving keeps the original. No queued edit is translated to a server PATCH. **Remove from Outbox** discards only local intent, never recalls a message from the server.

The main actor orders edits, claims and snapshot publication. SQLite orders transactions. Draft watermarks, snapshot revisions, editor holds, progress and local backoff attempts live in session memory. Each server retry deadline is stored with its submitted row or attachment slot. Account transitions fence old workers and callbacks.

## Handoff and recovery

An offline head remains pending if no create was handed off. A claimed request is immutable across retries, including its ID, attachment IDs, reply and link inputs. Process death or background expiration after the claim records or restores a failed create with unknown outcome. Network failures and HTTP 408, 429 and 5xx can retry on bounded exponential backoff, honoring `Retry-After`; validation, permission and unstructured conflicts require user action. Retry claims failed creates directly, without an editable interval. Authentication failure stops sending but does not purge local work.

A matching HTTP success, authenticated publication or structured `clientGeneratedIdConflict` settles the row. Client ID, sender, chat and thread must all match. A published server copy and the removal of the local row commit together before publication in the timeline and list. Late responses cannot recreate local work. Accepted unpublished audio frees FIFO and keeps only an in-memory processing bubble until canonical audio publication.

Background delivery uses the same dispatcher and first-in, first-out rules. On macOS eligible heads can run without an active window. On iOS they can run in the foreground, during a finite app grant, or during a scheduled app refresh. The grant can drain eligible heads across conversations, but cannot bypass a blocked head or work on an unsubmitted draft. A refresh request exists only for automatically actionable submitted work. Expiration returns a claim known not to have reached the transport to its previous state; a handed-off create retains its original ID and is treated as uncertain. iOS decides when it grants time. Confirmed sign-out purges that account’s local work; expiration of credentials and account switches do not.

## Native preparation and durable files

Unsent media lives under the account's Application Support directory, in `Outbox/<slot UUID>/`, not the evictable media cache. Database paths are relative to the account directory and resolve when loaded, including after container relocation. Imports reject external/symlink/nonregular references. Files are atomically installed before committing their database references.

The persisted `compressionEnabled` option selects the current fixed preparation policy:

- Disabled: upload the validated original.
- Enabled: preserve orientation and aspect ratio without upscaling or cropping. The compressed candidate simultaneously caps the short side at 1400 pixels, area at 8,000,000 pixels and long side at 16000 pixels, with dimensions floored. Prefer bundled libwebp, then JPEG for opaque pixels or PNG for transparent pixels. WebP quality is 0.6; JPEG quality is 0.8. Failed codecs fall through without flattening transparency; no AVIF encoding is attempted. Replace the original only if the selected result is less than 75% of its byte size; otherwise retain the original bytes and dimensions. Original inputs, including AVIF, and existing prepared checkpoints retain their formats.
- Multi-frame images retain their original bytes rather than flattening animation.
- Videos retain their original bytes regardless of this option. AVFoundation validates playable video and extracts an oriented preview; container extensions are normalized from file headers before loading.
- Local previews use an oriented thumbnail up to 480 pixels; preparation records actual output MIME type, dimensions and byte count.

Changing compression in a draft or pre-send editor invalidates affected prepared/uploaded slots. Prepared checkpoints survive restart. A future algorithm change must account for persisted unprepared work; the current option is a Boolean, not a versioned policy registry.

`Shared/StillImagePreparation.swift` supplies the same still-image policy to the app and iOS Share extension. The extension defaults **Compress images** on and retains acquired provider originals for opt-out. Changing this option cancels the current work, clears uploaded attachment IDs and starts preparation/upload for the new setting; late completions cannot replace the current IDs. The server size limit applies after image preparation, including when an oversized source can shrink below the limit. Videos retain their acquisition-time limit and original bytes. Extension files are temporary rather than durable outbox entries.

Cleanup retains files referenced by drafts, submitted rows and editor leases, and waits for active file work. A grace period covers pending-to-server preview handoff. A cancelled editor's unsubmitted imports are unreferenced; a saved edit transfers its selected slots into durable intent. A missing referenced source fails preparation rather than silently omitting it.

Each allocation and PUT is one attempt. The uploader checkpoints its attachment ID only after a successful PUT, keyed by slot ID and generation. Unresolved work can allocate again; completed slots reuse their IDs. Reordering uses the latest durable positions, not upload completion order.

## Backend protocol and deployment limits

1. `GET /attachments/config` returns `maxFileSizeBytes`, checked against the prepared file.
2. `POST /attachments/upload-url` sends filename, contentType, size, purpose `media`, order, width and height.
3. The response supplies attachmentId, uploadUrl and uploadHeaders; allocation URLs currently expire after 15 minutes.
4. PUT uploads the file with those headers. The uploader excludes API bearer credentials, cookies and redirects.
5. The existing chat/thread message endpoint receives the caption and ordered attachmentIds.

Every unresolved upload retry allocates a new ID, including after HTTP 403 or restart. There are no allocation expiry checks or persisted upload URLs. A lost PUT response or local success checkpoint can therefore cause the bytes to be uploaded again under another ID. This deliberately trades extra remote orphans for simpler recovery: the backend has no client allocation idempotency key or explicit renew/delete-unattached endpoint. Completed slots are reused, and claimed message requests never replace their attachment IDs.

The final message `attachmentIds` sequence is authoritative. Chat/thread creation and message PATCH persist its ordinals into attachment `order` while associating the existing IDs; metadata is then sorted by stored `order` and ID. Allocation-time `order` is only an initial hint and may become stale during preparation or PUT. The composer supports up to 20 attachments.

Deploy backend association-order and scoped conflict support before the Apple cutover. Older servers cannot guarantee reordered attachment IDs, and a bare 409 cannot confirm delivery to the app. Neither backend behavior requires a schema migration.

Message replay is idempotent at the server by client-generated ID. A safely visible conflicting server copy does not imply that the newly submitted content was accepted. This does not guarantee idempotent attachment allocation, cleanup of remote orphans, or indefinite unattached retention.

## Composer integration

The shared SwiftUI composer accepts photos and videos through Photos, Files, clipboard acquisition and drag/drop. Attaching media opens `ComposerAttachmentDialog`: a fixed count/close/options header, large scrollable previews and a fixed caption/send row. Per-item menus provide retry, removal and reordering; the header menu contains one image-compression option for the entire selection. Videos are sent unchanged. macOS also installs `onPasteCommand`; iOS uses `PasteButton` in the attachment menu.

The attachment caption edits the ordinary conversation draft. Closing with X durably discards its slots while preserving caption and reply. Dismissal waits for the transaction; if it fails the sheet remains open. Successful submission moves the draft's slots into the outbox. Queued editing reuses these controls against the leased selection instead of touching the ordinary draft.

On macOS, the caption uses a native scrolling text view that grows from one to six lines and confines longer text to its own viewport. The sheet and gallery do not scroll with the caption. The main composer and caption request keyboard focus once on enabled entry, placing the caret at the restored draft's end instead of selecting all text. Delayed permission loading cannot reclaim focus after intervening user input; ordinary updates do not reset selection or marked text.

On iOS, the caption/send row reserves a bottom safe-area inset above the software keyboard. The remaining gallery viewport can shrink without a minimum height, and image/backdrop layers are explicitly bounded so portrait media cannot push the editor offscreen. Single previews aspect-fit and remain centered. A Hide keyboard control resigns the caption editor without discarding text; closing the sheet does not automatically refocus the underlying chat editor.

The full chat detail pane and caption dialog accept additional media drops. `ComposerAttachmentState` shares acquisition/error state and hands pane drops to the existing composer import transaction, preventing duplicate batches while a drop or import is pending. Gallery drags use an own-process slot type rather than image/file URLs, so moving a tile never imports it again. Hover shows an insertion edge and can scroll the gallery; only a validated drop commits a complete new order. Gallery/session/membership checks reject stale or foreign payloads, and cancelled/no-op drags do not change the queue.

IME composition does not toggle control availability. Submission checks native marked text and the current composition boundary. On macOS, plain Return is intercepted before AppKit ends field editing, avoiding the select-all flash caused by restarting the editor. Candidate-confirmation Return remains native; Shift-Return inserts a newline with native selection and undo behavior.

Pending and delivered attachments share their layout, gallery and caption treatment. Pending bubbles show the derived phase and per-slot progress instead of server actions. Delivered messages use normal online actions.

The shared sticker picker shows favorites and deduplicated owned/subscribed packs in a 260-point panel with a bottom pack strip. Selecting a sticker sends immediately through the outbox without consuming typed text or attachments. Timeline sticker taps open a shared pack sheet; selecting another grid item changes the preview rather than sending. `StickerLibrary`, owned and reset by `ChatStore`, shares favorite/subscription state, applies account pack ordering and fences stale loads and mutations. Unsubscribed pack details remain browsable in an open sheet.

Sticker images use the existing bounded account media cache. A single guarded request supplies drawable first-frame pixels and lazy ImageIO GIF/WebP animation; animation cache identity does not depend on thumbnail size, and a cached first frame survives resizing and view recreation. Availability means actual pixels, not merely an image container. Pending media without cached pixels shows a spinner; terminal download/decode failures show an error only when no usable frame remains. Native scroll visibility observation resumes lazy cells that first appeared outside the viewport.

WebM previews use noninteractive WebKit video with signed URLs preserved and an account-scoped nonpersistent data store. Offscreen playback pauses without discarding the document; recreated views display a poster from the same bounded image cache while playback loads. Cold previews use a native spinner rather than clipped loading text. iOS/iPadOS 17.0–17.3 show an explicit unsupported-version error because [WebKit added WebM support in 17.4](https://webkit.org/blog/15063/webkit-features-in-safari-17-4/#media). VP9-alpha compositing remains subject to [WebKit's platform limitation](https://bugs.webkit.org/show_bug.cgi?id=275908).

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

Backend references: sibling `chahua/backend/src/handlers/attachments.rs`, `services/messages.rs`, and `services/api/chats/messages.rs`.
