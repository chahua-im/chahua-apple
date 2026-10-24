# Apple client documentation

[Project overview](../README.md)

## Development

- [Environment setup and signing](setup.md)
- [Local checks, profiling builds, and Jenkins](development.md)

## Product planning

- [PWA → Apple feature parity plan](flutter-parity-checklist.md) — source-reviewed iOS/macOS gaps, delivery order, and acceptance criteria.

## Architecture

- [Conversation timeline](arch/conversation-timeline.md) — grouping, receipts, delivery indicators, forwarding, unread activity, and image viewing.
- [Realtime messaging](arch/realtime-messaging.md) — transport lifecycle, event reconciliation, and read progress.
- [Outbound queue](arch/outbound-queue.md) — main-app blocked-tail composition, native image preparation/uploads, FIFO delivery, and durable revocation boundaries.
- [Scrolling performance](arch/scrolling-performance.md) — list/timeline optimizations and Instruments trace collection.
- [Markdown rendering](arch/markdown-rendering.md) — supported syntax, native text layout, and spoiler behavior.
- [Notifications and sharing](arch/notifications-and-sharing.md) — notification preferences, camera capture, and incoming shares.
- [Why SwiftUI is not ready for this complex chat scroll host](arch/swiftui-scroll-host-evaluation.md) — the native timeline-host decision.

## Backend API

The checked-in [OpenAPI specification](openapi.json) can be refreshed from:

```text
https://wchat.codetector.org/_api/api-docs/openapi.json
```

From this directory, run:

```bash
curl "https://wchat.codetector.org/_api/api-docs/openapi.json" -o openapi.json
```
