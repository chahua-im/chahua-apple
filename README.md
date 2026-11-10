# Chahua for iOS and macOS

The native Apple client for Chahua, with messaging, threads, media, reactions, and push notifications.

The app uses SwiftUI with native UIKit/AppKit conversation timelines. Shared Swift packages provide networking, Markdown rendering, and audio support.

Message link previews use optional backend-enriched metadata from full message responses and `messageUpdated` events. The Apple client renders up to three compact cards, loads only backend-cached thumbnails, and expires pending placeholders locally; it never fetches destination pages or polls for enrichment. Servers without preview metadata continue to display ordinary links. Availability depends on backend deployment.

## Getting started

Follow the [setup guide](docs/setup.md) for the development environment and signing assets, then open `chahua-apple.xcodeproj` in Xcode and select an iOS or macOS destination.

## Documentation

- [Documentation index](docs/README.md) — architecture, feature behavior, and API reference.
- [Development guide](docs/development.md) — local checks, formatting, profiling, and CI.
