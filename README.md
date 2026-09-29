# Chahua iOS

See the [setup guide](docs/setup.md) to prepare a development environment and sync signing assets.

## Architecture decisions

- [Why SwiftUI is not ready for this complex chat scroll host](docs/arch/swiftui-scroll-host-evaluation.md)

## Conversation timeline

iOS and macOS group consecutive non-system messages from the same sender within a calendar day, regardless of the time between messages. A date separator, unread separator, system message, or sender change starts a new group. The sender name appears on the first bubble of a group where sender names are enabled; the avatar appears on the final bubble. Adjacent bubbles have a 4-point vertical gap within a group and an 8-point gap between groups.

Message actions offer **Reactions** for published messages with reactions. On iOS and macOS, the sheet loads the full reactor list and uses horizontally scrollable emoji/count tabs with an accent underline above compact avatar/name rows. **All** groups reactions by person; up to eight populated emoji groups get individual tabs, and **More** contains the remaining populated groups. Zero-reaction groups are omitted; an entirely empty response shows the empty state. Reactor rows do not open profiles. Loading failures offer Retry.

The image viewer header shows Back, the chat/thread name above the message timestamp, and an overflow menu containing only **Save Image**. iOS requests add-only Photos access and saves the original image file; macOS uses a native Save panel with user-selected read/write access. Saving has no progress/status message, prevents duplicate requests, and reports success or failure with a transient accessible toast. Canceling the Save panel is silent. Video saving is not included.

## Notifications, camera, and incoming shares

- iOS and macOS message notifications offer **Reply**. The server must send `aps.category: "chahua"`; the separate routing envelope remains unchanged. Replies target the notification's chat/thread through the account-scoped outbox without consuming the open composer draft.
- On iOS, **Take Photo** is available from the attachment menu and attachment preview menu. Capture returns to the existing media preview for an explicit Send; cancellation preserves the draft. Camera access requires a physical device and permission. macOS retains Photos and Files.
- The iOS **Chahua** Share extension accepts text, web links, images, and videos in one unified sheet. Its media preview sits above a searchable grid of recent writable chat and thread avatars; the caption and **Send** stay on that screen with a single destination and no push navigation. Content uploads while the destination is being prepared. Sending replaces the card with a gapped activity ring, then a success checkmark before the share flow dismisses. macOS does not ship a Share extension.
- Failed content acquisition blocks sending rather than silently omitting items. A failed message request retains its destination and idempotency ID for retry.

The iOS app and extension share the session token through Keychain Sharing, not a shared plaintext file. Open the updated iOS app once to migrate an existing session before using the extension. Register `app.chahua.chat.share` only for iOS and refresh the iOS host/extension provisioning profiles with access to `$(AppIdentifierPrefix)app.chahua.chat.shared`; macOS signing requires only the app profile. Fastlane's iOS signing lanes include both identifiers, while its macOS lanes include only `app.chahua.chat`. Distribution signing and physical-device APNs/camera/share verification require those profiles.

Manual verification:

1. Leave a draft in a chat/thread, reply to its notification while Chahua is backgrounded or cold, and verify delivery to that destination without changing the draft.
2. Capture a photo from each attachment entry point, then exercise cancellation and denied camera permission; nothing should send before confirmation.
3. On iOS, from another app, share a link, text, a photo, and a video. Confirm the unified sheet keeps the preview, search/recent destination grid, caption, and Send together; exercise both chat and thread destinations, offline retry, and sign-out/account switching. Confirm the sent content in the destination and the brief success check before dismissal.

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
