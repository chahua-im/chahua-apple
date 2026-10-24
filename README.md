# Chahua iOS

See the [setup guide](docs/setup.md) to prepare a development environment and sync signing assets.

## Profiling builds

Select the shared **chahua-apple Profile** scheme and use **Product → Profile** (⌘I) with a physical iOS device or **My Mac**. Both Run and Profile use the `Profile` configuration: Swift `-O` with whole-module compilation, C/Objective-C `-Os`, and matching dSYMs. The app and iOS share extension use the existing `match Development` provisioning profiles and development signing; push entitlements use the development APNs environment. Signing assets must be installed locally. Archive still uses `Release` for distribution.

The scheme enables `-scroll-profiling` and passes its launch arguments to Instruments. Disable that argument for an uninstrumented comparison. Use **Product → Profile**, rather than Run with the LLDB debugger attached, for performance measurements.

## Architecture decisions

- [Why SwiftUI is not ready for this complex chat scroll host](docs/arch/swiftui-scroll-host-evaluation.md)

## Conversation timeline

iOS and macOS group consecutive non-system messages from the same sender within a calendar day, regardless of the time between messages. A date separator, unread separator, system message, or sender change starts a new group. The sender name appears on the first bubble of a group where sender names are enabled; the avatar appears on the final bubble. Base vertical gaps are 4 points within a group and 8 points between groups. Plain headerless text bubbles size to their contents rather than the avatar height; their single-line text is centered using painted glyph bounds, with the inline timestamp kept lower. A row reserves any extra avatar clearance outside a compact bubble so avatars cannot overlap neighboring rows.

Outgoing published messages show a single checkmark when sent and double checkmarks when read by the DM peer. Receipts are reciprocal and server-authorized; group conversations do not show read receipts. Main-conversation and thread read positions are independent, including the main-conversation root displayed in a thread. Scoped `readReceiptChanged` events refresh only the affected peer cursor; self-reader advances are ignored, while privacy revocation clears every affected cached scope immediately. Requests coalesce and stale responses cannot restore revoked receipts. Healthy foreground activation retains successful receipts; reconnects and failed queries still refresh.

**Settings → Privacy and Security → Read Receipts** controls sharing with friends or nobody. A friend's DM information screen offers **Use global setting**, **Share with this friend**, and **Hide from this friend**. Choices save automatically; failed loads and saves offer Retry.

Manual verification: with two friend accounts allowing receipt sharing, send a DM from Apple and open it in the PWA; the sent checkmark should become double. Repeat with a thread reply and confirm reading the parent conversation alone does not mark the reply read. Hide sharing on either account and confirm double checkmarks disappear; restore sharing, reconnect/foreground the Apple client, and confirm authorized receipts return. Group messages should remain single-checkmarked.

`MessageDeliveryStatusView.swift` is the shared SwiftUI delivery indicator used by production iOS/macOS timelines and the light/dark Canvas previews. Queued messages show a clock, sending messages animate a small spinner, sent messages show a single check, and read messages show nested double checks with default separation 0.3. The check ink matches the timestamp digit height and baseline without changing spinner size or the reserved status slot. Native rows host only this component; timestamps retain native drawing and retry targets retain their existing interaction/accessibility behavior. All outgoing states reserve the same status width to avoid timestamp and text reflow; hidden/reused hosts remove the animated subtree.

Chat-list previews show the outgoing message's delivery indicator immediately before the timestamp, using the same status renderer as the timeline. A saved draft hides that indicator. Incoming, system, and deleted message previews do not show it; double checks require an authorized receipt for that exact DM or DM-thread scope.

Manual verification: send a message while the list is visible, then open it from the peer account and confirm the list changes from a single to a double check. Repeat for a DM thread and a group, and confirm the group never shows double checks. Save a draft and confirm it replaces the preview without a delivery indicator; remove the draft to restore the message status.

Bubble timestamps use the smaller caption style (11 points at the standard iOS text size), with a 2-point timestamp/status gap. Outgoing timestamps are muted to 60% opacity while checks remain fully opaque; media overlays use 85% timestamp opacity for legibility. The footer extends 2 points lower and farther right than the body text at the default timestamp size, scaling with text size. Body wrapping retains its original width, and native text views install that body width independently from the footer's full drawing bounds.

When a text-only bubble's timestamp needs its own row, its width contracts to the actual text/footer and any header, reply, or thread content instead of retaining the failed inline reservation. Compaction cannot add a body line; media bubbles retain their media-driven width. Widening the timeline restores inline timestamps when they fit.

The workshop renders the production Core Text timestamp and fitted status frame, with controls for timestamp size, spinner stroke, check separation, symbol weight, and a **Play** sequence from queued through read. Open **Message status workshop** in the Debug component gallery or launch with `-message-status-preview`; neither route starts authenticated services.

Message actions offer **Reactions** for published messages with reactions. On iOS and macOS, the sheet loads the full reactor list and uses horizontally scrollable emoji/count tabs with an accent underline above compact avatar/name rows. **All** groups reactions by person; up to eight populated emoji groups get individual tabs, and **More** contains the remaining populated groups. Zero-reaction groups are omitted; an entirely empty response shows the empty state. Reactor rows do not open profiles. Loading failures offer Retry.

On iOS and macOS, message actions include **Forward** and **Select**. Selection captures up to 100 nondeleted, nonsystem messages with server IDs, including acknowledged audio still processing; invites and nested records remain selectable but are validated when forwarding. Tap or click a row to toggle its right-side circle/checkmark. The composer is replaced by Delete, count, Cancel, and Forward controls; zero disables Forward. Bulk deletion requires write permission and ownership/admin authority for every selected message, runs sequentially, and retains uncompleted selections on failure. Selection survives pagination, preserves the composer draft, and clears when leaving the conversation. Links, media, reactions, and reply gestures are inactive while selecting.

Forwarding one message preserves its content type with flattened source attribution and an inert original-reply preview; stickers and forwarded-message cards omit that extra attribution. Forwarded text cannot be edited. Forwarding multiple messages creates one **Forwarded Messages** card with the first three author summaries and total count. The shared destination picker mixes nonarchived chats and subscribed threads by recent activity, searches loaded titles/root text, and offers independent paging/retry. Enqueueing stays in the source conversation; the destination's existing durable outbox owns ordering, confirmation, failure, and stable-key retries without modifying its draft.

Opening a card pushes a **Forwarded Messages** page onto the conversation's existing navigation stack; nested cards push another page. Back returns one level at a time, preserving the parent page and the source conversation's message window, scroll position, and draft. The destination picker remains a sheet. Forwarded-message details reuse `ConversationTimelineView`/`ConversationTimelineModel` with a captured-only message source and dedicated message store. Grouping, dates, media, audio, reply previews, and nested cards use the production timeline. Internal replies jump only within the immediate bundle; external replies show `[Redacted]` without fetching source content. Details have no composer, message menus, mutations, or profile/link navigation. Nested reads retain the original wrapper/saved-row authority, and chat-root deletion or access loss invalidates cached content and in-flight results.

`placeholder` is a distinct message type: `pendingAudio` displays `[Pending voice message]`, `nestedForward` displays `[Forwarded Messages]`, and unknown reasons display `[Unavailable message]`. Placeholders have no media or expandable child and never expose their reason code as copyable text. Pending audio and over-nested merged cards require explicit replacement confirmation; already captured placeholders need no new confirmation. Thread headers offer forwarding when root plus replies fit within 100 messages, then reread the current full thread at destination selection.

Manual verification: forward a single text/image/sticker and a multi-selection to both a chat and a thread. Check source attribution, first-three card previews, detail grouping, media, internal reply jumps, external redaction, nested Back navigation, and placeholder localization. Confirm forwarding preserves both source and destination drafts, selection survives pagination, zero disables Forward, and partial bulk-delete failure retains remaining items. Exercise offline retry, pending-audio and deep-nesting confirmation/cancellation, deletion while the picker/detail is open, reconnect/account switching, and whole-thread forwarding as its count crosses 100.

Unread activity mirrors the PWA: `@` combines mentions and replies to your messages in groups and group threads; a heart marks unread reactions in any conversation. Chat/thread rows show these symbols beside the unread-message badge, muted or archived rows use subdued badges, and category tabs prioritize `@` using server-wide summaries rather than loaded rows.

Both production timelines share `TimelineNavigationControls`: stacked heart/`@` buttons above jump-to-latest, with counts capped visually at `999+`. Each click visits the oldest remaining target. Session targets survive counter clearing; missing/deleted targets are skipped and transient navigation failures remain retryable. Main chats and threads keep independent queues. Entry and reconnects refresh activity; healthy visibility restoration reuses successful snapshots and known-zero counters. Directed realtime changes coalesce follow-up reads without losing changes received during a request.

Mentions/replies clear through the existing visible-message read cursor. Reactions use a separate cursor: foreground entry acknowledges the exact queried snapshot boundary, while foreground navigation away acknowledges the conversation once more. Backgrounding does not acknowledge reactions; cancelled or old-account responses cannot revive queues or issue late acknowledgements.

Manual verification: from a second account, mention you and reply to one of your messages in a group, then react to one of your messages. Confirm `@`/heart row badges and the tab's `@` priority; open the group and use both jump buttons until their targets are exhausted. Repeat in a group thread and confirm parent activity stays independent. In a DM/thread, reactions should work without an `@` button. Background and reconnect Apple while new activity arrives, then confirm foregrounding restores the targets. Repeat with muted and archived conversations and verify subdued row badges without an active unmuted tab-attention badge.

Unread tab/archive summaries and the app-icon badge come from `watchConversationUnread`, not the removed HTTP summary endpoint or a sum of loaded pages. Visible list rows and open timelines share `watchConversationStates` (up to 512 distinct chat/thread scopes). Absolute full and partial snapshots update counters and read cursors; request IDs fence old subscriptions/accounts, while scoped versions fence read acknowledgements without restarting healthy watches. Known read cursors suppress equal or older acknowledgements even outside the loaded message window. Unwatched scopes or unavailable state snapshots use the chat/thread read-state GET endpoints; an ambiguous lower cursor after a local acknowledgement uses a scope-only read to resolve a possible mark-unread or deletion rewind. Background scenes release watches; foreground scenes replace them with fresh request IDs. A healthy socket retains event-maintained lists and message windows; actual reconnects reconcile them. See [visible-message read progress](docs/arch/realtime-messaging.md#visible-message-read-progress) for watermark and rewind behavior.

Message events update known previews directly. Membership, archive, and deletion reconciliation use targeted `chatId`/`rootId` list queries rather than reloading unrelated pages. Thread membership events carry absolute subscription/archive status; ordinary reply updates do not invalidate a known subscription.

Manual verification: read a chat and a thread in the PWA while Apple shows their list rows; confirm counts and the system badge update without switching tabs. Send messages while Apple is backgrounded, return with a healthy connection, and confirm previews/targets remain available without a full-list loading cycle. Repeat after a real disconnect, archive/unarchive and subscribe/unsubscribe from the PWA, then switch accounts while updates are pending; old snapshots must not restore counts or memberships.

The image viewer header shows Back, the chat/thread name above the message timestamp, and an overflow menu containing only **Save Image**. iOS requests add-only Photos access and saves the original image file; macOS uses a native Save panel with user-selected read/write access. Saving has no progress/status message, prevents duplicate requests, and reports success or failure with a transient accessible toast. Canceling the Save panel is silent. Video saving is not included.

## Scrolling performance

The shared chat list memoizes its ordered items and conversation-state references using complete chat/thread payloads, scope/archive preferences, and draft activity. Unrelated store or swipe-state updates reuse that projection; stable-ID edits, badges, membership changes, and draft removal still invalidate it. Genuine changes build one projection buffer and sort it in place, without intermediate filtered or decorated arrays.

DM avatar mount/unmount changes use a dedicated transport invalidation stream rather than `ChatStore`'s UI change publisher. Scrolling peers into or out of view updates the presence watch without rebuilding the whole list for unchanged chat data. Accepted server presence snapshots still publish visible state, preserving online dots, overlapping statuses during watch refresh, and last-seen label aging.

Relative list timestamps reuse a main-actor formatter and update its locale when the view environment changes, rather than constructing a formatter for each newly visible row or minute tick.

SwiftUI list, draft, search, and pin summaries use shared `Text` for ordinary formatted previews, with an explicit font/color/style bridge from the canonical Markdown renderer. Only spoiler-bearing SwiftUI summaries create the native TextKit surface required for glyph masks; ordinary rows avoid that extra representable, layout graph, and animation-lifecycle observers. Native timeline quote controls retain their existing renderer. Summary links and mentions remain inert, text selection stays disabled, and accessibility conceals spoilers.

The iOS timeline shares one visible-geometry query per scroll callback. Visibility transitions are separate from clipped-media refreshes, so tall rows suspend offscreen tiles without rebinding text, audio, or interaction handlers. Width/Dynamic Type height settlement scans pending rows incrementally and rebinds newly measured visible rows rather than every visible row on every batch. Viewport/read tracking remains synchronous.

`CADisableMinimumFrameDurationOnPhone` enables the iPhone's full adaptive ProMotion range. UIKit/Core Animation still choose the rate and honor Low Power Mode and thermal limits; the app does not force a constant 120 Hz. Timeline display links remain paused without pending work.

Device verification: use an optimized build and Instruments **Animation Hitches**, **Time Profiler**, and **Power Profiler**. Compare sustained flings through the list and a long conversation, then idle/background behavior; include tall media captions, rotation, accessibility text sizes, selection, and history pagination. Simulator callback timings are not physical-device FPS or energy measurements.

### Capturing scroll traces

Launch an optimized build with the scheme argument `-scroll-profiling`, or environment variable `CHAHUA_SCROLL_PROFILING=1`. This is a launch-time switch supported in Release builds; restart after changing it. Without either switch, the signposter is not initialized and image-completion tracing callbacks are not installed. The instrumentation adds no display link, timer, observable counters, or refresh-rate override.

1. On the affected physical device, select **chahua-apple Profile** and use **Product → Profile** with the **Profile** configuration. Ensure the Profile action uses the profiling argument/environment, and retain the matching app binary/dSYM for symbolication.
2. Record **Animation Hitches** with **Points of Interest**. Filter the latter to subsystem `app.chahua.chat`, category `PointsOfInterest`. Fling through the chat list, repeat over the same rows with warm caches, open a conversation, and repeat there. Include a short idle period. Use a separate **Time Profiler + Points of Interest** capture to attribute expensive intervals; **SwiftUI** can expose repeated view-body updates.
3. Select a hitch interval and correlate it with the markers below. Compare cold and warm passes, and then remove the profiling switch for an uninstrumented device check. Profiling itself adds overhead. At 120 Hz the refresh interval is approximately 8.33 ms, not a guaranteed per-callback CPU allowance.

| Markers | Interpretation |
| --- | --- |
| `List.Snapshot`, `List.SnapshotHit`, `List.ProjectionRebuild`, `List.ProjectionInput` | Projection comparison/reuse versus rebuilding and the input row count. |
| `Presence.ScopeChanged` | A viewport consumer changed the aggregate presence watch; `count=` is its entity count. This transport signal does not publish a UI-state change. |
| `Swipe.Created`, `Swipe.Detached`, `Swipe.Update`, `Swipe.HostContent`, `Swipe.Controls`, `Swipe.SizeFit`, `Swipe.Layout` | iOS row lifetime/churn, content reconfiguration, controls, native hosting measurement, and geometry layout. Repeated fitting is visible separately from content updates. |
| `Summary.Parse`, `Summary.Attributes`, `Summary.Bridge` | Preview projection/parsing, canonical native styling, and conversion to SwiftUI text attributes. These are not full SwiftUI text-layout or draw times. |
| `Image.MemoryLookup`, `Image.MemoryHit`, `Image.MemoryMiss`, `Image.LoadMemory`, `Image.LoadDisk`, `Image.LoadUncached` | Synchronous processed-image lookup and successful Kingfisher completion sources. An uncached result does not necessarily mean a network request; completion events do not measure download or decode duration. Inspect those stacks separately in Time Profiler. |
| `Timeline.Scroll`, `Timeline.VisibleGeometry`, `Timeline.Bind`, `Timeline.ExactLayout`, `Timeline.PreparedHit`, `Timeline.Prepare`, `Timeline.HeightBatch`, `Timeline.HeightsMeasured` | iOS scroll callbacks, visible queries, cell binding, installed-layout reuse/preparation requests, and height-settlement batches. A preparation request can still hit an underlying layout cache. |
| `Timeline.Install`, `Timeline.InstallReset`, `Timeline.InstallIncremental`, `Timeline.RowsRemoved`, `Timeline.RowsInserted`, `Timeline.RowsReloaded` | iOS synchronous snapshot installation, including change computation, native row updates, immediate layout, and anchor restoration. Reset events report the new total row count; incremental events report the requested removal/insertion/reload counts, not how many cells were actually rebound. The interval excludes deferred UIKit batch completion and subsequent display ticks. |
| `Timeline.SettleVisible`, `Timeline.SettlePasses`, `Timeline.SettleHeightChanges` | iOS synchronous visible-row height settlement. Passes include the final pass that finds no remaining height changes; height-change counts sum pending row invalidations before each layout pass, so a row can count more than once. Use these to identify repeated measure/invalidate/layout/restore cycles outside deferred height batches. |

Event occurrence counts expose repeated work; `count=` carries batch/input sizes where applicable. Interval IDs are ephemeral pairing tokens. These app markers contain only fixed operation names and numeric counts, never conversation IDs, message text, names, or URLs. Captures remain local to Instruments; system/framework tracks can contain other metadata, so review a trace before sharing it. Idle should not produce continuous row/layout activity, though incoming data and minute timestamp updates can legitimately do work.

Intervals can nest; their durations are not exclusive CPU time and must not be summed as frame time.

## Markdown rendering

Message bodies and displayed summaries render Markdown automatically on iOS and macOS. There is no rendering preference or composer formatting UI/shortcut support.

`Packages/ChahuaMarkdown` owns the restricted chat grammar, semantic document, single-line summary projection, and syntax-highlight token ranges. It does not depend on `ChahuaAPI` or resolve mention display names. The app inserts names literally, applies native fonts/colors, and owns TextKit layout, navigation, selection, scrolling, and spoiler state. Timeline measurement and display share the prepared document.

Supported syntax is `**bold**`, `__italic__`, `~~strikethrough~~`, `||spoilers||`, backtick inline/fenced code, dash/plus unordered lists, numbered/nested lists, and HTTP(S) links. Headings, blockquotes, tables, horizontal rules, indented code, star bullets, single/triple-star emphasis, tilde fences, raw HTML, and embedded Markdown images are not interpreted as those constructs. Plain messages preserve their original whitespace.

Fenced code preserves source whitespace and scrolls horizontally within its bubble. Explicitly labelled supported languages use bundled highlight.js 11.12.0 grammars through JavaScriptCore; unknown/unlabelled languages, inline code, and summaries remain unhighlighted. No user source is evaluated as JavaScript or installed as HTML. Resource provenance and the upstream license are included in the package.

Code surfaces follow the PWA's surrounding text color rather than an opaque theme panel: inline code uses a 10% tint and fenced blocks an 8% tint. Inline code retains nested bold/italic and link colors; summaries retain their caller's color. Unhighlighted fences inherit the bubble foreground, while highlighted fences use the pinned GitHub/GitHub-dark token palette, including nested token inheritance and diff backgrounds. The PWA's light syntax palette remains unchanged on blue outgoing bubbles; some tokens therefore have lower contrast there. Native code viewports refresh their contextual surface on reuse and appearance changes.

Body links and mentions use the app accent on incoming bubbles and white on outgoing bubbles. Mention backgrounds match the PWA: incoming 10% (self 20%), outgoing 18% (self 28%). Code surfaces and syntax colors resolve against the current light/dark appearance without recreating the message or changing its source.

Body spoilers use fine floating particles without a solid background panel. On macOS, interactive spoilers show a pointing-hand cursor, both concealed and revealed. The first click reveals without activating enclosed links or mentions; clicking revealed ordinary spoiler text hides it again. Concealed text cannot be selected/copied through the native text view. Displayed list, draft, search, pin, thread, and reply/edit summaries retain formatting and concealed spoiler geometry, but embedded links/mentions and spoiler reveal remain inactive so the surrounding action owns the click.

The existing DEBUG `-bubble-timeline` diagnostic includes a rich-text sample at message ID `5`. Set `CHAHUA_FIXTURE_MESSAGE=5` when launching it to inspect formatting, mention fallback, multiline spoilers, nested lists, and long fenced code without authentication or network writes. Check a narrow window/screen and both appearances; body spoilers should reveal/hide, preview spoilers should remain concealed, and horizontal code scrolling should not move the timeline sideways.

## Notifications, camera, and incoming shares

Chat-list swipe actions and group/DM information open the shared **Notification settings** chooser: **Use account default**, **Always notify**, **Always mute**, and temporary mutes for **1 hour**, **8 hours**, **1 day**, or **7 days**. Temporary mute takes precedence, then expires back to the saved exception or account default; it does not clear unread state or change archive membership. Temporary choices are hidden when the underlying preference already mutes the chat.

**Settings → Push Notifications → Direct messages / Groups** controls the two account defaults and their server-counted exception lists. Exceptions support search when adding from active or archived chats, paging, individual removal, and confirmed bulk removal. Changes synchronize across clients; reconnect refreshes defaults, and a single nearest-expiry timer updates mute indicators without polling.

Manual verification: disable a category default, add an **Always notify** exception, temporarily mute it, and confirm expiry restores notifications without changing archive or unread state. Change the same preferences in the PWA, reconnect Apple, and check the list/header and exception counts. Remove an exception and then all exceptions; each chat should return to its category default.

- iOS and macOS message notifications offer **Reply**. The server must send `aps.category: "chahua"`; the separate routing envelope remains unchanged. Replies target the notification's chat/thread through the account-scoped outbox without consuming the open composer draft.
- On iOS, **Take Photo** is available from the attachment menu and attachment preview menu. Capture returns to the existing media preview for an explicit Send; cancellation preserves the draft. Camera access requires a physical device and permission. macOS retains Photos and Files.
- The iOS **Chahua** Share extension accepts text, web links, images, and videos in one unified sheet. Its media preview sits above a searchable grid of recent writable chat and thread avatars; the caption and **Send** stay on that screen with a single destination and no push navigation. Content uploads while the destination is being prepared. Sending replaces the card with a gapped activity ring, then a success checkmark before the share flow dismisses. macOS does not ship a Share extension.
- Failed content acquisition blocks sending rather than silently omitting items. A failed message request retains its destination and idempotency ID for retry.
- Image compression defaults on in the app and Share extension, using the shared [still-image preparation policy](docs/arch/outbound-queue.md#native-preparation-and-durable-files). The app offers **Compress images** in Media options; the Share sheet shows the toggle beside the caption. Turning it off uploads the imported/provider source bytes. Changing it in the Share sheet cancels and replaces previous preparation/uploads before Send becomes available. Animated images and videos retain their original bytes.

The iOS app and extension share the session token through Keychain Sharing, not a shared plaintext file. Open the updated iOS app once to migrate an existing session before using the extension. Register `app.chahua.chat.share` only for iOS and refresh the iOS host/extension provisioning profiles with access to `$(AppIdentifierPrefix)app.chahua.chat.shared`; macOS signing requires only the app profile. Fastlane's iOS signing lanes include both identifiers, while its macOS lanes include only `app.chahua.chat`. Distribution signing and physical-device APNs/camera/share verification require those profiles.

Manual verification:

1. Leave a draft in a chat/thread, reply to its notification while Chahua is backgrounded or cold, and verify delivery to that destination without changing the draft.
2. Capture a photo from each attachment entry point, then exercise cancellation and denied camera permission; nothing should send before confirmation.
3. On iOS, from another app, share a link, text, a photo, and a video. Confirm the unified sheet keeps the preview, search/recent destination grid, caption, and Send together; exercise both chat and thread destinations, offline retry, and sign-out/account switching. For images, verify **Compress images** starts on, then toggle it before and during upload; Send must wait for the current setting, and disabling compression must preserve the provider bytes. Include a long screenshot, a transparent PNG and an animated image. Confirm the sent content in the destination and the brief success check before dismissal.

## Jenkins

| Job | Pipeline definition | Trigger |
| --- | --- | --- |
| `chahua/chahua-apple` (multibranch) | `Jenkinsfile` | Branch/PR checks |
| `chahua/chahua-apple-build` | `ci/Jenkinsfile.apple-build`, SCM branch `main` | Successful main push checks, exact commit SHA |
| `chahua/deploy/apple-appstore-publish` | Separate inline Jenkins pipeline, not stored here | Manual selection of a successful artifact build |

Keep these job paths synchronized with the trigger, upstream allowlist, artifact-copy permission, and publishing build selector if renamed. Branch indexing, manual checks, replays, and timer runs do not trigger artifact builds.

Agents:

- `macos`: macOS 26.5+, Xcode 27, an available iPhone simulator on iOS 26.5+, and rbenv/ruby-build with Ruby compilation prerequisites. Run the agent in a logged-in GUI session for hosted macOS UI tests. No distribution credentials. macOS checks use ad-hoc signing without provisioning-only push entitlements.
- `macos-signing`: a separate trusted agent/user with Xcode 27, rbenv/ruby-build with Ruby compilation prerequisites, and GitHub SSH host keys in `known_hosts`. Never schedule PR code on this agent. Initialize the artifact job's build counter above previously uploaded builds; `CFBundleVersion` uses `BUILD_NUMBER` directly.
- Jenkins plugins: Pipeline (including Declarative, Multibranch, and Build Step), Git/GitHub Branch Source, Credentials Binding, SSH Agent, Copy Artifact, Pipeline Utility Steps, and Lockable Resources.

Install rbenv and ruby-build for the Jenkins agent user. After checkout, both pipelines run `rbenv install -s` to install the version from `.ruby-version` only when missing, then print the Ruby version. Installation is serialized per Jenkins node using a shared Lockable Resources lock. The artifact job then runs `bundle install`. First-time Ruby installation requires network access and may take several minutes; installed versions are reused from the agent user's rbenv directory.

On both Jenkins agents, configure **Node Properties → Environment variables** with `PATH+RBENV` set to `/Users/jenkins/.rbenv/shims:/Users/jenkins/.rbenv/bin:/opt/homebrew/bin:/usr/local/bin`, replacing `/Users/jenkins` with the actual agent user's home directory. Leave `RBENV_VERSION` unset so the shims select the checkout's `.ruby-version`. The pipelines use plain `ruby`/`bundle` commands and do not initialize rbenv or override PATH. Verify after checkout with `command -v ruby`, `ruby --version`, and `rbenv version`.

Credentials on the artifact/publishing jobs:

| ID | Type | Purpose |
| --- | --- | --- |
| `github-app` | Existing GitHub checkout credential | Apple source checkout |
| `apple-match-ssh` | SSH private key | Read access to the existing distribution Match repository |
| `apple-match-password` | Secret text | Match repository decryption |
| `asc-api-key` | Secret file (`.p8`) | Team App Store Connect API key with upload and notarization access |
| `asc-key-id` | Secret text | API key ID |
| `asc-issuer-id` | Secret text | API issuer ID |

Provision the existing iOS App Store and macOS Developer ID Match assets before running CI; the artifact job never creates or repairs them. It archives `Chahua.ipa`, a universal Developer ID-signed but unnotarized `Chahua-macOS.zip`, and commit/build/checksum metadata. Artifacts are retained for 90 builds. The publishing jobs verify a selected artifact checksum without rebuilding: the iOS job uploads its IPA, while the macOS job notarizes, staples, and packages its ZIP. App Review submission and public release remain manual in App Store Connect.

Run the same checks locally with `bash ci/check.sh compile`, `bash ci/check.sh test`, and `bash ci/check.sh style`. Outputs live in ignored `.ci/`. Style checking uses Xcode's `swift-format`, `.swift-format` configuration, and first-party Swift files only. It is strict and read-only: existing violations must be formatted before the gate can pass; CI does not rewrite source files.

To format all first-party Swift files in place, including untracked files, run:

```sh
./format.sh
```

Run `./format.sh --check` to check without rewriting files. CI's `bash ci/check.sh style` calls this same check, using `.swift-format` and excluding vendored and generated code. The script also works when invoked from another directory.
