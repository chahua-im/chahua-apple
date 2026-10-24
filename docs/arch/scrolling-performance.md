# Scrolling performance

[Documentation index](../README.md) · [Profiling builds](../development.md#profiling-builds)

The shared chat list memoizes its ordered items and conversation-state references using complete chat/thread payloads, scope/archive preferences, and draft activity. Unrelated store or swipe-state updates reuse that projection; stable-ID edits, badges, membership changes, and draft removal still invalidate it. Genuine changes build one projection buffer and sort it in place, without intermediate filtered or decorated arrays.

DM avatar mount/unmount changes use a dedicated transport invalidation stream rather than `ChatStore`'s UI change publisher. Scrolling peers into or out of view updates the presence watch without rebuilding the whole list for unchanged chat data. Accepted server presence snapshots still publish visible state, preserving online dots, overlapping statuses during watch refresh, and last-seen label aging.

Relative list timestamps reuse a main-actor formatter and update its locale when the view environment changes, rather than constructing a formatter for each newly visible row or minute tick.

SwiftUI list, draft, search, and pin summaries use shared `Text` for ordinary formatted previews, with an explicit font/color/style bridge from the canonical Markdown renderer. Only spoiler-bearing SwiftUI summaries create the native TextKit surface required for glyph masks; ordinary rows avoid that extra representable, layout graph, and animation-lifecycle observers. Native timeline quote controls retain their existing renderer. Summary links and mentions remain inert, text selection stays disabled, and accessibility conceals spoilers.

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
| `Swipe.Created`, `Swipe.Detached`, `Swipe.Update`, `Swipe.HostContent`, `Swipe.Controls`, `Swipe.SizeFit`, `Swipe.Layout` | iOS row lifetime/churn, content reconfiguration, controls, native hosting measurement, and geometry layout. Repeated fitting is visible separately from content updates. |
| `Summary.Parse`, `Summary.Attributes`, `Summary.Bridge` | Preview projection/parsing, canonical native styling, and conversion to SwiftUI text attributes. These are not full SwiftUI text-layout or draw times. |
| `Image.MemoryLookup`, `Image.MemoryHit`, `Image.MemoryMiss`, `Image.LoadMemory`, `Image.LoadDisk`, `Image.LoadUncached` | Synchronous processed-image lookup and successful Kingfisher completion sources. An uncached result does not necessarily mean a network request; completion events do not measure download or decode duration. Inspect those stacks separately in Time Profiler. |
| `Timeline.Scroll`, `Timeline.VisibleGeometry`, `Timeline.Bind`, `Timeline.ExactLayout`, `Timeline.PreparedHit`, `Timeline.Prepare`, `Timeline.HeightBatch`, `Timeline.HeightsMeasured` | iOS scroll callbacks, visible queries, cell binding, installed-layout reuse/preparation requests, and height-settlement batches. A preparation request can still hit an underlying layout cache. |
| `Timeline.Install`, `Timeline.InstallReset`, `Timeline.InstallIncremental`, `Timeline.RowsRemoved`, `Timeline.RowsInserted`, `Timeline.RowsReloaded` | iOS synchronous snapshot installation, including change computation, native row updates, immediate layout, and anchor restoration. Reset events report the new total row count; incremental events report the requested removal/insertion/reload counts, not how many cells were actually rebound. The interval excludes deferred UIKit batch completion and subsequent display ticks. |
| `Timeline.SettleVisible`, `Timeline.SettlePasses`, `Timeline.SettleHeightChanges` | iOS synchronous visible-row height settlement. Passes include the final pass that finds no remaining height changes; height-change counts sum pending row invalidations before each layout pass, so a row can count more than once. Use these to identify repeated measure/invalidate/layout/restore cycles outside deferred height batches. |

Event occurrence counts expose repeated work; `count=` carries batch/input sizes where applicable. Interval IDs are ephemeral pairing tokens. These app markers contain only fixed operation names and numeric counts, never conversation IDs, message text, names, or URLs. Captures remain local to Instruments; system/framework tracks can contain other metadata, so review a trace before sharing it. Idle should not produce continuous row/layout activity, though incoming data and minute timestamp updates can legitimately do work.

Intervals can nest; their durations are not exclusive CPU time and must not be summed as frame time.

