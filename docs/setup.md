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

## Unit tests

The Xcode unit-test target runs inside the platform application. `ChahuaApp` detects the hosted XCTest process and supplies an empty window instead of constructing the production composition root. Unit-test startup must not restore a real session, access the Keychain, or start network requests.

Tests construct the models and views they exercise with injected dependencies. Authentication tests should use `InMemorySessionTokenStorage` (or a purpose-built storage test double), not `KeychainTokenStorage`. Real Keychain integration should be a separate, explicitly opted-in check.

Run the app's unit-test suite on either platform:

```sh
xcodebuild test -project chahua-apple.xcodeproj -scheme 'Debug - Prod API' -configuration Debug -destination 'platform=macOS,arch=arm64'
xcodebuild test -project chahua-apple.xcodeproj -scheme 'Debug - Prod API' -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Shared native bubble checks

Both platforms use `TextMessageBubble` for sender, reply, media, body, and thread composition. `BubbleTextContent` shares mention/link formatting, TextKit geometry, metadata placement, and caches; only native text-view interaction and drawing use AppKit/UIKit adapters. macOS retains its direct text-only measurement fast path.

iOS visible cells and measurement roots use the same `TimelineBubbleHostingController` with `safeAreaRegions = []`: the collection view owns screen insets, and scrolling a row under a safe-area boundary must not change its height. Both hosts supply viewport, current-user, and thread context. Viewport-height changes reflow media without discarding unrelated text-height caches.

The DEBUG-only bubble timeline uses the production native host with local messages and generated PNG, GIF, and HEIC files. It does not initialize authentication or production networking:

```sh
xcodebuild build -project chahua-apple.xcodeproj -scheme 'Debug - Prod API' -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/chahua-bubbles
open -n /tmp/chahua-bubbles/Build/Products/Debug/chahua-apple.app --args -bubble-timeline
```

On a booted iOS simulator:

```sh
xcodebuild build -project chahua-apple.xcodeproj -scheme 'Debug - Prod API' -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/chahua-bubbles-ios
xcrun simctl install booted /tmp/chahua-bubbles-ios/Build/Products/Debug-iphonesimulator/chahua-apple.app
xcrun simctl launch --terminate-running-process booted app.chahua.chat -bubble-timeline
```

The component gallery links to this timeline on both platforms. Toggle dark appearance, action hooks, and thread scope; use Queue, Sending, Fail, and Acknowledge to inspect pending-message transitions. Queue is intentionally single-use per fixture session. Video playback is deferred; the existing iOS image loader remains static for animated images.

For a targeted launch, set `CHAHUA_FIXTURE_MESSAGE` to a fixture ID (for example, `fixture-0` for text, `fixture-10` for GIF/HEIC, `fixture-19` for overflow galleries, or `fixture-24` for a text reply followed by a deleted quote). For `simctl launch`, prefix the environment variable with `SIMCTL_CHILD_`. The `-fixture-dark` argument starts in dark appearance.

Use `fixture-6` to inspect image-only sender headers in both appearances: incoming headers use the normal incoming bubble background, and outgoing headers use blue with white text. Images retain their overlaid timestamps and tail-free shape; bare media without a sender, reply, or thread section remains background-free.

`TimelineTableViewControllerTests` renders real native cells at 320, 600, and 900 points and retains PNG attachments in the XCTest result bundle. Its regressions check compact single/multiline bubbles, rendered glyph containment, caption/reply/thread reflow, dark timestamp visibility, scroll anchors, and complete row-height settlement after live resize. `TimelineCollectionViewControllerTests` checks Dynamic Type, width changes, failed-message rendering/acknowledgement, and reply/media row measurements across viewport-height-only changes. `BubbleTextLayoutTests` runs shared final-line geometry checks on both platforms and native selection/action checks in each adapter; `BubbleMediaLayoutTests` checks image bounds, missing dimensions, justified rows, and sixth-tile overflow on both.

Do not treat finding an `NSTextView`, a successful build, or a passing measurement-only test as visual proof. Inspect the native window or rendered XCTest attachments. Keep animated-image windows unoccluded while checking animation: AppKit can suspend animations in covered windows.

## macOS scrolling and divider regression checks

The expanded Apple chat shell uses a permanently visible, rounded material sidebar and an in-content floating conversation header. Both are inset 12 points from the content edges; drag the 12-point gap to resize the sidebar (280–400 points, constrained to preserve a 440-point conversation). The gap also supports accessibility width adjustment. Refresh and Account are inside the sidebar. Compact iPad windows retain a Chats back button, and iPhone retains stack navigation. The split diagnostic renders the same sidebar surface and conversation header; its controls and messages are local fixtures rather than a signed-in session.

On macOS/iOS 26, floating surfaces use native Liquid Glass; older systems use regular material. The conversation viewport extends behind the header and its top margin. A measured header height feeds native scroll-content and indicator insets, keeping the oldest message clear of the header without shrinking the viewport. Content is clipped before the floating header is overlaid, and sidebar content is rounded before glass is applied. Do not clip the enclosing panes: that cuts glass shadows into rectangular corners. Inactive compact panes are explicitly hidden and excluded from hit testing/accessibility.

`ConversationTimelineView` owns clipping of the timeline content only. Neither `ChatHeaderOverlay` nor `ChatComposerOverlay` may clip its input: these modifiers nest, so clipping in either one can cut off another floating control's glass shadow at the rectangular detail boundary.

Keep the floating sidebar above the detail pane in stacking order. The native timeline has an opaque background; drawing it over the sidebar shadow creates a hard color seam at the pane boundary even without clipping.

On macOS, geometry-changing clip-view bounds notifications occur inside AppKit's layout transaction. Defer timeline placement to the controller's completed layout pass; scrolling within that notification can be overwritten by AppKit's top-inset adjustment. The opening regression test mounts the production SwiftUI split/header hierarchy and verifies that the latest message is bottom-aligned without user input.

For visual checks, inspect light and dark appearances, scroll messages behind the header, and scroll to the oldest edge to check its clearance. The split fixture keeps diagnostic controls in the sidebar so they do not interrupt the production underlap geometry.

The jump-to-latest control uses a plain button with a circular interactive glass surface on macOS/iOS 26 and circular material on older systems. Keep the unread badge outside the glass effect; a default macOS button bezel adds an unwanted rectangular backdrop.

The composer floats over the conversation with separate glass attachment/action circles and a rounded, growing text field containing the smiley. Its measured height becomes native bottom content/scroller clearance; the jump-to-latest control sits above it. Empty input shows the disabled microphone; any nonempty draft shows the paper-plane Send control, with whitespace-only drafts still unsendable. Text submission, Return/Shift-Return, and native input-method handling retain their existing behavior. Attachment, emoji, and voice features are intentionally disabled in this design-only pass.

The local timeline fixture includes the production composer: submission records the draft in the diagnostic status and clears it without contacting the server. Check empty/nonempty transitions, multiline growth, light/dark appearance, and latest-message clearance when changing its height.

The split diagnostic uses the production `ChatSplitLayout` and native timeline. Add `-fixture-split` and set `CHAHUA_PERFORMANCE_ROWS=300` to exercise a loaded history of wrapped messages alongside the media fixtures:

```sh
CHAHUA_PERFORMANCE_ROWS=300 /tmp/chahua-bubbles/Build/Products/Debug/chahua-apple.app/Contents/MacOS/chahua-apple -bubble-timeline -fixture-split &
fixture_pid=$!
swift scripts/macos-split-smoke.swift "$fixture_pid"
```

Build `/tmp/chahua-bubbles` with the command above first. The smoke script requires Accessibility/input-posting permission for the invoking terminal and a diagnostic window at least 900 points wide. It sends real mouse input and reads the rendered divider's accessibility geometry after each move. Do not switch windows or use the pointer during the check; losing fixture focus aborts further drag input. The script releases the mouse and restores the original pointer position when it finishes.

The smoke checks successive pointer tracking, reversal, both sidebar clamps, release stability, and a fresh gesture after clamping. It uses a one-point tolerance for screen-coordinate rounding. This is intentionally separate from hosted unit tests: synthetic `NSEvent` delivery inside XCTest does not reliably reach SwiftUI's drag recognizer on all macOS versions.

The hosted `TimelineTableViewControllerTests` cover the other half of the interaction: the split environment reaches the native host, offscreen heights remain deferred during dragging, newly visible rows have exact heights, overlapping window/split resize lifecycles remain independent, and every row converges to exact final-width geometry afterward. They also check history-anchor/bottom attachment throughout cooperative settlement, including a reentrant message edit and another resize. Native text tests check selection preservation and replacement/removal of link actions.

For frame pacing, record the fixture with Instruments' **Animation Hitches** template while scrolling and dragging/releasing the divider:

```sh
xcrun xctrace record --template 'Animation Hitches' --attach "$fixture_pid" --time-limit 20s --output /tmp/chahua-scroll.trace
```

Use an unoccluded window and a fresh trace output path. Inspect rendered-update cadence and main-thread stalls, including mouse-up—not just average CPU use. A 60 fps frame budget is 16.7 ms; passing correctness checks or observing no stalls above the template's 33 ms reporting threshold does not establish that every frame meets that budget.

The macOS host measures visible/overscan rows during resizing. After release, offscreen corrections run in cooperative batches (at most 32 rows, with a 4 ms measurement budget), preserving the current reader anchor between batches. A new resize cancels the previous settlement pass; data or geometry changes restart it against the current revision. The budget bounds measurement work between yields, not the cost of a single complex row or AppKit layout.

## Cached image revalidation

`CachedImageView` displays eligible expired images while refreshing through the shared media cache. A decoded-memory hit is immediately available; a disk-only hit is validated and decoded before waiting for HTTP. Failed refreshes retain the displayed image. Explicit removal, corruption, eviction, and account changes revoke it. `no-store` remains non-retained, and `no-cache` / `must-revalidate` do not permit stale reuse.

The raw `MediaCache.file(for:)` API still requires freshness. Image presentation uses the separate cache-only `cachedFile(for:allowingStale:)` path and observes semantic invalidations. Old cache metadata without a recorded revalidation policy conservatively requires a response establishing that policy before expired reuse is allowed.

Run `swift test --package-path Packages/ChahuaMediaCache` for cache/lease regressions. Run the app suites `MediaImageLoaderTests`, `CachedAvatarPresentationTests`, and `MediaHostingTests` on both macOS and iOS Simulator. The hosted scenarios check old pixels during a suspended shared refresh, replacement pixels after completion, offline retention, explicit removal, and account isolation—not just loader completion.
