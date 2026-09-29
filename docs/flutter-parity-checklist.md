# Flutter → Apple feature parity checklist

Tracks user-facing functionality implemented in the old Flutter client but missing or partial in the Apple client's iOS surface, based on the 2026-09-20 static source review. Existing Apple functionality must be preserved. Source review is not runtime verification; confirm the current implementation before starting each item.

## Maintenance instructions

- Check off each item (`[x]`) as it is fully implemented and its user-visible behavior is verified. Do not check off scaffolding, API-only support, disabled controls, or partial implementations.
- Record a brief verification note under the completed item, including the platform and scenario exercised. If manual verification is still pending, leave the item unchecked.
- Prefer shared Apple-client implementations where appropriate; document necessary platform-specific exceptions according to repository guidance.
- Keep this checklist current while implementing these features.
- **Once every feature checkbox below is checked, delete this file.** Do not retain it as a completed historical checklist.

## Messaging

- [ ] **Chat-scoped message search:** query messages, choose relevance/newest ordering, paginate results, and navigate to a result in its chat or thread. Member autocomplete is not message search.
- [ ] **Full reaction emoji picker:** enable the More reactions control and allow selecting emojis beyond quick reactions, using the existing reaction eligibility and mutation behavior.
- [ ] **Thread subscription controls:** expose membership state and subscribe/archive/unarchive actions inside thread detail. Preserve existing conversation-list archive/unarchive actions.

## Media and stickers

- [x] **Camera capture from the composer:** take a photo directly and pass it through the existing attachment/send workflow. Photos and Files acquisition already exist.
  - User confirmed the iOS camera flow works after the full-screen presentation change: Take Photo opens the native camera and passes captured photos through attachment preview/send. Available from the attachment menu and attachment preview; macOS retains Photos and Files. iOS simulator builds also pass.
- [ ] **Video attachment playback:** open received video attachments, play/pause, and seek. Replace the unavailable-video interaction with working playback; video upload already exists.
- [ ] **Save received media to Photos:** save both images and videos to the device photo library, handling authorization and reporting success or failure.
  - Image saving is implemented in the image viewer's **Save Image** overflow action: iOS uses add-only Photos authorization; macOS exports the original through a native Save panel. The header shows the chat/thread name and message time. Saving is silent until a success/failure toast; cancellation is silent. Both platform builds passed; macOS viewer/menu, byte-for-byte export, and success/failure toasts were exercised using existing diagnostic media. iPhone Photos authorization and mobile appearance still need device verification. Leave unchecked: video saving remains outside this image-only change.
- [ ] **Owned sticker-pack management:** create a pack, upload/add stickers with metadata, remove stickers, and delete an owned pack. Sending, favorites, and subscriptions already exist.
  - Implemented in `StickerManagementViews.swift` and `StickerLibrary.swift`: create packs, import/upload stickers with emoji and optional name, confirm sticker removal, and confirm owned-pack deletion. Source review confirms UI actions call the corresponding API-backed mutations. The remaining gap is authenticated user-visible verification, not implementation; leave unchecked until these flows are confirmed on iOS.
- [ ] **Sticker picker hold-to-preview:** show an enlarged preview while pressing and holding a sticker before sending; preserve tap-to-send behavior.

## Groups

- [x] **Group information screen:** expose the group avatar, name, description, and applicable group actions in a reachable information/settings destination.
  - Title navigation was verified on iOS 26.5, iPhone 17 Pro and iPad Pro 11-inch; split navigation stays in the right pane. The revised unboxed profile, compact Mute/More actions, and inline members were rendered and visually inspected on iPhone and wide macOS layouts.
- [x] **Member directory:** browse, search, and paginate group members. Existing mention autocomplete does not replace a directory.
  - Pagination, search, deduplication, and server-provided management permissions were exercised before the layout revision. Members now appear inline below the profile with a local search field and refresh control, rather than a separate pushed directory. The revised layout was visually inspected on iPhone and macOS; the directory model and mutation logic are unchanged.
- [x] **Admin member management:** allow authorized administrators to promote, demote, and remove members, with appropriate confirmation and error handling.
  - Verified on both simulator layouts: native member menus and confirmations promoted, demoted, and removed a member, updating the directory. Unauthorized management was rejected by the directory model.
- [x] **Leave a group:** confirm leaving, perform the membership mutation, and update navigation and the conversation list.
  - Confirmed leave previously removed the conversation and returned out of group detail on both simulator layouts. Leave is now under More and retains its confirmation. Store regression coverage verifies child-thread cleanup, stale-list fencing, and draft preservation.
- [x] **Timed notification muting:** offer 1 hour, 8 hours, 1 day, 7 days, and indefinite mute, while preserving unmute and existing list actions.
  - Verified on both simulator layouts: selected every duration and unmuted, observing notification status and list-state changes. Store regression coverage verifies preview/read-state preservation and unarchive-on-unmute.

Group verification used temporary hosted runners with deterministic API responses, not live-server sessions; captures were visually inspected and the runners were removed afterward. API wire-contract tests cover group metadata, member mutations, and timed/indefinite mute. The revised shared SwiftUI profile uses one scroll surface and a bounded desktop content width. Only action controls use Liquid Glass on iOS; macOS uses flat action tiles. The member panel is an ordinary flat surface on both platforms. No media tabs or unsupported reference actions were added.

## Settings and customization

- [ ] **In-app language selection:** persist a choice of system default, English, Simplified Chinese, or Traditional Chinese and apply it to the app. Existing localization and OS-managed language selection are not the missing feature.
  - Implemented: `AppLanguage` supplies all four choices; `@AppStorage` persists the selection, `ChahuaApp` applies the SwiftUI locale, and app-localized eager strings use the selected locale. Device verification remains unconfirmed. Notification quick-reply labels still use `String(localized:)` rather than the in-app override.
- [ ] **Cache inspection and clearing:** display cached media/image disk usage and let the user clear it with confirmation, then refresh the displayed usage. Do not remove unsent outbox data.
  - Implemented: Storage displays Kingfisher disk usage, confirms clearing, clears memory/disk media, and refreshes usage with success/error feedback. The clear path does not touch the separate drafts/outbox store. Device verification remains unconfirmed. Production `AppCompositionRoot` namespaces the media cache by API base URL, not user ID; the earlier claim of account-scoped media-cache isolation was too strong.
- [x] **Thread inclusion in Messages:** persist the “Show 'Threads' in Messages” preference and apply it to the Messages list and unread count, including archived conversations. Keep the dedicated Threads scope available.
  - User confirmed this is the intended behavior and verified the toggle on device. This replaces the former requirement to hide/show the entire Messages tab; all four tabs remain available. `ConversationListItem` and `ConversationTabBadges` apply the preference to list contents and counts.
- [ ] **App-specific message text size:** provide a persisted message text-size control equivalent to Flutter's 14–18 pt preference, without regressing system accessibility behavior.
  - Implemented: the persisted 14–18 pt slider feeds the composer and both native timelines through `MessageTextSizePreference`; iOS uses Dynamic Type scaling and macOS scales relative to the preferred body font. Source inspection confirms the rendering paths; device verification, including accessibility text sizes, remains unconfirmed.
- [x] **Unread-badge color presets:** provide a persisted color override and reset-to-default action for colored unread badges; muted conversations and the aggregate Archived row use the same adaptive gray badge.
  - User confirmed the unread-badge color setting works on device. Source inspection confirms preset persistence/reset and adaptive `.quaternary` gray for muted and Archived badges.
- [ ] **Custom unread-badge color picker:** extend the existing presets with a custom color picker, persist the selected color, and retain reset-to-default and adaptive-gray behavior for muted/Archived badges.
  - Requested by the user after verifying preset colors. Recorded as pending work only; no picker implementation was added in this review.

Settings uses shared controls with platform-appropriate navigation: a pushed category list and grouped forms on iPhone/iPad, and a persistent sidebar with detail pane on macOS. The thread-inclusion preference uses a switch on both platforms; it does not hide the Messages tab. Source inspection confirms persisted language, message typography, and unread-color controls and their consumers. Earlier isolated cache-clear verification passed on macOS and iPhone 17 Pro simulator using separate injected caches: disk usage fell to zero while the other cache remained intact. This does not prove per-account isolation in production, where the media cache namespace is the API base URL. Earlier conversation-scope tests passed on macOS. The current review is code inspection, not a new authenticated runtime check; device confirmations and remaining verification are recorded per item above.

Grouped iOS settings forms use their native row separators; standalone dividers are reserved for the macOS detail cards so they do not render as empty rows on iPhone or iPad.

Settings now starts with the signed-in avatar/name, groups active destinations under General and Push Notifications, and ends with Sign out; the obsolete Account/Refresh chats page is removed. Emojis & Stickers manages owned and subscribed packs, pinned quick reactions, sorting preferences, server-backed pack ordering, and owned-pack sticker uploads/removal. Sticker management is shared across iOS/macOS; the API request-shape test covers pack and upload mutations. Visual interaction with an authenticated account still requires manual verification.

Notification settings show OS authorization, APNs environment, a non-sensitive token suffix, backend confirmation, and a retry action. macOS can inspect the signed entitlement and use it for backend routing; iOS cannot read that entitlement at runtime, so it reports the build-configured environment (shared by Info.plist and the signing request). iOS Release now requests production APNs; Debug/Local and macOS Release retain sandbox to preserve the existing working macOS behavior. A successful backend subscription confirms registration, not end-to-end delivery: verify on a signed physical iPhone by sending a message while the app is backgrounded.

## Scope exclusions

These are not additional checklist items and do not block deletion of this file:

- Flutter's release-reachable developer-session controls are not a normal product parity requirement. Apple intentionally confines developer authentication controls to DEBUG builds; do not expose them in production as part of this checklist.
- Do not count unused Flutter APIs, placeholders, or debug-only UI as implemented features. The review did not establish reachable Flutter implementations for Copy Link, a reactor-details sheet, media sharing, profile editing, group creation/join/invite UI, adding members, or editing group metadata.
- Preserve existing Apple functionality: text copy, reply, edit/delete, thread creation/opening, pins, quick reactions, archive, mark read/unread, basic mute, image viewing, media uploads, voice recording/playback, sticker sending/favorites/subscriptions, and push-notification navigation.

## Implementation reference areas

Paths below are relative to the workspace containing both repositories.

| Area | Flutter reference | Apple starting points |
| --- | --- | --- |
| Messaging | `chahua/wetty-chat-flutter/lib/features/conversation/` | `chahua-apple/App/Features/Chat/Conversation/`, `ChatDetail/`, `Packages/ChahuaAPI/` |
| Media and stickers | `chahua/wetty-chat-flutter/lib/features/conversation/compose/`, `lib/features/stickers/` | `chahua-apple/App/Features/Chat/Compose/`, `ImageDetail/`, `Stickers/`, `Outbox/` |
| Groups | `chahua/wetty-chat-flutter/lib/features/groups/` | `chahua-apple/App/AuthenticatedShell.swift`, `App/Features/Chat/ChatDetail/`, `Packages/ChahuaAPI/Sources/ChahuaAPI/Endpoints/ChatEndpoints.swift` |
| Settings | `chahua/wetty-chat-flutter/lib/features/settings/`, `lib/core/settings/app_settings_store.dart` | `chahua-apple/App/Features/Notifications/NotificationSettingsView.swift`, `App/Features/Chat/ChatList/`, `App/DesignSystem/` |
