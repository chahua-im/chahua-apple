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
