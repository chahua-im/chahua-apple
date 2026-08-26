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

First-party local Swift packages. Today there is only **ChahuaAPI** (`Packages/ChahuaAPI/`), linked by the app target.

- Prefer putting reusable, non-UI logic in packages rather than the app target.
- Do **not** add extra packages (e.g. Core, Chat, UI) unless the user asks — keep the surface small for now.
- Package platforms should match the app: iOS 16+, macOS 13+.

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
