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

4. **Understand the automation tool.** Fastlane is the project's iOS automation tool; this project uses its Match integration to retrieve code-signing assets.

5. **Sync development signing.** The development sync lane is read-only: it fetches the existing development signing profile and certificate assets without changing Apple or the Match repository. Before running it, ask the project owner for the Match encryption password. Provide that password when Fastlane prompts for it, then run:

   ```sh
   bundle exec fastlane ios sync_development_signing
   ```

## Unit tests

The Xcode unit-test target runs inside the platform application. `ChahuaApp` detects the hosted XCTest process and supplies an empty window instead of constructing the production composition root. Unit-test startup must not restore a real session, access the Keychain, or start network requests.

Tests construct the models and views they exercise with injected dependencies. Authentication tests should use `InMemorySessionTokenStorage` (or a purpose-built storage test double), not `KeychainTokenStorage`. Real Keychain integration should be a separate, explicitly opted-in check.

Run the app's unit-test suite on either platform:

```sh
xcodebuild test -project chahua-apple.xcodeproj -scheme 'Debug - Prod API' -configuration Debug -destination 'platform=macOS,arch=arm64'
xcodebuild test -project chahua-apple.xcodeproj -scheme 'Debug - Prod API' -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Native macOS bubble checks

The DEBUG-only native bubble timeline uses the production table host with local messages and generated PNG, GIF, and HEIC files. It does not initialize authentication or production networking:

```sh
xcodebuild build -project chahua-apple.xcodeproj -scheme 'Debug - Prod API' -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/chahua-bubbles
open -n /tmp/chahua-bubbles/Build/Products/Debug/chahua-apple.app --args -bubble-timeline
```

The component gallery also links to this timeline. Toggle dark appearance, action hooks, and thread scope; use Queue, Sending, Fail, and Acknowledge to inspect pending-message transitions. Queue is intentionally single-use per fixture session. Video playback is deferred.

For a targeted launch, set `CHAHUA_FIXTURE_MESSAGE` to a fixture ID (for example, `fixture-0` for text, `fixture-10` for GIF/HEIC, or `fixture-19` for overflow galleries). The `-fixture-dark` argument starts in dark appearance.

`TimelineTableViewControllerTests` renders real native cells at 320, 600, and 900 points and retains PNG attachments in the XCTest result bundle. Its regressions check compact single/multiline bubbles, rendered glyph containment, caption/reply/thread reflow, dark timestamp visibility, scroll anchors, and complete row-height settlement after live resize. `MacBubbleTextLayoutTests` checks final-line metadata and drawing-appearance changes; `MacBubbleMediaLayoutTests` checks image bounds, missing dimensions, justified rows, and sixth-tile overflow.

Do not treat finding an `NSTextView`, a successful build, or a passing measurement-only test as visual proof. Inspect the native window or rendered XCTest attachments. Keep animated-image windows unoccluded while checking animation: AppKit can suspend animations in covered windows.

## macOS scrolling and divider regression checks

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
