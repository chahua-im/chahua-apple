# PWA → Apple feature parity plan

Review date: 2026-10-24. Baseline: the current `chahua/pwa` implementation, compared with the native Apple client on **iOS and macOS**. Flutter is not a reference for this plan and was not inspected.

This is a **source-reviewed implementation backlog**, not a runtime certification. A PWA feature counts only when a reachable screen/action has an implementation behind it, not merely a generated endpoint. “Missing” means no corresponding native workflow was found in the inspected UI/API paths; “partial” means Apple already supplies part of the capability. Native files were changing during review; recheck each item before implementation, particularly relationship actions and the emoji picker.

## Working rules

- Preserve existing Apple functionality. Reuse the shared SwiftUI screens, native timeline hosts, outbox, navigation, and `ChahuaAPI` conventions rather than building parallel feature stacks.
- Each unchecked item below needs its stated behavior on both platforms. Check it only after the reachable workflow is implemented and exercised; record platform, scenario, result, and any remaining manual verification. Source presence, an API method, or a successful build alone is not completion.
- Prefer shared UI. Document concrete UIKit/AppKit exceptions at their implementations. Native controls need not reproduce Ionic layout or browser lifecycle behavior.
- Add missing native API models/endpoints using the current PWA request/response contract; do not assume the older checked-in Apple OpenAPI snapshot contains every current operation. Existing PWA calls establish a contract to inspect, not proof that every server deployment supports it.
- Verify mutations with a local backend/development database or isolated request interception. Do not write test data or upload files to production; the PWA development proxy can target production.
- Keep this document current as capabilities land. Do not inherit completion marks or runtime claims from the old Flutter checklist.

## Recommended delivery order

| Phase | Work | Dependency / rationale |
| --- | --- | --- |
| 1 | M1–M5: complete operations in existing conversations | Useful without a new social-navigation surface; closes explicit unavailable actions and narrower native behavior. |
| 2 | S1–S4 and G1–G4: discovery, friends, safety settings, group lifecycle | Establish S1 profile navigation before request entry points and profile-based management; G2 invite redemption must work before G3 invite sharing is complete. |
| 3 | B1–B4: chat/thread browsing and continuous voice playback | Reuse S1 for participant profiles and M2 for message-target navigation; media browsing can ship independently of file sending. |
| 4 | U1–U4: presentation and input preferences | Independent of social APIs. Emoji search extends the existing picker rather than replacing it. |

These are recommended batches, not a requirement to finish unrelated work before shipping an individual item.

## Phase 1 — Existing conversation capabilities

### M1 — Saved-message snapshots · Missing

- [ ] Add **Save / remove saved message** and a global **Saved Messages** destination with paging, captured-content viewing, source navigation when available, and removal. Preserve saved snapshots when the source is edited, recalled, or no longer accessible; saved forwarded records must use saved-message authorization, not source-chat access. Sticker favorites and shared pins remain separate features.
- **PWA evidence:** [saved-message store](../../chahua/pwa/src/app/messages/saved-message-store.ts) (`save`/remove mutations), [saved-message list](../../chahua/pwa/src/app/messages/saved-message-list/saved-message-list.ts) (paging and source navigation), [routes](../../chahua/pwa/src/app/app.routes.ts) (`chats/saved` and saved forwarded records).
- **Apple starting points:** [message action policy](../App/Features/Chat/Conversation/Timeline/View/Interaction/MessageActionPolicy.swift) marks `.save` as `.unimplemented`; [forwarding endpoints](../Packages/ChahuaAPI/Sources/ChahuaAPI/Endpoints/ForwardingEndpoints.swift) can read a saved forwarded record but do not implement the save/list/remove workflow. Add the destination to [the shell](../App/AuthenticatedShell.swift).
- **Acceptance:** Save text, media, and a forwarded record; reopen and page the global list; change/remove the source and confirm the captured content remains viewable; inaccessible source navigation fails clearly without losing the snapshot; unsave removes only the saved item.

### M2 — Copy and open message links · Missing

- [ ] Enable copying the existing application message-link format for eligible group messages, including thread replies, and route incoming links to the correct chat/thread and highlighted message. Keep the PWA's DM exclusion; do not invent a second URL format.
- **PWA evidence:** [message menu](../../chahua/pwa/src/app/messages/message-menu/message-menu.ts) (link-copy action near lines 597–599), [chat-link route handler](../../chahua/pwa/src/app/chats/chat-link/chat-link.ts), and `/m/:encoded` in [routes](../../chahua/pwa/src/app/app.routes.ts).
- **Apple starting points:** [message action policy](../App/Features/Chat/Conversation/Timeline/View/Interaction/MessageActionPolicy.swift), `.copyLink`, is explicitly unimplemented outside DMs. Reuse search/notification message-target navigation in [the shell](../App/AuthenticatedShell.swift); inspect existing app URL handling before extending it.
- **Acceptance:** Copy a root-message link and a thread-reply link; open from outside the app on iOS and macOS; verify exact IDs, parent scope, target highlighting, and useful unavailable/unauthorized behavior. Copying a link must not mutate the conversation.

### M3 — General file attachments · Partial

- [ ] Extend acquisition, upload/outbox, message rendering, and open/save handling to ordinary files, not only images/videos. Preserve original bytes for the explicit Files workflow; keep the media workflow's image preparation separate. Cover supported paste/drop inputs as well as file selection.
- **PWA evidence:** [composer template](../../chahua/pwa/src/app/messages/message-composer/message-composer.html) has a separate unrestricted file input; [composer logic](../../chahua/pwa/src/app/messages/message-composer/message-composer.ts) routes files separately from media.
- **Apple starting points:** [composer](../App/Features/Chat/Compose/MessageComposerView.swift) restricts `.fileImporter` to `.image` and `.movie` and hands both to `onImportImages`. Extend the existing [outbox](../App/Features/Chat/Outbox/) and attachment presentation rather than just widening the picker filter.
- **Acceptance:** Send and receive a PDF and a non-media document on both platforms; verify filename/type presentation, byte-preserving download/export, progress, offline retry, cancellation, and that ordinary files do not enter image conversion.

### M4 — Atomic multi-select recall · Partial

- [ ] Replace sequential single-message recall for a selection with the PWA's bulk recall operation, up to 100 messages from one chat. Retain eligibility checks, pending-audio publication handling, cancellation, and retryable selection state.
- **PWA evidence:** [conversation](../../chahua/pwa/src/app/conversations/conversation/conversation.page.ts) (selection recall near lines 419–480) prepares selected messages and submits through `recallMany`; [message actions](../../chahua/pwa/src/app/messages/message-actions.ts) calls the batch endpoint.
- **Apple starting points:** [chat detail](../App/Features/Chat/ChatDetail/ChatDetailView.swift), `deleteSelection`, loops over `store.deleteMessage` and stops at the first failure; [message endpoints](../Packages/ChahuaAPI/Sources/ChahuaAPI/Endpoints/MessageEndpoints.swift) exposes individual deletion. Multi-select and multi-message forwarding already exist.
- **Acceptance:** Confirm a multi-message selection produces one bulk submission for its ready items, with server whole-batch validation rather than partially successful sequential deletes. Exercise unauthorized selections, audio awaiting publication, batch failure/retry, and leaving/cancelling during preparation; keep unresolved items selected and only treat server-confirmed recall as successful.

### M5 — DM pin permissions · Partial

- [ ] Allow either participant in a writable DM to manage shared pins, while retaining admin-only pin management in groups. Apply the same policy to the message menu, pin preview, full pin list, and mutation path.
- **PWA evidence:** [message menu](../../chahua/pwa/src/app/messages/message-menu/message-menu.ts), pin availability near lines 271–291, distinguishes DMs from groups.
- **Apple starting points:** [message action policy](../App/Features/Chat/Conversation/Timeline/View/Interaction/MessageActionPolicy.swift), `.pin`/`.unpin`, and [chat detail](../App/Features/Chat/ChatDetail/ChatDetailView.swift) pin controls require `isAdmin`.
- **Acceptance:** Both DM participants can pin and unpin with synchronized results; ordinary group members cannot manage pins; administrators still can; read-only/inactive relationships do not gain write access.

## Phase 2 — Discovery, friends, and groups

### S1 — Directory search and standalone user profiles · Missing outside existing DM info

- [ ] Add the PWA's group/user directory search and a user-profile destination reachable from search results, member/participant rows, and applicable message identities/mentions. Show available user identity, existing relationship actions, a message entry when a chat is available, and the external forum/personal-space link. Do not require an existing DM merely to inspect a user profile.
- **PWA evidence:** [directory search](../../chahua/pwa/src/app/chats/directory-search/directory-search.ts) queries joined groups and users, then opens chat/profile routes; [member rows](../../chahua/pwa/src/app/chats/chat-members/chat-members.html) link to profiles; [chat details](../../chahua/pwa/src/app/chats/chat-details/chat-details.html) includes the personal-space link and relationship actions. `/profile/:uid` is declared in [routes](../../chahua/pwa/src/app/app.routes.ts).
- **Apple starting points:** [the shell](../App/AuthenticatedShell.swift) has group-info and chat-message-search destinations, not directory/profile destinations; [group member rows](../App/Features/Groups/GroupMembersView.swift) display identity/admin actions without profile navigation. [Group/DM info](../App/Features/Groups/GroupInfoView.swift) already handles existing DM identity, friend removal, blocking, and privacy; reuse those capabilities.
- **Acceptance:** Find a user without a prior DM, inspect their profile, open their forum space, and return without losing the conversation/draft. Open the same profile from a group member and a message identity. Directory search must not be labelled global message-history search.

### S2 — Friend requests and request history · Missing

- [ ] Add user lookup/add-friend entry points, request submission subject to the recipient's verification mode, incoming accept/reject/archive actions, outgoing request status, and non-pending request history. Integrate friendship changes with the existing DM list and relationship/privacy state rather than treating every historical DM as an active friendship.
- **PWA evidence:** [start-chat routes](../../chahua/pwa/src/app/app.routes.ts) include `chats/add-friend`; [chat details](../../chahua/pwa/src/app/chats/chat-details/chat-details.ts), `addFriend`, reads the recipient's policy and submits a request; [chat-list content](../../chahua/pwa/src/app/chats/chat-list-content/chat-list-content.html) displays incoming/outgoing requests, decisions, and history.
- **Apple starting points:** [conversation scopes](../App/Features/Chat/ChatList/ConversationListItem.swift) include DMs but no request inbox/history; [friend endpoints](../Packages/ChahuaAPI/Sources/ChahuaAPI/Endpoints/FriendEndpoints.swift) currently cover relationship lookup, removal, and block/unblock, not the request lifecycle.
- **Acceptance:** Exercise direct, verification-message, question, and forbidden modes; prevent duplicate pending requests; accept/reject/archive an incoming request and revisit history; verify accepted friendships and revoked relationships update both clients' accessible actions. S1 supplies the profile entry point.

### S3 — Configure add-friend verification · Missing

- [ ] Add account privacy settings for allowing direct requests, requiring a message, requiring a question response, or forbidding requests. Save simple mode changes immediately; require explicit Apply for a valid question rather than saving incomplete question text.
- **PWA evidence:** [friend-verification settings](../../chahua/pwa/src/app/settings/friend-verification-settings/friend-verification-settings.ts), `loadVerification`/`chooseMode`/`saveVerification`, and [privacy navigation](../../chahua/pwa/src/app/settings/privacy-settings/privacy-settings.html).
- **Apple starting points:** [settings pages](../App/Features/Notifications/NotificationSettingsView.swift), `privacyPages`, currently expose presence and read receipts only. Add the current friend-settings API contract to `ChahuaAPI`.
- **Acceptance:** Persist and reopen all four modes; reject an empty/whitespace question; retain unsaved values on failure and offer retry; a second account sees the saved policy when adding this user.

### S4 — Blocked-user index · Partial safety workflow

- [ ] Add the privacy overview/count and a blocked-users list that opens a profile for unblock management, including users with no currently visible DM.
- **PWA evidence:** [privacy overview](../../chahua/pwa/src/app/settings/privacy-settings/privacy-settings.html) shows the loaded block count and [blocked-users page](../../chahua/pwa/src/app/settings/blocked-users/blocked-users.ts) loads the account's block resource.
- **Apple starting points:** [settings pages](../App/Features/Notifications/NotificationSettingsView.swift) have no block-list destination. **Block/unblock themselves are already implemented** in [Group/DM info](../App/Features/Groups/GroupInfoView.swift), `performSafetyAction`, and [friend endpoints](../Packages/ChahuaAPI/Sources/ChahuaAPI/Endpoints/FriendEndpoints.swift); reuse them rather than rebuilding them.
- **Acceptance:** Block a peer, find them in the index even without a listed DM, open their profile, unblock, and confirm the count/list refresh. Loading failure must not look like an empty successful list.

### G1 — Create a group · Missing

- [ ] Add a reachable create-group form, submit the group name, refresh the conversation list, and open the created group.
- **PWA evidence:** [start-chat flow](../../chahua/pwa/src/app/chats/start-chat/start-chat.ts), `submit`, calls `postGroup`; [routes](../../chahua/pwa/src/app/app.routes.ts) exposes `chats/new`.
- **Apple starting points:** [the shell](../App/AuthenticatedShell.swift) and [API client contract](../Packages/ChahuaAPI/Sources/ChahuaAPI/Core/ChahuaAPIClient.swift) have no corresponding creation workflow.
- **Acceptance:** Create a group from the list on each platform; prevent empty names and duplicate submissions; handle failure without dropping the input; successful creation opens the server-created group once.

### G2 — Preview and redeem group invites · Missing

- [ ] Accept an invite code or existing invite URL, preview the group/status, and join only after explicit confirmation. Already-member previews open the existing group without redeeming again.
- **PWA evidence:** [start-chat flow](../../chahua/pwa/src/app/chats/start-chat/start-chat.ts), `lookup`/`previewValid`/`submit`, and `chats/join[/code]` in [routes](../../chahua/pwa/src/app/app.routes.ts).
- **Apple starting points:** Add invite-preview/redemption endpoints and list/shell entry points alongside [existing group info](../App/Features/Groups/GroupInfoView.swift); reuse app URL routing rather than limiting the feature to manual code entry.
- **Acceptance:** Preview never joins automatically. Exercise valid, expired, revoked, ineligible, and already-member invitations; join succeeds once and updates list/navigation; opening the link works on both platforms.

### G3 — Group invite management and invite messages · Missing

- [ ] Let authorized group administrators list/create/revoke invites, choose supported invite types and optional expiry, copy invite URLs, and send an invite card to a selected destination chat. Support targeted-user and prerequisite-membership selection where the selected type requires them.
- **PWA evidence:** [invite management](../../chahua/pwa/src/app/chats/chat-invites/chat-invites.ts), `create`/`copy`/`revoke`/`share`, uses those parameters and the send-invite-message endpoint; the admin entry is in [chat details](../../chahua/pwa/src/app/chats/chat-details/chat-details.html).
- **Apple starting points:** [group info](../App/Features/Groups/GroupInfoView.swift) has no invite-management action. Add native API operations and integrate received invite-card activation with G2; a generic forwarded message is not an invite-sharing implementation.
- **Acceptance:** Create each UI-supported invite type, copy and redeem its URL, send/open its card in another chat, revoke with confirmation, and confirm revoked/expired links cannot join. Non-admins must not gain management access.

### G4 — Edit group name, description, and avatar · Partial (read-only identity)

- [ ] Add permission-gated field editing and avatar selection/upload to group info; save only the edited field and refresh group/list identity after success. Permit clearing the description, not an empty name; retain input on failure.
- **PWA evidence:** [chat-details template](../../chahua/pwa/src/app/chats/chat-details/chat-details.html) exposes admin edit/avatar controls; [chat-details logic](../../chahua/pwa/src/app/chats/chat-details/chat-details.ts), `save`/`avatar`, performs group patches and avatar upload.
- **Apple starting points:** [group info](../App/Features/Groups/GroupInfoView.swift), `hero`/`descriptionCard`, is display-only. Reuse upload handling with the group-avatar endpoint contract.
- **Acceptance:** An admin edits each field independently and changes the avatar, then sees the result in info and list rows on both clients. Ordinary members remain read-only. Do not add group visibility editing or avatar removal merely because an API field could support it; this review established the PWA's avatar replacement UI, not removal UI.

## Phase 3 — Browse existing content

### B1 — Chat-wide image, video, and file browser · Missing

- [ ] Implement real, independently paged Images/Videos/Files sections in conversation info, including open/download and source-message navigation. A per-message gallery is not a chat-wide browser. When shown from a thread, label the scope honestly: the current PWA queries the parent chat's attachments, not thread-only media.
- **PWA evidence:** [chat-details tabs](../../chahua/pwa/src/app/chats/chat-details/chat-details.html) render [chat attachments](../../chahua/pwa/src/app/chats/chat-attachments/chat-attachments.ts), which queries by kind/cursor and resolves source messages into their parent/thread scope.
- **Apple starting points:** [group/DM info](../App/Features/Groups/GroupInfoView.swift), `sectionTabs`, renders noninteractive section labels and only loads group members. Reuse [the existing media viewer](../App/Features/Chat/ImageDetail/) for viewing rather than replacing it.
- **Acceptance:** Page images/videos/files independently, open an item, locate a thread attachment in its actual thread, and return to the same browsing position. Distinguish empty, failed, and exhausted lists. Do not implement the placeholder Links/Voice tabs as if PWA parity required them.

### B2 — Per-chat thread discovery · Partial (global subscribed Threads already exists)

- [ ] Add an info section listing thread roots from the selected chat, including roots not already in the user's subscribed Threads list. Continue using message-page cursors; a page without roots is not end-of-history.
- **PWA evidence:** [chat threads](../../chahua/pwa/src/app/chats/chat-threads/chat-threads.ts), `load`, pages ordinary messages and filters `threadInfo`; [chat details](../../chahua/pwa/src/app/chats/chat-details/chat-details.html) mounts it only outside thread detail.
- **Apple starting points:** [group info](../App/Features/Groups/GroupInfoView.swift) has no thread section; [chat detail](../App/Features/Chat/ChatDetail/ChatDetailView.swift) already opens threads and supplies whole-thread forwarding. Reuse that navigation and current message APIs.
- **Acceptance:** Open an unsubscribed thread from chat info; continue beyond a page containing no thread roots; preserve browsing position on return. Do not scan all history to claim a complete thread directory or invent a nonexistent per-chat thread-list endpoint.

### B3 — Thread participants · Missing as a browseable surface

- [ ] Add a thread information destination with a participant list, using server-provided thread participants when cached and otherwise the root plus loaded replies. Make partial coverage explicit and open user profiles through S1; do not substitute the parent group's member directory.
- **PWA evidence:** [thread participants](../../chahua/pwa/src/app/chats/thread-participants/thread-participants.ts) merges cached participants with the root/loaded messages; [chat details](../../chahua/pwa/src/app/chats/chat-details/chat-details.html) selects that view for thread info.
- **Apple starting points:** [thread detail](../App/Features/Chat/ChatDetail/ThreadDetailView.swift) and [chat detail](../App/Features/Chat/ChatDetail/ChatDetailView.swift) supply conversation/subscription UI, but no participant directory. The existing group directory represents a different scope.
- **Acceptance:** Show unique thread participants, reflect newly loaded replies, disclose incomplete coverage when no authoritative cache exists, and open profiles without scanning historical messages or losing thread position/draft.

### B4 — Persistent voice player and shared playback speed · Partial

- [ ] Move active voice-playback ownership out of the message row and provide the PWA-equivalent persistent playback bar, play/pause, shared speed setting, sender/time, and jump-to-source navigation. Keep one active voice message and retain playback across conversation/list navigation.
- **PWA evidence:** [voice playback state](../../chahua/pwa/src/app/messages/voice-player/voice-playback.ts) adopts playback when inline players disappear and retains global speed; [voice bar](../../chahua/pwa/src/app/messages/voice-player/voice-bar.html) exposes playback, source, and speed controls.
- **Apple starting points:** [voice controller](../App/Features/Chat/VoicePlaybackController.swift) owns row-level playback, has only a weak static active controller, and releases player/resources in `stop()`. Basic recording, waveform playback, and seeking already exist.
- **Acceptance:** Start playback, scroll the row away, visit another chat and the list, and still control the same message. Change speed, play a second message, and jump back to the source; verify single-player behavior, failure, and account teardown. Native lock-screen/background audio is not established as PWA parity and is outside this item.

## Phase 4 — Presentation and input

### U1 — System / Light / Dark override · Partial (system appearance exists)

- [ ] Add a persisted app-level appearance choice and apply it to the whole app from launch, including sheets and native timeline surfaces. System follows OS changes; explicit Light/Dark overrides do not.
- **PWA evidence:** [general settings](../../chahua/pwa/src/app/settings/general-settings/general-settings.html), [preferences](../../chahua/pwa/src/app/settings/preferences.ts), and [appearance application](../../chahua/pwa/src/app/settings/appearance.ts).
- **Apple starting points:** [settings](../App/Features/Notifications/NotificationSettingsView.swift) exposes typography and badge colors but no mode choice; [theme](../App/DesignSystem/ChahuaTheme.swift) consumes the environment color scheme. Apply the preference at the app/root presentation boundary.
- **Acceptance:** Switch all three choices on iOS/macOS, relaunch, open sheets/media/settings, and change the OS appearance while System is selected; no surface should retain the wrong scheme.

### U2 — Avatar density and DM identity preferences · Missing preferences

- [ ] Add persisted controls for showing all message avatars and showing/hiding both avatars and names in DMs. Apply the avatar-density choice to normal timelines and forwarded records; the DM-only choice must not hide group identities or incorrectly change record-detail rules.
- **PWA evidence:** [general settings](../../chahua/pwa/src/app/settings/general-settings/general-settings.html), [preferences](../../chahua/pwa/src/app/settings/preferences.ts), [conversation template](../../chahua/pwa/src/app/conversations/conversation/conversation.page.html), and [forwarded records](../../chahua/pwa/src/app/messages/forwarded-records/forwarded-records.html).
- **Apple starting points:** [conversation preferences](../App/Features/Chat/ChatList/ConversationListPreferences.swift) and [settings](../App/Features/Notifications/NotificationSettingsView.swift) do not expose these options. Preserve native timeline grouping and shared geometry rather than rendering separate message implementations.
- **Acceptance:** Toggle each option across DM/group/thread/forwarded-record views, reopen the app, and verify name/avatar visibility, reclaimed DM avatar-column space, grouping, and source-author presentation.

### U3 — Bold/italic composer shortcuts · Partial (rendering already exists)

- [ ] Implement Cmd/Ctrl+B and Cmd/Ctrl+I on selected composer text using `**bold**` and `__italic__` wire markup. Match the existing whitespace/paragraph behavior and preserve editing/selection; do nothing for an empty selection or during IME composition. On iOS, exercise with a hardware keyboard.
- **PWA evidence:** [composer](../../chahua/pwa/src/app/messages/message-composer/message-composer.ts), formatting handler near lines 278–296 and key handler near 532–538, wired by [the template](../../chahua/pwa/src/app/messages/message-composer/message-composer.html).
- **Apple starting points:** [composer](../App/Features/Chat/Compose/MessageComposerView.swift) handles Return/Escape/arrows but not these format shortcuts. The existing Markdown parser/renderer already supports bold and italic; no format toolbar is required.
- **Acceptance:** Format selections containing leading/trailing spaces and blank lines; verify unchanged outside text, expected sent rendering, undo/edit behavior, and no mutation during Chinese input composition.

### U4 — Search within the full reaction picker · Partial; changes an intentional native UX choice

- [ ] Add localized emoji name/keyword search and pasted-emoji lookup to the existing Unicode 17 reaction picker. Keep exact emoji sequences, skin-tone variants, recent choices, reaction eligibility, and platform-native presentation. This explicitly expands the current category-only design; it is not a missing full-picker implementation.
- **PWA evidence:** [emoji picker](../../chahua/pwa/src/app/messages/emoji-picker/emoji-picker.ts) and [picker data](../../chahua/pwa/src/app/messages/emoji-picker/picker-data.ts) supply search and localized data.
- **Apple starting points:** [reaction keyboard](../App/Features/Chat/Conversation/Reactions/ReactionEmojiKeyboard.swift) has categories/pages/recents/variants but no search input; [catalog](../App/Features/Chat/Conversation/Reactions/ReactionEmojiCatalog.swift) already loads bundled Unicode 17 data. Add search metadata as needed; do not replace working catalog/tone support.
- **Acceptance:** Find available emoji by English, Simplified Chinese, and Traditional Chinese names/keywords and by pasting a full sequence; select toned/mixed sequences without normalization loss; verify no-results, recents, and permission/deletion changes while open.

## Already implemented — do not rebuild as missing features

The following native implementations were found in source. This does **not** newly certify their runtime behavior or replace pending device checks.

- Chat-scoped relevance/recent message search, paging, and result navigation: [Search](../App/Features/Chat/Search/) and [shell](../App/AuthenticatedShell.swift).
- Threads, subscribe/archive/unarchive, reply/edit/single recall, selection, single/merged/whole-thread forwarding and record viewing: [ChatDetail](../App/Features/Chat/ChatDetail/), [Forwarding](../App/Features/Chat/Forwarding/), and [ThreadSubscription](../App/Features/Chat/ThreadSubscription/). M4 concerns batch recall specifically.
- Quick reactions, a full Unicode 17 picker with tone variants, and reactor details: [Reactions](../App/Features/Chat/Conversation/Reactions/). U4 concerns search only.
- Markdown rendering including spoilers, code, and lists: [Markdown architecture](arch/markdown-rendering.md). U3 concerns input shortcuts only.
- Image/video acquisition, iOS camera capture, media viewing/playback, media export/save actions, voice recording/basic playback: [Compose](../App/Features/Chat/Compose/), [ImageDetail](../App/Features/Chat/ImageDetail/), and [voice controller](../App/Features/Chat/VoicePlaybackController.swift). These do not establish arbitrary-file parity or cross-chat playback ownership.
- Sticker sending/favorites/subscriptions and owned-pack create/rename/reorder/delete/upload/remove: [sticker management](../App/Features/Chat/Stickers/StickerManagementViews.swift) and [library](../App/Features/Chat/Stickers/StickerLibrary.swift). The old unchecked management item was a verification gap, not missing implementation.
- Group info, member browse/search/paging, administrator promote/demote/remove, and group leave: [Groups](../App/Features/Groups/). Native member-management controls should remain even where the current PWA member panel is simpler.
- Existing DM friend removal and block/unblock: [Group/DM info](../App/Features/Groups/GroupInfoView.swift) and [friend endpoints](../Packages/ChahuaAPI/Sources/ChahuaAPI/Endpoints/FriendEndpoints.swift). S4 adds the missing account-wide index.
- Device notification enable/disable/permission help, account DM/group defaults, paged exceptions/add/remove/clear, per-chat inherited/explicit/timed preferences: [Notifications](../App/Features/Notifications/). Do not confuse native APNs registration with browser Push subscription.
- Global and per-friend presence/read-receipt privacy, authorized DM receipts, online/away/last-seen display, DM online dots, group member/online counts, unread mention/reaction navigation and server-wide badge summaries: [Notifications](../App/Features/Notifications/), [presence display](../App/DesignSystem/Components/UserPresenceDisplay.swift), and [timeline architecture](arch/conversation-timeline.md). Account-level “Coming soon” exception-list placeholders do not mean per-friend overrides are absent; the PWA does not establish a bulk privacy-exception index requirement here.
- Language selection, five-step message sizing with system-default option, thread inclusion in Messages, badge-color presets, cache inspection/clearing, and sticker/reaction preferences: [settings](../App/Features/Notifications/NotificationSettingsView.swift). Apple credential login, Keychain session restoration, and sign-out also exist; the PWA's token-entry lifecycle is not a native gap.

## Differences and exclusions

- **Sticker picker shortcuts:** PWA can create packs/upload into an owned pack directly from its picker; Apple exposes these capabilities in Settings → Manage Sticker Packs. This is a navigation difference, not missing pack management. Reusing those screens from the picker is optional, not a blocker for the capability backlog.
- **Prior native-only requests:** The old checklist recorded a user-requested custom unread-badge color picker beyond presets. Retain that request as separate native work; this review did not establish it as a PWA feature. Likewise, do not carry over sticker hold-to-preview as a PWA gap without a reachable PWA implementation.
- Browser installation instructions/prompts, service-worker updates, browser history mechanics, and web notification permissions have native equivalents/platform differences; do not copy these controls literally into Apple.
- No PWA implementation was established for self-profile editing, adding arbitrary members directly, group visibility editing, global message-history search, or sender/date message filters. Do not add them to this parity plan based only on API shapes or old client assumptions.
- Do not regress Apple-only strengths such as secure credentials, durable drafts/outbox behavior, native Photos/export integration, or existing administrator tools to match narrower browser behavior.

## Verification and completion record

This review used static source inspection across routed PWA UI/actions and corresponding native UI, policies, stores, and endpoint surfaces. No application builds, authenticated runtime scenarios, device interactions, or production mutations were performed. All new backlog boxes are intentionally unchecked.

For each implementation, exercise the changed UI through to its observable result on iOS and macOS, including failure/retry and navigation/state preservation. Use existing regression coverage where applicable; add focused tests for uncertain consumer-visible boundaries such as batch atomicity, snapshot authorization, invite eligibility, account switching, and exact ID/emoji preservation. Do not substitute copied request mocks or menu-presence assertions for actual behavior verification. Record manual device checks separately from automated/build evidence.
