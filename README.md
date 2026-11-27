# Chahua for iOS and macOS

The native Apple client for Chahua, with messaging, threads, media, reactions, and push notifications.

The app uses SwiftUI with native UIKit/AppKit conversation timelines. Shared Swift packages provide networking, Markdown rendering, and audio support.

Initial message loading uses grouped bubble placeholders with the PWA’s soft 1.4-second pulse. Placeholders follow the avatar and direct-message detail preferences, stop pulsing with Reduce Motion, and do not replace loaded messages during refresh or pagination.

Message link previews use optional backend-enriched metadata from full message responses and `messageUpdated` events. The Apple client renders up to three compact cards, loads only backend-cached thumbnails, and expires pending placeholders locally; it never fetches destination pages or polls for enrichment. Servers without preview metadata continue to display ordinary links. Availability depends on backend deployment.

Conversation lists load more downloaded conversations automatically near the end. Paging failures keep the visible rows and offer Retry.

Message Copy resolves mention names without changing stored content. Image-only messages can be edited to add captions while retaining their attachments. Confirmed edits return to the ordinary draft; failed updates retain the edit.

Message action menus use the same compact, two-row layout on iPhone, iPad, and Mac, with paging instead of scrolling. Sticker messages support favorites. A single image without a caption can be added to an owned sticker pack; the server checks source access and creates the sticker.

## Getting started

Follow the [setup guide](docs/setup.md) for the development environment and signing assets, then open `chahua-apple.xcodeproj` in Xcode and select an iOS or macOS destination.

## Documentation

- [Documentation index](docs/README.md) — architecture, feature behavior, and API reference.
- [Development guide](docs/development.md) — local checks, formatting, profiling, and CI.
