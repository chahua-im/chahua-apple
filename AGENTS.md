## Project Overview

chahua-ios is the native SwiftUI client for Chahua (chat). It targets iOS and macOS.

This codebase is yours: what it's for and how it's built are your call, and you'll keep building on it.

## Project Layout

```
chahua-ios/
├── App/                      # App target source (UI, composition, resources)
├── Packages/
│   └── ChahuaAPI/            # Local Swift package — API / networking client
├── Vendor/                   # Vendored third-party source and binaries
└── chahua-ios.xcodeproj/
```

### App/

SwiftUI app target. Entry point is `ChahuaApp.swift`. Keep screens, navigation, and app wiring here. Assets live under `App/Resources/`.

The Xcode target uses a filesystem-synchronized group rooted at `App/` — files added under `App/` are picked up automatically.

### Packages/

First-party local Swift packages.

- Prefer putting reusable, non-UI logic in packages rather than the app target.

### Vendor/

Third-party code that must live in-repo (patched forks, non-SPM C/C++, binary xcframeworks).

- Prefer remote SPM when upstream supports it.
- Each vendored library: its own subdirectory with `LICENSE`, `VERSION`, and upstream source.
- Binary frameworks go under `Vendor/Binaries/`.
- See `Vendor/README.md`.

## Conventions

- Bundle ID: `app.chahua.chat`
- Swift concurrency: approachable concurrency / default actor isolation as set in the Xcode project
- Formatting: run `./format.sh` from the project root to format first-party Swift files in place, including untracked files, or `./format.sh --check` for the read-only CI style check. Both use `.swift-format` and exclude vendored and generated code.
- After implementation is complete, run `./format.sh` from the project root before reporting completion. The read-only `--check` command does not replace this formatting step.
- Do not introduce CocoaPods or Carthage; use SPM (remote or local under `Packages/`)
- Prefer shared SwiftUI views and controls across iOS and macOS. Use UIKit/AppKit wrappers or separate platform implementations only when a concrete requirement cannot reasonably be met with shared SwiftUI.
- Document each new or retained platform-specific UI exception near its implementation: the requirement, the SwiftUI limitation that necessitates the exception, and why the native approach is needed. Do not add custom native UI solely to reproduce behavior SwiftUI already provides.
- When a control needs different iOS and macOS implementations, keep a small shared wrapper that selects the platform implementation. Put each implementation in its platform subfolder rather than wrapping large view bodies in `#if os(...)`.

### GitHub issue closure

- When a change fixes a GitHub issue, include a closing keyword and the issue reference in the pull request description or commit message, for example `Fixes #23` or `Closes chahua-im/chahua-apple#23`. GitHub closes the issue when the fix merges into the default branch (`main`).
- Use a closing keyword only when the change fully resolves the issue. Use `Refs #23` for partial work.
- Do not use `Fixes issue://23`: GitHub does not recognize that reference for automatic closure.

## Localization

- Ship all product text in English, Simplified Chinese (`zh-Hans`), and Traditional Chinese (`zh-Hant`). This includes menus, tooltips, accessibility labels, notifications, errors, and the share extension.
- Use literal `LocalizedStringKey` values for SwiftUI controls and shared label parameters. A stored `String` is not automatically localized by `Text` or `Button`. Do not localize user content, server names, file names, or identifiers.
- In the app, use `AppLanguage.localized` when an API needs a resolved `String`. Do not use `String(localized:)` there: it ignores the selected in-app resource language. The separate share extension uses its own catalog and system language.
- Add complete Chinese translations in the owning target's `.xcstrings` catalog with each UI change. Preserve format argument types and positions; use positional arguments when the translation changes their order.
- Remove orphaned keys when text or features are removed. Keep `push.*` keys: remote notification payloads use these keys without Swift references. Keep property-list keys only while a target's property list uses them.
- Mark only language-neutral content with `shouldTranslate: false` and explain why in its catalog comment. Do not exempt English labels to make checks pass.
- Run `python3 ci/check-localizations.py` before completion. The CI style stage runs this check for missing or unfinished translations, format arguments, missing source keys, and orphaned keys. Source extraction is conservative and cannot prove that every dynamic string is localized; review stored labels and custom controls as well.
- Verify menus and related screens in both Chinese languages after an explicit Language Save. Standard operating-system menus can follow the system language.

## Design — circular controls and chips

- Icon-only floating action buttons, including Jump to Bottom, must be perfect circles: equal width and height with a circular outline, background, and clipping shape. Do not substitute a squircle or a continuous rounded rectangle.
- Single-character chips must be circular. Keep longer chip content circular while it fits; otherwise grow only horizontally into a capsule with semicircular ends (corner radius = half the height). Never stretch the circle into an ellipse or use rounded-square ends.
- Size these shapes from the actual content and padding, including localized text and larger text sizes. Use matching geometry for fills, borders, glass effects, and hit targets.
- Use explicit `Circle` or circular-style `Capsule` shapes for round controls and pills; a half-height radius on a continuous rounded rectangle is not equivalent. Reuse `RoundChipLayout` for content-sized SwiftUI chips rather than independently padding width and height.

## Verification

- Do not introduce new test fixtures unless explicitly requested by the user. Reuse existing fixtures when appropriate.
- For most new feature verification, especially look and feel and interaction behavior, request manual verification and feedback from the user rather than creating new fixtures or elaborate UI automation.
- Give the user concise verification steps and the expected behavior. Distinguish checks performed from behavior awaiting manual verification.
- Treat user-reported verification as authoritative; do not repeat checks they have already completed.

## Documentation
Try to keep code documentation inline when needed. Do not update `docs/setup.md` unless explicitly requested by the user.

- `docs/development.md` is a durable developer guide, not a task diary or changelog. Update it only when a change affects reusable setup, development workflows, or architectural constraints, or when explicitly requested.
- Do not append per-fix narratives, test implementation details, local test/smoke results, or one-off verification checklists to developer docs. Put verification evidence in the change description or assistant response.
- Keep non-obvious implementation rationale near the code and behavioral coverage in tests. Do not duplicate implementation constants or test assertions in developer docs.
