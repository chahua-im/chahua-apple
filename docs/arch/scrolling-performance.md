# Scrolling performance

[Documentation index](../README.md) · [Profiling builds](../development.md#profiling-builds)

The shared chat list memoizes its ordered items and conversation-state references using complete chat/thread payloads, scope/archive preferences, and draft activity. Unrelated store or swipe-state updates reuse that projection; stable-ID edits, badges, membership changes, and draft removal still invalidate it. Genuine changes build one projection buffer and sort it in place, without intermediate filtered or decorated arrays.

DM avatar mount/unmount changes use a dedicated transport invalidation stream rather than `ChatStore`'s UI change publisher. Scrolling peers into or out of view updates the presence watch without rebuilding the whole list for unchanged chat data. Accepted server presence snapshots still publish visible state, preserving online dots, overlapping statuses during watch refresh, and last-seen label aging.

Relative list timestamps reuse a main-actor formatter and update its locale when the view environment changes, rather than constructing a formatter for each newly visible row or minute tick.

SwiftUI list, draft, search, and pin summaries use shared `Text` for ordinary formatted previews, with an explicit font/color/style bridge from the canonical Markdown renderer. Only spoiler-bearing SwiftUI summaries create the native TextKit surface required for glyph masks; ordinary rows avoid that extra representable, layout graph, and animation-lifecycle observers. Native timeline quote controls retain their existing renderer. Summary links and mentions remain inert, text selection stays disabled, and accessibility conceals spoilers.

The iOS swipe row now lets its original SwiftUI content participate directly in List layout. A non-sizing UIKit overlay owns custom controls and row-filtered directional gestures on the public scroll ancestor; it no longer creates a nested `UIHostingConfiguration` or calls `systemLayoutSizeFitting` for row content. Horizontal offsets update only that row's SwiftUI state. Dynamic row sizing, content hit testing, native vertical scrolling and edge-back arbitration remain required.

Timeline prepared rows retain immutable attributed-body styling alongside their existing layout cache. Measurement and native binding reuse parsing/highlighting and natural code sizes; each TextKit graph still gets independent mutable code-attachment bounds, selection and spoiler state. Code runs are indexed when text changes, and unchanged widths skip repeated code fitting. The tradeoff is retained styling for the bounded prepared-row lifetime, not a retained TextKit graph per row. This removes duplicate work but did not materially improve the image-heavy scrolling result below.

The iOS timeline shares one visible-geometry query per scroll callback. Visibility transitions are separate from clipped-media refreshes, so tall rows suspend offscreen tiles without rebinding text, audio, or interaction handlers. Width/Dynamic Type height settlement scans pending rows incrementally and rebinds newly measured visible rows rather than every visible row on every batch. Viewport/read tracking remains synchronous.

Scroll-driven chrome has a separate `TimelineViewportPresentation` observation boundary. Visible-message dates, viewport revisions, and live-edge/direction flags still update synchronously, but do not publish a whole-model UI change. The model publishes non-viewport state transitions and row/activity changes normally. The pin bar and jump controls observe the viewport boundary directly; the macOS native chrome consumes emitted jump visibility independently. No read candidate, dwell, request serialization, or scroll-anchor work is throttled.

Chat detail's attachment, pin, mutation-error, forwarding, and deletion presentations use concrete modifier bodies with focused inputs. Computed-property splits alone retained the monolithic generic presentation type; copying the whole screen into child views or erasing it with `AnyView` is not the replacement.

iOS timeline static images cross a background display-preparation boundary before installation, including original-memory fallbacks and animation first frames. A cancellable serial queue bounds preparation; request/account/representation and preparation generations fence completion and cache writes. Account-owned, size-aware memory entries restore prepared frames immediately. Original images remain available at full resolution, and static original restoration uses native thumbnail preparation rather than full-original PNG re-encoding. Animation playback keeps its existing lazy, background-prepared frame lifecycle.

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
| `Detail.Body` | Actual chat-detail body evaluations, including parent/environment-driven invalidation. Count during an active scroll interval; an isolated model observer is not sufficient proof. |
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

## Device-trace follow-up

The supplied `timeline trace.trace` contains approximately twelve-second Animation Hitches/CPU recordings from iPhone 15 Pro Max and iPhone 13 Pro Max. These were not controlled identical workloads. The update statistics below use seconds 4–11.5 to exclude initial presentation; app-update duration is not delivered FPS, and 8.33 ms is a 120 Hz interval, not an allowance for every individual subsystem.

| Baseline measurement | iPhone 15 Pro Max | iPhone 13 Pro Max |
| --- | ---: | ---: |
| Recorded animation hitches, whole recording | 81 | 128 |
| Top-level app-update p95, ms, selected window | 19.49 | 27.34 |
| Sampled main-thread CPU inside SwiftUI graph updating, whole recording | 49.6% | 58.9% |

The older-device trace spent 4.38 seconds of sampled main-thread CPU inside SwiftUI graph updating versus 0.23 seconds inside native timeline binding. These are inclusive categories, not additive frame times. Chat detail, composer and chat-list bodies repeatedly appeared; the cost persisted beyond initial presentation. Core Animation image preparation also reached WebP decoding on main. This changed the next-fix priority from the earlier native-only simulator workload: isolate viewport publication, reduce the presentation type, and prepare static pixels before display. The trace does not prove which individual publisher caused every graph update.

Post-change proof: `.ci/TraceFix5-Profile-native.xcresult` passed both temporary native smokes in an optimized Profile build. Forty distinct viewport changes updated the narrow chrome without rebuilding its outer model-observing screen; a real unread-state change still rebuilt that consumer. The actual `ChatDetailView` traversed 180 messages forward and backward with Markdown/code, mixed-aspect single and 2/4/6/9-photo galleries, captionless photos and 120-line captions. Gallery-only native leaf checks verified 1/2/4/6/6 tiles, excluding avatars; four-photo and overflow screenshots were inspected. An earlier counter included an avatar and is not accepted as a passing gallery check. Temporary smoke source was removed afterward.

Existing image regressions plus new cached-original WebP, bounded-thumbnail/remount, original-resolution preservation and pending account-reuse cases passed in the scoped iOS run. Existing native read/geometry/model regressions also passed. The isolated smoke's unsupported saved-message-status API shows its existing retry state; this is not backend or full-shell navigation sign-off.

Physical-device performance after the fix remains unverified. Repeat the same 13 Pro Max conversation in the optimized Profile configuration, cold and warm/reverse, and compare Animation Hitches and main-thread SwiftUI/image stacks against the supplied recording. Do not claim sustained 120 Hz from the observation smoke or simulator callbacks.

Final integration: `.ci/TraceFix6-iOS-final.xcresult` passed 427 tests after temporary smoke removal; `.ci/TraceFix3-macOS-final.xcresult` passed 466 tests. Both report zero failures/skips/runtime warnings. Formatting/lint passed; existing compiler warnings remain. The obsolete `$state` publisher assertion was removed from the realtime regression while preserving its actual registration, status-transition, failed-open, reset and unregister behavior checks.

## Full-shell invalidation iteration

The supplied third device run confirmed that WebP decoding moved off main, but SwiftUI graph work remained high. The next iteration targets shared-store and parent/environment invalidation, not a frame-rate override.

- Unchanged chat/thread installations do not mutate published rows or unmatched opposite lists. Full payload equality still permits real edits, archive moves, unread changes and metadata updates. Read caching, cursor/reset fences, revisions, membership caching and timeline delivery run independently of these UI-write guards.
- Conversation-state watch scope is transport-only, like presence scope: its dedicated signal still schedules websocket watches without invalidating every store-observing view.
- Chat detail observes only its current permissions, matching thread reply count and account/session projection, plus existing independent feature controllers. Thread identifiers are parsed once rather than formatted for every list-state comparison.
- The parent route has an equality boundary over presentation/routing metadata, not unread counters or previews. Automatic unread positioning reads the current cache on appearance/open. Explicit anchors and account/reset identity still remount; normal metadata edits preserve the timeline and draft.
- Shell navigation environment closures have stable identity with refreshed imperative targets. Recreating these closures on every shell update bypassed route equality through environment dependencies. Targets are cleared on disappearance/sign-out and rebound on appearance; asynchronous forward routing rechecks the live target and account fence.

Accepted paired smokes: `.ci/Iter2-before4-native.xcresult` and `.ci/Iter2-after5-native.xcresult`, one passed each, with matching local Time Profiler/Points of Interest traces. Both mount the actual `AuthenticatedShell`, navigate through its notification route, and scroll the actual detail screen with 120 conversations and 180 messages. The workload includes Markdown/code, real mixed-aspect 1/2/4/6/9-photo attachments, captionless photos and 120-line captions. Three phases each process 120 display-tick steps: identical snapshots, real changes in an unrelated conversation, then genuine active-conversation unread/message edits.

| Full-shell measurement | Before this iteration | After |
| --- | ---: | ---: |
| Identical snapshots: shared-store UI notifications | 480 | 0 |
| Identical snapshots: actual detail body evaluations | 357 | 0 |
| Unrelated changes: shared-store UI notifications | 240 | 119 |
| Unrelated changes: actual detail body evaluations | 360 | 0 |
| Active changes: actual detail body evaluations | 15 | 4 |
| Identical-snapshot phase duration, seconds | 5.07 | 2.66 |
| Unrelated-change phase duration, seconds | 5.47 | 4.59 |

Native binding counts remain 362/358/357 across the respective phases in both variants; this is not a reduced-content workload. Genuine unread counts and edited message contents were checked after traversal. Intermediate store/route changes alone still produced 118 unrelated-change body evaluations; stabilizing environment callbacks removed that remaining path.

Both variants use optimized Profile builds with existing fixture support and testability on the same iPhone simulator. A compiler VFS overlay uses preserved pre-iteration working-tree sources, not Git HEAD or a checkout/reset; only the same `Detail.Body` marker was added to the baseline. Duplicate exported signpost tables are deduplicated. Test-bundle phase names are unresolved in the export, so the three ordered begin/end pairs are matched by signpost ID; app body markers and publication counts resolve. The temporary display driver requests 60–120 Hz only for this workload; the shipped scheduler policy is unchanged. Phase durations are not delivered FPS, physical gestures or device power measurements.

Initial harness failures from a nonnumeric notification ID, inactive scene gating and missing connected-watch setup are not passing evidence. A prior capture with ignored synthetic snapshots is excluded. The successful updated unprofiled smoke is `.ci/Iter2-aftercheck2-native.xcresult`; accepted paired runs validate the final synthetic state changes. The isolated fixture's saved-message-status error is not production backend evidence. Post-iteration device pacing still requires the next 13 Pro Max recording.



