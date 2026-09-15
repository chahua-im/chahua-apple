# Development setup

Follow these steps to prepare the Ruby and Fastlane tooling used by the project.

1. **Install and initialize rbenv.** Follow the [official rbenv installation instructions](https://github.com/rbenv/rbenv#installation), then install rbenv and Ruby builds with Homebrew and initialize it in your shell:

   ```sh
   brew install rbenv ruby-build
   rbenv init
   ```

   Complete any shell configuration step printed by `rbenv init`, then open a new shell (or reload your shell configuration).

2. **Install the repository's Ruby version.** From the repository root, install the version declared in `.ruby-version` and make sure rbenv selects it:

   ```sh
   rbenv install "$(cat .ruby-version)"
   rbenv local "$(cat .ruby-version)"
   ```

3. **Install Ruby dependencies.**

   ```sh
   bundle install
   ```

4. **Understand the automation tool.** Fastlane is the project's iOS and macOS automation tool; this project uses its Match integration to retrieve code-signing assets. Signing lanes are separate: `ios` handles iOS, and `mac` handles native macOS. Commands without a platform default to iOS.

5. **Sync development signing.** Each development sync lane is read-only: it fetches existing development profiles and certificates for the selected platform without changing Apple or the Match repository. Before running it, ask the project owner for the Match encryption password and ensure SSH access to the signing repository. Provide that password when Fastlane prompts for it. Run the command for the platform you are developing, or both if needed:

   ```sh
   bundle exec fastlane ios sync_development_signing
   bundle exec fastlane mac sync_development_signing
   ```

## Signing and direct macOS distribution

Both platforms use bundle ID `app.chahua.chat` and team `9422PL3GFR`. Development assets remain in `fastlane-development`; distribution assets remain in `fastlane-distribution`.

| Command (`bundle exec fastlane …`) | Signing assets | Remote changes |
| --- | --- | --- |
| `ios sync_development_signing` | iOS Development | None |
| `mac sync_development_signing` | macOS Development | None |
| `ios sync_distribution_signing` | iOS App Store | None |
| `mac sync_distribution_signing` | macOS Developer ID | None |
| `ios bootstrap_development_signing` | iOS Development | Create or repair |
| `mac bootstrap_development_signing` | macOS Development | Create or repair |
| `ios bootstrap_distribution_signing` | iOS App Store | Create or repair |
| `mac bootstrap_distribution_signing` | macOS Developer ID | Create or repair |

If a read-only sync reports missing or expired assets, a signing maintainer must run the corresponding bootstrap lane with Apple Developer access and write access to the signing repository. Creating Developer ID certificates requires appropriate Apple account permissions; use the Account Holder account if Apple requires it. macOS development profiles also require the development Mac to be registered with the team.

Each lane operates only on its selected platform. Missing macOS assets do not block iOS signing, and running a macOS bootstrap does not also bootstrap iOS.

Xcode uses manual macOS signing:

| Build configuration | Identity | Provisioning profile |
| --- | --- | --- |
| Debug / Local | Apple Development | `match Development app.chahua.chat macos` |
| Release | Developer ID Application | `match Direct app.chahua.chat macos` |

Run `bundle exec fastlane mac sync_development_signing` before building macOS Debug or Local; run `bundle exec fastlane mac sync_distribution_signing` before building macOS Release. iOS signing settings are unchanged. macOS sandboxing and hardened runtime remain enabled.

These lanes manage signing assets only. Public direct-download releases still need packaging, notarization, and stapling; those steps are not automated here. No installer certificate is requested because `.pkg` distribution is not configured.

## Native push notifications (APNs)

In the signed-in app, tap the account avatar, then **Enable notifications**.
Settings opens full-screen on compact iOS devices and in a sheet on larger
devices and macOS. If permission was denied, use **Open System Settings**, enable
notifications for Chahua, and return to the app to refresh registration.

Use **Disable notifications** in the same page to unregister this device through
`POST /push/unsubscribe` without signing out or changing the system permission.
The device opt-out persists across app restarts and account changes on this
server, so returning to the app does not silently subscribe again. **Enable
notifications** explicitly opts back in. Failed unsubscribe requests show an
error and remain retryable; the app does not claim notifications are disabled
until the backend request succeeds.

The client registers directly with APNs and subscribes the token through the
authenticated backend `POST /push/subscribe` endpoint. No Firebase configuration
or notification service extension is required. Sign out waits for
`POST /push/unsubscribe` before deleting the local credential; if that request
fails, sign out remains retryable rather than leaving the old account subscribed.

The backend must configure its APNs auth key and `APNS_TOPIC=app.chahua.chat`;
see the backend repository's `backend/README.md` for the required environment
variables. iOS and macOS use the same topic, with distinct APNs device tokens.

`APNS_ENVIRONMENT` controls both the platform-specific signing entitlement and
the `ChahuaAPNSEnvironment` Info.plist value used for registration:

- `development` registers with the backend's `sandbox` environment.
- `production` registers with the backend's `production` environment.

The checked-in APNs setting is `development`. For distribution, set
`APNS_ENVIRONMENT=production` **and** use matching distribution signing assets.
Changing only the subscription environment or only the signing profile is not
sufficient; a token registered against the wrong APNs environment will be rejected.

The backend supplies localized alerts and `aps.thread-id`: `chat_<chatId>` for a
main conversation and `chat_<chatId>_thread_<threadRootId>` for a reply thread.
The client preserves these native groups rather than replacing prior messages.
Read receipts remove delivered notifications only through the confirmed message
watermark in that same conversation. Badges count top-level unread messages,
excluding muted and archived chats, matching the backend.

For an end-to-end check, enable notifications on a signed device and send messages
from a second account while Chahua is inactive. Verify that two messages in one
chat group together, a different chat and a reply thread remain separate, tapping
an alert opens the referenced message (including after cold launch), and reading
one conversation leaves unrelated notification groups intact.

## Native conversation interactions

- Send a text message while the composer is focused. The editor stays enabled
  and the keyboard stays open throughout the local write; Send blocks duplicate
  submission without interrupting typing. The draft clears only after durable
  enqueue, and edits made during that write remain in the draft. Verify this on
  a physical iPhone as well as with macOS Return and the Send button.
- Touch and hold a message on iOS. The bubble starts a subtle press-in immediately;
  a 0.45-second hold commits with one light haptic and springs into the preview.
  Releasing early or scrolling restores the bubble without a commit haptic.
  The preview covers the title/header and composer and retains original wrapping
  and media size. Oversized previews clip beneath the scrollable action panel.
  Reduce Motion uses opacity instead of scaling. Verify feel on a physical iPhone.
- Right-click a message on macOS. The original message stays in place, with no
  full-window blur, dimming, or lifted duplicate. The existing reaction bar and
  action grid appear together near the message. The reaction bar is opaque white
  in light mode and opaque dark in dark mode; the action grid remains translucent.
  A short scale transition opens/closes the controls; Reduce Motion skips scaling.
  Verify the transition feel with an actual right-click.
  Selected reactions use only a darker circular background, without a dot/check;
  the pressed reaction highlight is circular too.
- Click outside the macOS menu, including the title bar, to dismiss it without
  also closing or moving the underlying window. Escape also dismisses it.
- On iOS, conversation swipe actions are 44-point icon-only circles. Trailing
  actions are **Archive** and, on chats, **Mute/Unmute**. Leading offers **Mark as
  Read** when unread and **Mark as Unread** for a read chat with a message.
  Dragging beyond the leading reveal stretches the circle into a capsule.
  Crossing the commit boundary gives a haptic; release beyond it executes.
  Retreating below the boundary disarms release-to-commit. Verify on a physical
  iPhone that vertical scrolling and aborted swipes do not execute actions.
  macOS retains standard swipe actions, including leading **Mark as Read**.
  Threads have separate archive/read actions, no mark-unread action, and no
  independent mute API. Archiving a chat also mutes it indefinitely.
- Tap/click a message's reply-count indicator to push its thread. Back returns
  to the parent conversation; reply drafts and read receipts use the thread scope.
- On macOS, Back occupies its own 44-point circular glass button, separated
  from the avatar/title capsule by 8 points, matching the iOS arrangement.
  macOS uses its native glass button style for control feedback.
- Choose **Thread** from an eligible message's action menu to start a thread.
  This opens the message-rooted conversation; sending its first reply creates
  the thread, matching the PWA. Existing threads use their reply-count indicator,
  and thread replies cannot start nested threads.
- Choose **Delete** to recall your own message, or another sender's message when
  you are an administrator. Confirm before the server mutation. The PWA's
  message terminology is preserved: **撤回** in Simplified Chinese and **收回**
  in Traditional Chinese. Accepted deletions redact shared reply previews;
  failed requests retain the original content.
- Scroll toward older history, then reverse toward newer messages. With no
  unread messages or deferred arrivals, the jump button appears only while
  moving toward newer messages away from the bottom. Unread messages keep it
  available regardless of direction. Above the current chat read boundary, the
  first tap bottom-aligns that boundary above the composer; another tap reaches
  latest. A missing boundary falls back to latest. Thread jumps go to latest.
- The jump badge is the current chat/thread's server-confirmed unread count,
  updated by read receipts and refreshed conversation metadata. Deferred arrivals
  are not added again. Opening sends the first fully visible read candidate
  immediately, including historical entry without regressing the cursor;
  subsequent advancement retains the 500 ms visibility dwell.

The existing `-bubble-timeline -fixture-split` launch mode can exercise preview
rendering without production authentication. Verify touch/trackpad gestures and
animation feel manually on both platforms; list mutations require a live session.

Native display-linked layout checks require an awake display. Keep it awake
while running them with `caffeinate -d -i xcodebuild …`; the tests wait for
display-coalesced layout before checking scroll geometry.
