# Native iOS App Delivery Plan

## Purpose

A progressively deliverable plan for a first-party, iOS-native chat client. This is a planning document, not an implementation commitment or a GitHub issue list yet. Each numbered task is intended to become one issue after product and technical review.

**Decision — 2026-08-28:** Build a first-party SwiftUI iOS app. The first release is an internal TestFlight build. Support iOS current-major-minus-two at launch. Ship iPhone and iPad; defer macOS as a later target while designing shared SwiftUI state, domain, and reusable UI components so the future port is additive rather than a rewrite.

## Existing-client evidence and planning boundaries

| Area | Existing PWA | Existing Flutter client | Planning implication |
| --- | --- | --- | --- |
| App architecture | Ionic React, Redux, Axios, React Router v5 | Cupertino + GoRouter, Riverpod, Dio | The native app should own its UI/navigation/state while reusing the server API contract. Do not port web UI or Redux state mechanically. |
| Authentication | JWT, cookie/query bootstrap, client ID compatibility | Persisted JWT plus legacy headers; development credential flow | Establish one production mobile-auth contract before building screens. |
| Realtime | Ticket-authenticated WebSocket with reconnect/lifecycle logic | Ticket-authenticated WebSocket with lifecycle/recovery logic | Realtime can be built after read-only messaging, but its server event contract needs a written compatibility test suite. |
| Notifications | Web Push, service worker, VAPID, app badge | Push abstraction and APNs channel code, but no iOS runner | APNs device registration, notification payloads, universal links, and server support are explicit work—not a port of Web Push. |
| Local data | IndexedDB preferences and notification high-water marks; no offline outbox | Preferences and caches; no production database | Ship online-first initially. Make offline storage/outbox a separately approved product capability. |
| Media | Browser capture, compression, direct object-store upload | Picker/recording/playback packages and native voice package | iOS capture, permissions, codecs, upload resume/cancel, and playback must be treated as vertical slices. |
| Current product surface | Chats, threads, groups, settings, stickers, search, media, pins, saved messages; several production gates off | Chats, conversations, threads, groups, settings, stickers, search, media | The MVP must be selected from enabled, supported product behavior—not from every dormant UI path. |

Evidence: `wetty-chat-mobile/src/App.tsx`, `src/api/ws.ts`, `src/hooks/usePushNotifications.ts`, `src/api/upload.ts`, and `package.json`; `wetty-chat-flutter/lib/app/app.dart`, `lib/app/routing/app_router.dart`, `lib/core/session/dev_session_store.dart`, `lib/core/network/websocket_service.dart`, `lib/core/notifications/`, and `pubspec.yaml`. The Flutter project currently has no iOS runner/configuration directory, so it is not presently an iOS deliverable.

## Delivery principles

1. **One server contract, multiple clients.** Server endpoints and WebSocket event schemas are the product boundary. UI state, storage, and navigation remain platform-owned.
2. **Online-first MVP.** Do not promise sending while offline, full message history offline, or background WebSocket delivery until those capabilities are designed, implemented, and tested.
3. **Native platform behavior is a requirement.** Secure credential storage, APNs, notification routing, permissions, media-session behavior, dynamic type, VoiceOver, and iOS lifecycle handling are acceptance criteria.
4. **Vertical slices over screen completion.** A user should be able to complete a coherent workflow at the end of each milestone.
5. **Capability parity is intentional, not automatic.** Feature-gated or unfinished web/Flutter behavior is reviewed before it enters the iOS backlog.

## Definition of ready for every future issue

Before an issue enters a sprint, it has:

- a product owner and an explicit in/out-of-scope statement;
- API, WebSocket, and notification payload examples or a linked backend-contract issue;
- navigation entry and exit behavior;
- loading, empty, error, permission-denied, and unauthorized states;
- accessibility/localization requirements;
- telemetry/privacy expectations where applicable;
- deterministic unit, UI, or integration acceptance coverage; and
- a device/OS support target and any required Apple entitlement.

## Confirmed contracts

### Platform and release contract

- **Client:** first-party SwiftUI app. SwiftUI replaces Flutter over time; the initiative focuses on Apple platforms. The PWA and other clients are outside this plan's migration scope.
- **Release:** internal TestFlight first; minimum iOS version is current major minus two.
- **Devices:** ship iPhone and iPad. Use stack navigation on iPhone and adaptive split-view navigation on regular-width iPad. macOS is deferred, but shared SwiftUI domain, state, and reusable UI components must support a later Apple-platform expansion.

### Initial TestFlight scope contract

- **Included:** sign-in/session restoration/logout; active-chat list; text timeline and sending; foreground realtime and recovery; APNs opt-in, badge, and notification opening; account/notification settings; threads; group participation; replies/reactions; photo/video/file attachment picking, compression, and display; voice-message record/playback; and stickers.
- **Group boundary:** participate in existing groups only. Group creation, membership changes, invite redemption, and group settings are post-MVP.
- **Post-MVP:** search, pins, saved messages; archives and chat create/join flows; friend/direct-message/block flows; advanced language, appearance, cache, developer, and sticker-pack settings.

### Authentication contract

- **Development/test:** expose a debug-only developer-session path and manual JWT entry. The developer-session endpoint remains unavailable in release deployments; neither control ships in TestFlight/App Store configuration.
- **Production:** use a native username/password form and the same HTTPS form-encoded credential `POST` currently used by Flutter. Treat its plain-text response as a candidate JWT, validate it through `/users/auth-token`, fetch `/users/me`, then persist the validated token in Keychain.
- **Session/account:** use the existing long-lived, revocable v2 JWT model. Local logout removes the Keychain token and unregisters APNs. Logout-all-devices, recovery, and account deletion are out of scope for the first TestFlight build.
- **Implementation artifact:** document the credential endpoint request/response/error schema, TLS/ATS requirements, rate-limit/lockout behavior, password-redaction rules, backend owner, fixtures, and auth/revocation/logout acceptance scenarios. The app must never log, cache, or include credentials/JWTs in diagnostics.

### Notifications and deep-link contract

- **APNs privacy/badge:** notifications show sender and message preview. APNs/server payloads own the authoritative total unread badge; the app reconciles it after opening or foreground recovery.
- **Transport/routing:** canonical HTTPS Universal Links have browser fallback; a custom URL scheme is reserved for internal tooling/debug. Routes cover approved conversation and thread targets. When authentication is required, retain the validated destination, sign in, then resume; show an explicit unavailable state for deleted, inaccessible, or malformed targets.
- **Implementation artifact:** specify sandbox/production environments; device-token registration and logout unregistration; payload version, stable target identifiers, collapse/thread identifiers, preview localization, badge number, fallback route, and physical-device acceptance scenarios. Invitation links remain post-MVP with group management.

### Quality contract

- **Diagnostics:** use Sentry for crash/fatal-error reporting only; do not add behavioral product analytics for the internal TestFlight build. Establish Sentry’s data-handling policy and SDK integration in 10.1.
- **Accessibility/localization:** no dedicated accessibility treatment or audit is a TestFlight gate. Use standard SwiftUI controls where they provide platform semantics; do not schedule specialized accessibility work. Ship English, Simplified Chinese, and Traditional Chinese.
- **Performance/reliability:** use measured core-flow gates. Establish numeric values and reference devices from the first foundation build; cover launch, chat opening/scrolling, media memory, reconnect/reconciliation, notification delivery, and crash-free sessions.

## Progressive task breakdown

### Milestone 1 — Deliverable iOS foundation


**1.1 Build the app composition root and design foundations**

- Split this foundation work into focused implementation issues: dependency composition and environments; adaptive navigation; localization; and shared design/state components.
- **Set up app dependency composition and environments:** create one composition boundary that constructs `ChahuaClient` from `AppConfiguration.apiConfiguration` and injects app-owned dependencies. Preserve Local, Debug, and Release API configuration; invalid or missing `APIBaseURL` fails before a request.
- **Build the adaptive app navigation shell:** add app-owned route state and a logged-out/authenticated shell, using stack navigation on iPhone and adaptive split navigation on regular-width iPad. Limit destinations to authentication, chat list, timeline, and settings; use explicit fixture placeholders until their issues land.
- **Add app localization scaffolding:** add string catalogs and locale selection for English, Simplified Chinese, and Traditional Chinese. Localize shell and shared state text; missing translations fall back to English; do not add a user-facing language settings screen.
- **Build shared design and state components:** add theme tokens and reusable SwiftUI components for forms, lists, loading, empty, recoverable error, avatars, timestamps, and image loading, with deterministic preview/test fixtures for each state. Use standard SwiftUI semantics and Dynamic Type; do not add feature-specific chat bubbles.
- **Done when:** each configuration launches the same logged-out root with its configured API base URL; fixture state traverses every route on iPhone and iPad without duplicated navigation state; all three locales render translated shell/loading/empty/error strings; and a fixture gallery renders every shared component state in every locale.
- **Depends on:** navigation and localization depend on dependency composition; shared components depend on localization.

**1.2–1.3 Implement authentication**

- Implement the form-encoded username/password request, candidate-JWT validation through `/users/auth-token`, `/users/me` loading, Keychain-backed `TokenStorage`, restore/revoked/logged-out/network-unavailable bootstrap states, local logout, and debug-only dev-session/manual-JWT controls excluded from Release.
- Cover invalid credentials, malformed/expired/revoked tokens, cancellation, server unavailability, relaunch restoration, and credential deletion on logout. Credentials and JWTs never enter logs, cache, screenshots, or diagnostics.
- **Done when:** a clean staging install signs in with real credentials, relaunch restores the account, invalid or revoked credentials return safely to sign-in, a transient network failure can retry, logout removes Keychain access, and Release exposes no debug auth control.
- **Depends on:** adaptive navigation and shared design/state components.


### Milestone 2 — Chat-list gateway and timeline prototype


**2.1 Build the minimal chat-list gateway**

- Fetch and render only enough active-chat data to identify a conversation and open it. Keep loading and recoverable-error states; exclude pagination, refresh, unread counts, previews, search, archive, sorting refinements, and list reconciliation.
- **Done when:** an authenticated staging user can choose an active chat and enter its conversation timeline.
- **Depends on:** 1.2; Authentication contract.

**2.2 Prototype and build the conversation timeline**

- Treat this as the milestone’s primary risk-reduction epic, not a single implementation issue. The final scope is a minimal read-only timeline; composition, read state, realtime updates, reactions, replies, threads, and rich media remain deferred.
- **GitHub issue split:**
  1. **Timeline behavior contract and fixtures:** document timeline direction, cursors, chronology, message states, and representative small/large conversation fixtures.
  2. **Canonical timeline store and paging:** implement page loading, cursor handling, chronological merge, deduplication, and retry/error state independent of UI.
  3. **Timeline container and loading states:** build the read-only list host, loading/empty/failure states, and the initial-position policy without coupling it to a particular bubble type.
  4. **Scroll behavior and state restoration:** a dedicated issue for loading older/newer pages without visual jumps, maintaining the visible anchor, initial bottom/target positioning, and restoring position after leaving/returning.
  5. **Text-message bubble:** render sender identity, plain/rich text, timestamp, edited/deleted state, and outgoing/incoming presentation.
  6. **System-message and date-separator rows:** render membership/system events and chronological separators independently of ordinary message bubbles.
  7. **Bubble-layout grouping:** add sender grouping, avatar/name visibility rules, and mixed row-height measurement without changing scroll semantics.
  8. **Large-timeline hardening:** validate the assembled timeline against representative large conversations for rendering performance, duplicate rows, chronology errors, and deleted/unknown-message recovery.
  9. **Later bubble issues, one type per issue:** image/video attachment; file attachment; voice message; sticker; invitation; reply preview; reaction summary; and thread summary. These remain outside Milestone 2 and must not be bundled into the base timeline work.
- **Epic done when:** a staging user can open, paginate, scroll, leave, and return to a representative large conversation without duplicate messages, chronology errors, or lost position.
- **Depends on:** 2.1.

**2.3 Add logged-in user settings**

- Add a settings entry that shows the authenticated user’s current account identity and provides local logout. Do not add preferences, cache management, language/appearance controls, account recovery, or account deletion.
- **Done when:** the displayed identity matches the authenticated session and logout returns safely to sign-in.
- **Depends on:** 1.2; Authentication contract.

### Milestone 3 — Sending, realtime, and message settings


**3.1 Build the text compose bar**

- Build the text-only compose bar, draft editing, validation, and the explicit handoff of a submission to the outbound queue. Attachments, voice, replies, reactions, and offline-send UX remain deferred.
- **Done when:** a user can enter, edit, discard, and submit a valid text draft from the timeline without directly issuing a competing send request.
- **Depends on:** 2.2.

**3.2 Build the ordered outbound message queue**

- Implement a durable, per-conversation queue with one ordered send stream per conversation, stable client-generated IDs, acknowledgement handling, retryable failure, and recovery after an app restart. A failed earlier message blocks later messages in that conversation until it succeeds, is explicitly retried, or is explicitly discarded.
- **Done when:** controlled send/retry/relaunch scenarios deliver messages to the server in their original per-conversation order without duplicates or silent loss.
- **Depends on:** 2.2, 3.1; Authentication contract.

**3.3 Implement resilient realtime transport**

- Build ticket acquisition, authenticated WebSocket connection, event decoding, reconnect/backoff, app lifecycle transitions, and reconciliation after reconnect.
- Persist no event solely because it was received locally; refetch/reconcile authoritative data after gaps.
- **Done when:** messages received while the app is foregrounded appear correctly through reconnect and background/foreground transitions.
- **Depends on:** 2.1, 2.2, 3.2; Authentication contract.

**3.4 Add realtime projection and update**

- Apply message, chat-order, unread, membership/deletion, and read-state events to the chat gateway and active timeline.
- Define an explicit fallback for event types the server does not emit; the Flutter client currently notes missing read-state events and incomplete reaction-list projection.
- **Done when:** controlled multi-client scenarios converge without duplicate rows, wrong ordering, or stale timeline/list state.
- **Depends on:** 3.3.

**3.5 Add sticker and reaction settings**

- Add settings surfaces for the approved sticker-pack and reaction configuration. Keep this separate from sticker/reaction message bubbles and message actions, which remain later content-specific issues.
- **Done when:** a user can view and change the approved sticker/reaction settings, and the selected state survives relaunch.
- **Depends on:** 2.3; Initial TestFlight scope contract.

### Milestone 4 — Notifications and read-state coherence

**4.1 Provision APNs and register devices**

- Configure Apple capabilities, entitlements, environments, device-token lifecycle, backend registration, and permission education UI.
- Avoid mapping browser PushSubscription/VAPID implementation directly to APNs.
- **Done when:** a physical staging device receives a test notification after opt-in and stops receiving it after logout/unregister.
- **Depends on:** Platform and release contract; 1.2; Notifications and deep-link contract.

**4.2 Route notification taps and universal links**

- Resolve notifications/deep links to the correct authenticated conversation or thread; handle cold start, locked device, expired session, unknown resource, and opt-out paths.
- **Done when:** automated and physical-device checks verify foreground, background, and terminated-app notification opening behavior.
- **Depends on:** 4.1, 2.2; Notifications and deep-link contract.

**4.3 Implement read state and unread-count reconciliation**

- Apply the agreed server read-state API/event behavior when opening, leaving, and receiving messages in a conversation.
- Verify chat-list unread state through multiple conversations and app relaunch.
- **Done when:** chat-list unread counts, conversation state, and server state converge after normal network recovery.
- **Depends on:** 2.2, 3.2; Authentication contract.

**4.4 Implement app badge ownership**

- Apply the server-authoritative badge policy across notification delivery, read state, logout, and reinstall.
- **Done when:** badge count is correct in controlled multi-chat, multi-device scenarios.
- **Depends on:** 3.4, 4.1, 4.3.

### Milestone 5 — Conversation interactions

**5.1 Add replies, reactions, and message actions**

- Deliver reply navigation/context, reactions, copy/share/report actions, optimistic state rules, server-error recovery, and accessibility labels.
- **Done when:** each selected action has a server-confirmed state and works after realtime reconciliation.
- **Depends on:** 3.4.

**5.2 Add threads and threaded unread state**

- Build thread list/detail, thread composition, parent-context navigation, unread accounting, and notification/deep-link routing if threads are MVP.
- **Done when:** a user can create and follow a thread from notification through parent and thread context without lost state.
- **Depends on:** 5.1, 4.2; Initial TestFlight scope contract.

### Milestone 6 — Discovery and group management

**6.1 Add conversation search, pins, and saved messages**

- Split this into separate issues if API behavior or interaction scope differs. Define indexing latency, result navigation, permissions, and empty/error states.
- **Done when:** selected capabilities match approved server contracts and have UI tests for result/action navigation.
- **Depends on:** 2.2; Initial TestFlight scope contract.

**6.2 Add group creation, membership, invites, and settings**

- Deliver only the approved role/permission matrix. Include invitation deep links, membership-removal handling, mute settings, and destructive-action confirmation.
- **Done when:** a permitted staging user can complete the selected management flow, while unauthorized paths are unavailable and server-enforced.
- **Depends on:** 4.2; Initial TestFlight scope contract.

### Milestone 7 — Attachment delivery

**7.1 Establish iOS media permissions and attachment selection**

- Implement Photos/camera/file selection using least-privilege permissions, attachment validation, previews, cancellation, and accessible error recovery.
- **Done when:** a user can select approved file types from the intended sources and denied permissions do not block text messaging.
- **Depends on:** 3.1; Initial TestFlight scope contract.

**7.2 Implement direct upload and attachment message sending**

- Use the server’s upload configuration and presigned upload contract. Add progress, cancellation, retry policy, cleanup behavior, and network-loss recovery.
- Confirm object-store CORS assumptions are irrelevant to native clients, while authentication/authorization and expiry remain enforced.
- **Done when:** images/files upload from a physical device and display correctly to another client; cancellation and expired upload URLs recover safely.
- **Depends on:** 7.1; Authentication contract.

**7.3 Implement image, video, and file viewing**

- Add thumbnails, full-screen viewing, playback, download/share policy, cache limits, memory behavior, and unsupported-content states.
- **Done when:** representative large and malformed media cases meet performance and error-recovery expectations on the oldest supported device.
- **Depends on:** 7.2.

### Milestone 8 — Voice and stickers

**8.1 Implement voice messages**

- Define recording format, encoding, interruption/route-change behavior, upload, waveform/progress UI, playback speed, and background audio policy.
- The existing Flutter voice package has Darwin code; evaluate it only as behavioral/reference evidence, not as a Swift implementation dependency.
- **Done when:** a user can record, cancel, send, receive, and play a voice message through headset and interruption scenarios.
- **Depends on:** 7.2; Initial TestFlight scope contract.

**8.2 Add stickers and other approved rich content**

- Implement sticker discovery/selection, download/cache policy, message rendering, order persistence, and pack-management rules.
- **Done when:** approved sticker flows work offline only to the extent explicitly designed; no implied general offline messaging support.
- **Depends on:** 7.2; Initial TestFlight scope contract.

### Milestone 9 — Data policy and quality

**9.1 Define and implement local-data policy**

- Decide what may persist locally: drafts, preferences, media cache, recent timeline pages, and search history. Define encryption/privacy, eviction, logout deletion, and account-switch behavior.
- Consider a database and offline outbox only as separately scoped work with conflict semantics and server idempotency.
- **Done when:** storage policy is implemented and tested for logout, low storage, migration, and account change.
- **Depends on:** 3.2, 7.2.

**9.2 Complete localization and iOS polish**

- Validate English, Simplified Chinese, and Traditional Chinese strings, localized truncation, native control states, and permission wording across approved user flows. No dedicated accessibility audit is in scope.
- **Done when:** localization and native-polish checks pass device-based QA for all MVP user flows.
- **Depends on:** all MVP user flows.

**9.3 Add performance, reliability, and security validation**

- Exercise launch, large timelines, image-heavy chats, reconnect storms, token revocation, background/foreground transitions, push delivery, and memory/disk limits.
- Conduct mobile threat-model review for credentials, screenshots, links, uploads, logging, and notification content.
- **Done when:** release quality bars from the Quality contract are met, known exceptions have owners/dates, and no critical security finding remains open.
- **Depends on:** all MVP user flows.

### Milestone 10 — Release readiness

**10.1 Establish release validation and hygiene**

- Establish the measured performance/reliability baseline from the production-like app; convert it into TestFlight release gates. Establish Sentry’s crash/fatal-error data-handling policy (retention, redaction, access controls, and incident ownership) and integrate its SDK without behavioral analytics. Add release checklist automation, dependency/license review, reproducible build metadata, and release notes.
- **Done when:** the TestFlight candidate meets its defined release gates, Sentry is configured under its approved data-handling policy, and the release has reproducible notes and build metadata.
- **Depends on:** 9.1–9.3.

**10.2 Run beta, triage, and App Store release readiness**

- Launch internal then external TestFlight cohorts, collect structured feedback/crashes, triage fixes, complete App Store privacy metadata/review assets/support process, and prepare rollback/kill-switch policy.
- **Done when:** go/no-go review approves the release candidate and store submission has all required operational artifacts.
- **Depends on:** 9.1–10.1.

## Suggested issue sequencing into sprints

1. **Sprint A — Foundation and authentication:** 1.1–1.3.
2. **Sprint B — Chat gateway and timeline:** 2.1–2.3. End with a minimal chat list, logged-in-user settings, and a validated read-only timeline.
3. **Sprint C — Sending, realtime, and message settings:** 3.1–3.5. End with ordered text delivery, foreground realtime updates, and sticker/reaction settings.
4. **Sprint D — Notifications and read-state coherence:** 4.1–4.4.
5. **Sprint E — Conversation interactions:** 5.1–5.2.
6. **Sprint F — Discovery and group management:** 6.1–6.2.
7. **Sprint G — Attachment delivery:** 7.1–7.3.
8. **Sprint H — Voice and stickers:** 8.1–8.2.
9. **Sprint I — Data policy and quality:** 9.1–9.3.
10. **Sprint J — Release readiness:** 10.1–10.2.

## Implementation details assigned to consuming work

- Authentication credential exchange, fixtures, security controls, and ownership belong to the M1 **Implement authentication** issue.
- APNs registration, payload/deep-link schema, and physical-device scenarios belong to M4 notification implementation.
- Foundation and hardening implementation establish performance measurements and TestFlight release gates.
- Sentry data handling and SDK integration belong to 10.1.

## Issue creation handoff

Create concrete implementation issues from milestone tasks. Split broad tasks into focused, shippable implementation slices or combine adjacent tasks where one end-to-end implementation slice is clearer. Preserve stated dependencies and product acceptance scenarios; do not require separate contract issues before implementation issues are created.
