# Development

[Documentation index](README.md) · [Environment setup](setup.md)

Run the commands below from the repository root.

## iOS compatibility

The app and iOS share extension require iOS 17 or later. Use native SwiftUI navigation, sheet configuration, change observation, and text input; iOS 15 compatibility adapters are not retained. First-party packages retain their own supported deployment targets, all compatible with the app's iOS 17 minimum.

Swift 6.4 can assert while resolving chained observable-object dictionary lookups in optimized builds. Keep the dictionary and lookup key in separate locals at affected sites rather than changing pin-loading or route semantics.

## Thread inbox contract

`GET /threads` returns compact rows with `chatKind` and an optional DM `peer` (`MemberSummary`), not a `participants` array. Thread-row and header avatars use that identity directly, including when the parent chat is not loaded. Full participant lists remain paginated through `GET /chats/{chatId}/threads/{rootId}/participants` in thread information.

## iOS simulator signing

Simulator builds use ad-hoc signing (“Sign to Run Locally”); they do not need device provisioning profiles. If signing `ChahuaMarkdown_ChahuaMarkdown.bundle` reports `bundle format unrecognized, invalid, or unsuitable`, clean the build folder (**Product → Clean Build Folder**) and rebuild. Older builds copied a literal `Resources` directory into the bundle root, which codesign misidentifies as a different bundle layout. The package now processes resources into the platform-appropriate layout, and the highlighter loads `highlight.js` from the bundle root.

## macOS self-updates

The directly distributed macOS app uses Sparkle's standard update UI. Only the macOS `Release` configuration enables the updater; Debug, Local, Profile, previews, fixture modes, and hosted tests do not start it. The application menu contains **Check for Updates…**, disabled when updating is unavailable.

Configure these Xcode build settings when producing an updater-enabled release:

- `CHAHUA_UPDATE_FEED_URL`: the stable HTTPS appcast URL. In an `.xcconfig`, escape the URL's `//` as `https:/$()/…` to avoid starting a comment.
- `CHAHUA_UPDATE_PUBLIC_ED_KEY`: the base64-encoded Ed25519 public key printed by Sparkle's `generate_keys` tool.

The macOS Release target configures the public key and the stable Jenkins feed:

```text
https://jenkins.codetector.org/job/chahua/job/deploy/job/macos-notarize/lastSuccessfulBuild/artifact/build/artifacts/appcast.xml
```

An unconfigured Release build disables updating and logs the missing configuration; it never falls back to Apple-code-signing-only updates. The macOS Release plist enables Sparkle's installer XPC service and requires archive-signature verification before extraction. The existing sandbox network-client entitlement handles downloads.

### Jenkins release setup

The manually triggered `chahua/deploy/macos-notarize` job uses `ci/Jenkinsfile.macos-notarize`. Install that pipeline definition in the existing standalone job; do not add automatic triggers. It needs Git, Copy Artifact, Pipeline Utility Steps, and Credentials Binding, the existing `github-app` and App Store Connect credentials, and a Secret file credential named `chahua-sparkle-ed25519`. The secret file must contain the base64-encoded raw 32-byte Ed25519 seed corresponding to the configured public key, not PEM or OpenSSH data. Keep the private key outside the repository with an encrypted backup.

Build and release a commit containing the updated Fastfile and release helpers. `ci_artifacts` exports the macOS archive using Developer ID distribution before packaging, and records the actual checkout commit in its artifact metadata. Older artifacts without this provenance or the configured updater are not eligible for promotion.

Select a successful, newer Apple build with the job's `APPLE_BUILD` Run Parameter. The release job copies its artifacts, checks out that exact commit into `release-source`, and runs `ci/macos-release.sh`. The helper verifies the app's version, identity, feed, public key, and required security settings; downloads checksum-pinned Sparkle tools; notarizes and staples; signs the final repackaged ZIP; and verifies the generated appcast signature against the app's embedded public key. The private signing credential is bound only for appcast generation, without importing it into Keychain.

The job archives `appcast.xml`, `Chahua-macOS-notarized.zip`, and notarization metadata. The stable feed follows `lastSuccessfulBuild`, while its ZIP enclosure uses that release's numbered build URL. Each successful release is marked **Keep this build forever** to protect downloads from normal retention; manual deletion or renaming the job can still break installed clients. Both feed and ZIP must remain anonymously readable over HTTPS. Jenkins downtime prevents updating but does not prevent the installed app from running.

This internal-testing feed contains only the latest release, without delta updates or historical minimum-OS branches. Promotion rejects the same or an older app bundle version, including comparison with legacy successful notarization metadata. To recover from a bad release, publish corrected code with a higher `CFBundleVersion`.

Sparkle owns automatic-check permission, scheduling, installation prompts, and relaunch. This integration does not force downloads or restarts. Users of releases without Sparkle must manually install an updater-enabled release once. A genuine signed/notarized A → B update remains required before release; a local ad-hoc build cannot establish distribution-signing or installation correctness.

## Profiling builds

Select the shared **chahua-apple Profile** scheme and use **Product → Profile** (⌘I) with a physical iOS device or **My Mac**. Both Run and Profile use the `Profile` configuration: Swift `-O` with whole-module compilation, C/Objective-C `-Os`, and matching dSYMs. The app and iOS share extension use the existing `match Development` provisioning profiles and development signing; push entitlements use the development APNs environment. Signing assets must be installed locally. Archive still uses `Release` for distribution.

The scheme enables `-scroll-profiling` and passes its launch arguments to Instruments. Disable that argument for an uninstrumented comparison. Use **Product → Profile**, rather than Run with the LLDB debugger attached, for performance measurements.

For Instruments capture steps and marker definitions, see [Scrolling performance](arch/scrolling-performance.md#capturing-scroll-traces).

## Adaptive chat layout

Chat presentation follows available window width, not device identity. Below 768pt, iOS retains its compact navigation stack. At wider sizes the conversation list and timeline appear together; desktop rows use a denser presentation while iPad keeps touch-sized controls.

The macOS main scene defaults to 800×600pt. This is a launch default, not a forced resize: native restoration can retain a user's existing window size.

Chat information opens inward: a 340pt inspector and its gutters consume timeline space without changing the window size or minimum. When the detail area cannot retain a 440pt timeline alongside the inspector, information uses a fitted modal card. This also applies in compact-width iPad windows. Resizing between modal and sidebar retains the open-info intent; a sheet dismissal caused by widening is not a user Close action. Compact iPhone information keeps its existing navigation route.
On macOS, M6 retains a floating info panel: 16pt corners, tinted material, subtle outline/shadow and 8pt top/bottom/right margins. It consumes 348pt without an additional inter-column gutter; the conversation bars provide their own 16pt clearance from the panel. The docked sidebar does not move or resize when information opens. Existing info-page content and actions are retained.

The Chat Info root shares its neutral surface, close/title header, identity, action tiles, privacy row and attachment/thread controls between sidebar and modal. Native Back remains available on pushed privacy, edit and invitation pages. macOS toolbar suppression is scoped to the modal environment only: an inline inspector must never hide the main window toolbar or traffic lights.

User profiles are always independent modal cards on macOS and iPad, including when opened from Chat Info, member lists, friend requests, saved/forwarded messages or settings. A profile opened from a Chat Info modal layers above that modal instead of replacing its page. The compact profile retains its avatar/name/handle/group badge and Message, Forum Profile and More actions; nonfriend requests, errors and disclosures remain scrollable. Compact iPhone retains pushed profile navigation where it was previously used.

Profile Close clears the selection owned by its presenter, including profiles layered above Chat Info or settings. The card receives an explicit close action rather than asking its nested navigation stack to dismiss. Its compact Close label owns the full 44pt hit region; pushed iPhone profiles retain native Back navigation.

For verification, open Chat Info wide, narrow until it becomes modal, open a profile above it, close the profile, and widen again. Info should return to the sidebar without closing; a profile opened wide must still be modal. Check Close, native nested-page Back, privacy, mute/search, member navigation, attachment kinds, threads, Message, Forum Profile and safety actions. Repeat in an iPad narrow window and verify the macOS native toolbar remains intact.

Wide timelines cap bubbles at 620pt, use 24pt side padding, and retain the user's message text size. Wide conversation-list search is always visible but remains explicitly unavailable; in-chat message search is a separate working feature.

Compact iOS chat-list pulling reveals Search before arming refresh. The native scroll bridge owns drawer insets and row displacement; do not add a second SwiftUI spacer. Refresh holds the drawer open until the request completes without focusing the keyboard. Global search remains unavailable.

New macOS windows default to 1280×800pt, constrained per dimension to the main display's usable `visibleFrame` (excluding Dock/menu bar), subject to existing content minimums. This uses only SwiftUI `defaultSize`, compatible with macOS 14; the stable scene retains native frame restoration and never resizes/recenters an attached window. Restored geometry takes precedence over the initial default. A native scene smoke opened at 1280×800 within the screen and retained a user resize/reposition to 900×650 through layout. Quit/relaunch restoration and changing display arrangements remain manual checks.

On macOS the main window retains a transparent native 52pt title band with its standard traffic lights. Only the toolbar background is hidden, not the toolbar itself; hiding the entire toolbar in a hidden-title-bar SwiftUI scene removes the window controls. The split layout extends to the top edge so there is no separate title-bar gap. No view moves, replaces or asynchronously repositions the system buttons, and no custom draggable-area bridge is installed.
Account and creation actions live in the SwiftUI sidebar title row, using 32pt frames and a 26pt account avatar. Ordinary 100pt leading padding reserves the traffic lights; trailing padding is 16pt. The content title row is 52pt tall followed by an 8pt search margin. These content controls sit beneath full-window overlays rather than above them in native toolbar items. iPhone and iPad retain their existing header presentation.
The sidebar title container remains the macOS default focus target, so opening or reopening a window does not automatically edit Search. Explicit search clicks/shortcuts and conversation-editor focus remain independent; no native first-responder reset steals user-initiated focus.
The macOS Friend Requests destination supplies the same content-layer account/Back header and a page title above its list. It hides the destination's automatic native Back item so rows and navigation controls do not overlap traffic lights in the edge-to-edge window. Returning restores the conversation-list header; iOS keeps its native navigation bar.
Verification: a temporary SwiftUI navigation smoke rendered the shared header/title/list arrangement after a push and returned to the root. All native traffic lights remained visible, and the rendered first row stayed below the header. This exercised layout with a representative row, not an authenticated friend-request fetch; verify the actual request list, account menu and Back action in-app. The temporary smoke source/executable were removed.

The macOS sidebar is full-height and defaults to 300pt wide, resizable to 340pt. It has no outer gaps, card corners, outline or drop shadow: a tinted material and a 0.5pt trailing divider separate it from the conversation canvas.
Its native List rows retain 8pt outer horizontal insets, 10pt inner horizontal padding, 40pt avatars, a 10pt avatar/text gap, a 60pt minimum height and 2pt trailing vertical spacing. Native row insets supply spacing rather than the iOS-only `listRowSpacing` API; accessibility content may increase row height.
Desktop floating glass uses explicit tint, hairlines and shadow over native backdrop material rather than OS-version-dependent Liquid Glass lenses; it approximates, rather than reproduces, CSS blur/saturation. The existing conversation canvas color is retained.

The macOS conversation header and pinned strip are structural rows above the native timeline, not floating overlays or scroll-content insets. The header is 48pt high at y12 with 16pt horizontal margins. The 36pt pin strip begins at y68, with an 8pt gap above and 12pt below; messages are clipped to the viewport beginning at y116 and cannot scroll behind these controls. Only the floating composer contributes a native timeline inset. Its 44pt attachment, editor/sticker field and microphone surfaces use 10pt gaps, 16pt side/bottom margins and separate columns; the attachment menu uses a plain button style with its native menu indicator hidden.

For manual verification, open a group on macOS or a wide iPad window, toggle the header's inspector control, and confirm the timeline contracts without moving the window edges. Narrow and widen the window with information open, then check Edit/back, Members/Media/Files/Threads, source-message navigation, search, mute, and closing. Repeat on compact iPhone and folded/unfolded Duo, including Dynamic Type. The existing `-bubble-timeline -fixture-split` diagnostic exercises the shared inspector container without production services; its info panel contains diagnostic controls rather than live group data. Launch it only after the build finishes, so verification does not run an older executable against replaced package resources.

The macOS conversation-list scroller bridge must release native references without restoring spacing or scroller settings during representable dismantling. AppKit setters and column fitting can synchronously query SwiftUI rows after their view tree has been invalidated. Restoration is reserved for switching live native views, not closing the owning List/window.

The macOS chat timeline uses a small, auto-hiding native overlay scroller rather than a persistent scrollbar gutter. The sticker-pack strip suppresses its scrollbar with `.scrollIndicators(.never)`, including when macOS is set to always show scrollbars, so its 44pt tabs retain their full height. Over that strip only, discrete vertical mouse-wheel input scrolls horizontally; precise trackpad/Magic Mouse events and native horizontal wheel input retain AppKit handling. Input outside the strip is untouched.
The synchronous AppKit wheel monitor returns only a Boolean consumed/not-consumed decision from `MainActor.assumeIsolated`. Its `NSEvent` return stays outside that closure because AppKit explicitly marks events non-Sendable under Swift 6.

For manual verification, use both a wheel mouse and a trackpad with enough sticker packs to overflow the strip. Wheel vertically over the pack tabs, swipe horizontally on the trackpad, and check the first/last pack boundaries. Repeat with “Show scroll bars: Always”; tab previews should stay centered with no horizontal scrollbar. Scroll and drag the chat timeline's overlay thumb and confirm it does not reserve a gutter.

macOS composer and caption editors route native media drops through the same attachment importer as Paste. `NSTextView` advertises attachment pasteboard types and overrides `readSelection(from:type:)`; relying only on the enclosing SwiftUI `onDrop` lets AppKit insert Finder's filename into the draft instead. Plain-text drops retain native text editing.

For manual verification, type a draft and drag an image from Finder onto the message editor: the attachment caption sheet should open with the draft intact and no filename inserted. Drop another image onto the open caption editor and confirm it appends without replacing the caption. Also check a drop onto the conversation timeline and ordinary text drag-and-drop. `ComposerFocusTests.testDroppedImagePresentsCaptionSheetWithoutChangingDraft` covers native pasteboard ingestion through actual caption-sheet presentation; physical WindowServer drag targeting still requires a manual check.

macOS Settings uses an 880×680pt ideal sheet with a dense sidebar and dirty-only bottom Revert/Save bar. Regular-width iPad uses a 940×720pt ideal sheet with touch-sized sidebar rows and a persistent top-right Save that becomes blue only with changes. Compact iPhone keeps native pushed editors. Read Receipts uses macOS radio rows and iPad checkmarks; saving split-layout settings stays on the selected page. Sign out requires native confirmation on both platforms. See [Settings editing](arch/settings-editing.md) for draft protection and verification.


## Local checks and formatting

Run the same checks locally with `bash ci/check.sh compile`, `bash ci/check.sh test`, and `bash ci/check.sh style`. Outputs live in ignored `.ci/`. Style checking uses Xcode's `swift-format`, `.swift-format` configuration, and first-party Swift files only. It is strict and read-only: existing violations must be formatted before the gate can pass; CI does not rewrite source files.

The Xcode compile and test commands use separate SwiftPM workspaces at `.ci/SourcePackages/iOS` and `.ci/SourcePackages/macOS`. Keep these destination-specific: sharing one package workspace across iOS and macOS can leave macOS-only binary artifacts such as Sparkle unresolved after the iOS build. Compile and test reuse the same workspace for each platform.

`App/` uses Xcode filesystem-synchronized source discovery, including platform subfolders such as `Features/Groups/macOS`. Keep Swift source directories out of the synchronized group's `explicitFolders`: those entries are opaque folder resources, so their Swift files are not compiled.

To format all first-party Swift files in place, including untracked files, run:

```sh
./format.sh
```

Run `./format.sh --check` to check without rewriting files. CI's `bash ci/check.sh style` calls this same check, using `.swift-format` and excluding vendored and generated code. The script also works when invoked from another directory.

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

