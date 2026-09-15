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
- Long-press (iOS) or right-click (macOS) a message. The preview covers the
  title/header and composer, retains the original text wrapping and media size,
  and lifts into place. Oversized previews clip beneath the action panel rather
  than reflow; the actions remain scrollable. Reduce Motion uses fades.
- Click the covered macOS title bar: dismiss the preview without closing or
  moving the underlying window. Background taps and Escape also dismiss it.
- Swipe conversation rows from the trailing edge for **Archive** and, on chats,
  **Mute/Unmute**. Swipe from the leading edge for **Mark as Read** when unread.
  Threads have separate archive/read actions and no independent mute API.
  Archiving a chat also mutes it indefinitely, matching the backend contract.
- Tap/click a message's reply-count indicator to push its thread. Back returns
  to the parent conversation; reply drafts and read receipts use the thread scope.

The existing `-bubble-timeline -fixture-split` launch mode can exercise preview
rendering without production authentication. Verify touch/trackpad gestures and
animation feel manually on both platforms; list mutations require a live session.
