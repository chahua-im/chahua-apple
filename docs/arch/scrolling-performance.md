# Scrolling performance

[Documentation index](../README.md) · [Profiling builds](../development.md#profiling-builds)

The shared chat list memoizes its ordered items and conversation-state references using complete chat/thread payloads, scope/archive preferences, and draft activity. Unrelated store or swipe-state updates reuse that projection; stable-ID edits, badges, membership changes, and draft removal still invalidate it. Genuine changes build one projection buffer and sort it in place, without intermediate filtered or decorated arrays.

DM avatar mount/unmount changes use a dedicated transport invalidation stream rather than `ChatStore`'s UI change publisher. Scrolling peers into or out of view updates the presence watch without rebuilding the whole list for unchanged chat data. Accepted server presence snapshots still publish visible state, preserving online dots, overlapping statuses during watch refresh, and last-seen label aging.

Relative list timestamps reuse a main-actor formatter and update its locale when the view environment changes, rather than constructing a formatter for each newly visible row or minute tick.

SwiftUI list, draft, search, and pin summaries use shared `Text` for ordinary formatted previews, with an explicit font/color/style bridge from the canonical Markdown renderer. Only spoiler-bearing SwiftUI summaries create the native TextKit surface required for glyph masks; ordinary rows avoid that extra representable, layout graph, and animation-lifecycle observers. Native timeline quote controls retain their existing renderer. Summary links and mentions remain inert, text selection stays disabled, and accessibility conceals spoilers.

The iOS swipe row now lets its original SwiftUI content participate directly in List layout. A non-sizing UIKit overlay owns custom controls and row-filtered directional gestures on the public scroll ancestor; it no longer creates a nested `UIHostingConfiguration` or calls `systemLayoutSizeFitting` for row content. Horizontal offsets update only that row's SwiftUI state. Dynamic row sizing, content hit testing, native vertical scrolling and edge-back arbitration remain required.

Timeline prepared rows retain immutable attributed-body styling alongside their existing layout cache. Measurement and native binding reuse parsing/highlighting and natural code sizes; each TextKit graph still gets independent mutable code-attachment bounds, selection and spoiler state. Code runs are indexed when text changes, and unchanged widths skip repeated code fitting. The tradeoff is retained styling for the bounded prepared-row lifetime, not a retained TextKit graph per row. This removes duplicate work but did not materially improve the image-heavy scrolling result below.

The iOS timeline shares one visible-geometry query per scroll callback. Visibility transitions are separate from clipped-media refreshes, so tall rows suspend offscreen tiles without rebinding text, audio, or interaction handlers. Width/Dynamic Type height settlement scans pending rows incrementally and rebinds newly measured visible rows rather than every visible row on every batch. Viewport/read tracking remains synchronous.

`CADisableMinimumFrameDurationOnPhone` enables the iPhone's full adaptive ProMotion range. UIKit/Core Animation still choose the rate and honor Low Power Mode and thermal limits; the app does not force a constant 120 Hz. Timeline display links remain paused without pending work.

Device verification: use an optimized build and Instruments **Animation Hitches**, **Time Profiler**, and **Power Profiler**. Compare sustained flings through the list and a long conversation, then idle/background behavior; include tall media captions, rotation, accessibility text sizes, selection, and history pagination. Simulator callback timings are not physical-device FPS or energy measurements.

## Capturing scroll traces

Launch an optimized build with the scheme argument `-scroll-profiling`, or environment variable `CHAHUA_SCROLL_PROFILING=1`. This is a launch-time switch supported in Release builds; restart after changing it. Without either switch, the signposter is not initialized and image-completion tracing callbacks are not installed. The instrumentation adds no display link, timer, observable counters, or refresh-rate override.

1. On the affected physical device, select **chahua-apple Profile** and use **Product → Profile** with the **Profile** configuration. Ensure the Profile action uses the profiling argument/environment, and retain the matching app binary/dSYM for symbolication.
2. Record **Animation Hitches** with **Points of Interest**. Filter the latter to subsystem `app.chahua.chat`, category `PointsOfInterest`. Fling through the chat list, repeat over the same rows with warm caches, open a conversation, and repeat there. Include a short idle period. Use a separate **Time Profiler + Points of Interest** capture to attribute expensive intervals; **SwiftUI** can expose repeated view-body updates.
3. Select a hitch interval and correlate it with the markers below. Compare cold and warm passes, and then remove the profiling switch for an uninstrumented device check. Profiling itself adds overhead. At 120 Hz the refresh interval is approximately 8.33 ms, not a guaranteed per-callback CPU allowance.

| Markers | Interpretation |
| --- | --- |
| `List.Snapshot`, `List.SnapshotHit`, `List.ProjectionRebuild`, `List.ProjectionInput` | Projection comparison/reuse versus rebuilding and the input row count. |
| `Presence.ScopeChanged` | A viewport consumer changed the aggregate presence watch; `count=` is its entity count. This transport signal does not publish a UI-state change. |
| `Swipe.Created`, `Swipe.Detached`, `Swipe.Update`, `Swipe.Controls`, `Swipe.Layout` | Current iOS overlay lifetime, control reconfiguration and geometry. `Swipe.HostContent` and `Swipe.SizeFit` occur only in historical/baseline captures; their nested hosting/sizing path has been removed. |
| `Summary.Parse`, `Summary.Attributes`, `Summary.Bridge` | Preview projection/parsing, canonical native styling, and conversion to SwiftUI text attributes. These are not full SwiftUI text-layout or draw times. |
| `Image.MemoryLookup`, `Image.MemoryHit`, `Image.MemoryMiss`, `Image.LoadMemory`, `Image.LoadDisk`, `Image.LoadUncached` | Synchronous processed-image lookup and successful Kingfisher completion sources. An uncached result does not necessarily mean a network request; completion events do not measure download or decode duration. Inspect those stacks separately in Time Profiler. |
| `Timeline.Scroll`, `Timeline.VisibleGeometry`, `Timeline.Bind`, `Timeline.ExactLayout`, `Timeline.PreparedHit`, `Timeline.Prepare`, `Timeline.HeightBatch`, `Timeline.HeightsMeasured` | iOS scroll callbacks, visible queries, cell binding, installed-layout reuse/preparation requests, and height-settlement batches. A preparation request can still hit an underlying layout cache. |
| `Timeline.Install`, `Timeline.InstallReset`, `Timeline.InstallIncremental`, `Timeline.RowsRemoved`, `Timeline.RowsInserted`, `Timeline.RowsReloaded` | iOS synchronous snapshot installation, including change computation, native row updates, immediate layout, and anchor restoration. Reset events report the new total row count; incremental events report the requested removal/insertion/reload counts, not how many cells were actually rebound. The interval excludes deferred UIKit batch completion and subsequent display ticks. |
| `Timeline.SettleVisible`, `Timeline.SettlePasses`, `Timeline.SettleHeightChanges` | iOS synchronous visible-row height settlement. Passes include the final pass that finds no remaining height changes; height-change counts sum pending row invalidations before each layout pass, so a row can count more than once. Use these to identify repeated measure/invalidate/layout/restore cycles outside deferred height batches. |

Event occurrence counts expose repeated work; `count=` carries batch/input sizes where applicable. Interval IDs are ephemeral pairing tokens. These app markers contain only fixed operation names and numeric counts, never conversation IDs, message text, names, or URLs. Captures remain local to Instruments; system/framework tracks can contain other metadata, so review a trace before sharing it. Idle should not produce continuous row/layout activity, though incoming data and minute timestamp updates can legitimately do work.

Intervals can nest; their durations are not exclusive CPU time and must not be summed as frame time.

## Latest matched simulator review

Accepted runs: `.ci/ScrollProfile8-grid-before.xcresult` and `.ci/ScrollProfile9-grid-after.xcresult`, with matching Time Profiler + Points of Interest traces. Both passed the same temporary native workload: 500 conversations with avatar downloads and varied previews; 400 messages mixing text, Markdown/code, single photos, mixed-aspect 2/4/6/9-photo galleries, captionless media and 120-line captions. The existing gallery displays at most six tiles; nine photos include the `+4` overflow tile. Native checks counted actual media leaves, not avatars or only tiles larger than an arbitrary size. A tall row measured 6,120 points against an 874-point viewport.

Each list/timeline phase drove offsets on display ticks for 16 seconds, traversing then reversing, with travel capped at 64,000 points. This includes asynchronous initial timeline preparation; its content size was initially zero. The callback timings include forced native layout, not GPU presentation time or physical touch latency.

| Measurement | Original iOS renderers | Current iOS renderers |
| --- | ---: | ---: |
| List callback p95, ms | 30.06 | 12.65 |
| Timeline callback p95, ms | 8.04 | 8.54 |
| Nested `Swipe.SizeFit` intervals | 3,440 | 0 |
| `Timeline.Bind` p95, ms | 8.63 | 9.21 |

The list improvement is clear; the image-heavy timeline is not materially improved and is not signed off as smooth. CPU stacks still put substantial binding work in native TextKit storage/container updates, text/code views and media-tile setup. Exact-layout cache hits and ordinary visibility queries are comparatively cheap; do not throttle viewport/read reporting to hide those costs.

Both variants used optimized `Profile` builds with testability and `DEBUG` enabled solely for existing fixture support, no debugger, on an iPhone 18 Pro simulator. An isolated compiler VFS overlay restored the original swipe wrapper, presentation/layout/text/bubble sources and matching text tests from `e132d64320ddefe2aed4514e0eb2dbc8537c1e8b`; current working-tree sources were not checked out or reset. Other current sources, including the canonical summary fast path, were shared. Overlay files and temporary harnesses were removed afterward.

Earlier file-card workloads and incorrect gallery counters are excluded from image-grid acceptance. An attempted TextKit edit batch caused the width/Dynamic Type regression to request layout while storage was editing; it was reverted, not suppressed. These local CPU traces do not certify device FPS, power, network latency, video playback, or live-presence behavior. Repeat the physical-device procedure above before claiming the timeline performance problem resolved.

