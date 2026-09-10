## Project Overview

chahua-ios is the native SwiftUI client for Chahua (chat). It targets iOS and macOS.

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
- Do not introduce CocoaPods or Carthage; use SPM (remote or local under `Packages/`)
- Prefer shared SwiftUI views and controls across iOS and macOS. Use UIKit/AppKit wrappers or separate platform implementations only when a concrete requirement cannot reasonably be met with shared SwiftUI.
- Document each new or retained platform-specific UI exception near its implementation: the requirement, the SwiftUI limitation that necessitates the exception, and why the native approach is needed. Do not add custom native UI solely to reproduce behavior SwiftUI already provides.

## Verification

- Do not introduce new test fixtures unless explicitly requested by the user. Reuse existing fixtures when appropriate.
- For most new feature verification, especially look and feel and interaction behavior, request manual verification and feedback from the user rather than creating new fixtures or elaborate UI automation.
- Give the user concise verification steps and the expected behavior. Distinguish checks performed from behavior awaiting manual verification.
- Treat user-reported verification as authoritative; do not repeat checks they have already completed.
