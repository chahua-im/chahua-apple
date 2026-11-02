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

Initial harness failures from a nonnumeric notification ID, inactive scene gating and missing connected-watch setup are not passing evidence. A prior capture with ignored synthetic snapshots is excluded. The successful updated unprofiled smoke is `.ci/Iter2-aftercheck2-native.xcresult`; accepted paired runs validate the final synthetic state changes. The isolated fixture's saved-message-status error is not production backend evidence.

On 2026-10-26 the user verified that scrolling in the updated client is “a lot lot better.” This confirms qualitative interactive improvement; the feedback does not specify measured FPS or power. Further physical tracing is optional for residual hitches, not a prerequisite for accepting that observation. Keep unrelated functional acceptance checks separate.

Final interaction smoke `.ci/Iter2-after6-interactions.xcresult` passed: genuine permission events disabled and restored the native composer, and a message's profile action opened the native peer-profile sheet through the stable environment callback. The profile API fixture is unsupported; this verifies routing, not live profile data.

Final integration: `.ci/Iter2-iOS-final.xcresult` passed 430 tests after temporary workload removal; `.ci/Iter2-macOS2-final.xcresult` passed 469. Both report zero failures/skips/runtime warnings. The final macOS build also succeeded after explicitly matching the async environment callback's MainActor/Sendable contract. Formatting/lint passed; existing compiler warnings remain. Temporary workload source, local recording gate and compiler-overlay inputs were removed.



## macOS native timeline iteration

Static delivery indicators retain their shared SwiftUI graph while native clipping/hiding conceals recycled rows. Only the sending spinner mounts/unmounts with visibility, so offscreen animations still stop. Rebinding an unchanged decoration compares every visual input before replacing its hosting root. Code attachments synchronize when applied text/geometry changes or selection resets, not again during native layout. Text selection and current link callbacks retain their existing update path.

Animated native jumps use a separate `TimelineDisplayScheduler` instead of a 16ms sleep loop. This keeps animation writes aligned with the view's display without replacing the table-install scheduler's pending transaction. Elapsed-time easing, generation fences, user-scroll cancellation and height-settlement completion remain intact.

Matched optimized Profile runs: `/tmp/chahua-mac-perf-before-6.xcresult` and `/tmp/chahua-mac-perf-after2.xcresult`. Both used 400 messages mixing ordinary text, Markdown/links and twelve-line code blocks in a 900×700 native window, a 120-step warm traversal, then 360 forward/reverse steps over the same 32,000pt range. Callback timings include forced native layout and transaction flushing; they are not GPU frame times.

| Measurement | Before | After |
| --- | ---: | ---: |
| Scroll callback mean, ms | 8.01 | 7.86 |
| Scroll callback p95, ms | 13.10 | 13.23 |
| Delivery hosting-root replacements during traversal | 930 | 0 |
| Code viewport applications during traversal | 232 | 116 |

The redundant work is removed, but callback latency is not materially improved; this does not certify that the reported stutter is resolved. A local Time Profiler capture still shows substantial native row binding, TextKit/height preparation and drawing work. The workload contains no images/video and does not mount the full authenticated shell.

Both harnesses select the existing 60Hz run-loop fallback for repeatability, including a genuine near-live-edge animated jump that completed at the bottom. This verifies animation completion, not production display-link cadence or delivered FPS. A separate final real-display attempt could not obtain a visible native window; its occlusion precondition failed and is not passing evidence. The native post-traversal bitmap was inspected: text, code blocks, timestamps and static delivery checks remained visible.

The baseline restores only the three changed macOS rendering/host sources through a compiler VFS overlay, from a preserved pre-edit copy; other current sources are shared. Both builds use `-O`, whole-module compilation, testability and existing fixture support. Ad-hoc test-host signing disables hardened runtime and adds the generated package-framework runpath only in these commands. Temporary counters, workload sources and overlay inputs are removed after verification; no profiling counter ships.

Full integration after removing the temporary repository sources: macOS ran 495 tests with zero failures and seven GUI-activity skips; iPad ran 441 tests with zero failures. These suites include native selection/link actions, code horizontal scrolling/theme changes, metadata rendering, resize/anchor/read behavior and user cancellation of animated jumps. Profile Close also passed earlier native center-click checks for initial, reopened and nested-above-Chat-Info presentations; later GUI availability does not constitute a new passing interaction check.

## Supplied macOS 120 Hz trace

`trace-macos.trace` records 11.9 seconds of the user's scrolling in two conversations. It contains 150 hitch entries and 302 app-update intervals: p95 18.84ms, maximum 75.95ms, with 112 updates exceeding the 8.33ms interval at 120Hz. App-update duration is not delivered FPS. The recorded executable is a Debug build with SwiftUI view debugging, Metal validation, Main Thread Checker and backtrace recording enabled; do not use that configuration for refresh-rate acceptance.

Resolved CPU samples put work in native row binding and repeated environment/installation checks, but also in SwiftUI graph updates, hosting-view layout and sidebar row sizing outside the timeline. The previous root-write guards did not remove the retained hosting graphs themselves.

This iteration changes macOS only:

- Sidebar swipe content stays in its original SwiftUI tree. A non-sizing native overlay retains phased wheel/momentum and mouse-pan arbitration, circular buttons and accessibility. The nested `NSHostingView`/`AnyView` and synchronous `fittingSize` measurement are removed.
- Static delivery icons use a 64-entry bounded cache of snapshots from the canonical shared SwiftUI renderer. One offscreen host renders misses with the local native appearance; only sending retains a per-row live animation host. Keys include fitted size, backing scale, appearance and resolved colors.
- Code view reuse retains native TextKit graphs and pools at most four emptied code views per text surface. Identity changes reset selection and horizontal offset even when the attachment object is unchanged. Unchanged-message updates preserve interaction.
- Layout-environment lookup reuses unchanged font/locale results. Geometry, text-size choice, language, avatar/detail/selection settings and layout direction remain in its identity; locale/time-zone notifications invalidate it. Viewport/read and clipped-media reporting are not throttled.

Accepted comparison: `/tmp/chahua-mac-120-before2.xcresult` and `/tmp/chahua-mac-120-after3.xcresult`. Both use optimized `-O` whole-module Profile builds, existing timeline fixture factories, a 900×700 native timeline beside a 300pt sidebar with thirty actual swipe rows, and 400 messages mixing text/Markdown/links and twelve-line code blocks. A 120-step warm traversal precedes two 360-step forward/reverse traversals over 32,000pt; the second also invalidates the sidebar's observed revision each step. This is a render/layout stress workload, not the authenticated shell or a replay of the user's conversations.

| Native callback measurement | Before | After |
| --- | ---: | ---: |
| Timeline-only mean, ms | 8.64 | 8.08 |
| Timeline-only p95, ms | 14.02 | 11.98 |
| Timeline-only callbacks over 8.33ms, out of 360 | 200 | 170 |
| With sidebar updates mean, ms | 10.84 | 10.24 |
| With sidebar updates p95, ms | 15.75 | 13.81 |
| With sidebar updates callbacks over 8.33ms, out of 360 | 266 | 291 |

The p95 improvement is repeatable in the earlier after run (12.22ms / 13.87ms), but the update-heavy distribution does not uniformly improve. Both p95 values remain above 8.33ms. **This is not 120fps sign-off.** These callbacks include forced native layout/transaction flushing and use the scheduler's existing run-loop test fallback; they exclude GPU presentation and physical input latency. No images/video are included.

The native post-traversal bitmap was inspected for sidebar content, code, timestamps and static delivery glyphs. Existing rendering regressions plus new canonical-ink/appearance/fitted-size and code-interaction-reset regressions passed in the targeted optimized run. The temporary wheel-event smoke could not construct the required native phases; its failed input precondition is not passing gesture evidence. Accessibility/input-posting permission is unavailable, so physical routing remains a manual check. No crash-on-GUI-precondition helper was used.

To verify the goal, select **chahua-apple Profile → Product → Profile**, rather than attaching Instruments to a Debug Run. Repeat the same two conversations cold and warm with back-and-forth scrolling, and compare Animation Hitches, app-update intervals above 8.33ms and CPU stacks. Also check horizontal sidebar swipes versus vertical scrolling/navigation clicks, resizing, dark/high-contrast delivery checks, and code selection/horizontal scrolling. The native display-link policy remains system-adaptive: its [default range follows the display's maximum refresh rate](https://developer.apple.com/documentation/quartzcore/cadisplaylink/preferredframeraterange), not a new fixed 60Hz or forced 120Hz loop. OS power/thermal/accessibility policy can still lower cadence.

The pre-edit App sources were preserved without checkout/reset, and a compiler overlay restored the five changed source files for the baseline. Temporary workload sources and overlay inputs are removed after verification. No benchmark counters or input simulation ship.

Final integration: `/tmp/chahua-mac-120-final.xcresult` ran 497 tests with zero failures and seven existing GUI-activity skips after temporary source removal. The canonical delivery-ink and code selection/scroll-reset regressions passed. No view-update publication warning appeared in this run. `./format.sh --check` passed. iOS rendering/swipe implementations are intentionally unchanged.

## Run 3: macOS chat-list scrolling

Run 3 in the same supplied trace records 6.18 seconds of sidebar scrolling: 22 hitch entries and 45 outer app-update spans, with p95 131.59ms and maximum 219.60ms. Nested update records are excluded from those duration statistics. It is still the Debug executable, not an optimized Profile capture.

Of 3,389 main-thread CPU samples, inclusive stacks contain SwiftUI graph updates in 2,040 samples, native automatic row-height updates in 729, `ChatListView.swipeRow` in 266, localization in 207, and native swipe `configure` in 148. These overlap; they are not independent percentages to sum. This points to list graph/layout churn, not a reason to force a different display-link rate.

The chat-list changes keep native SwiftUI `List` and existing dynamic row sizing:

- Named swipe rows leave callback/navigation/busy/reveal state outside the equality boundary around row visuals. Equality includes the complete item, draft, pending/selection state, localization identity and snapshots of store-derived mute, badge and sender values. Avatar presence and receipt children retain live observation; minute-based activity labels remain live.
- A retained action palette resolves localized values once per selected language/locale/system-language key. Unread, thread/read-through and archive eligibility are still evaluated from current inputs.
- Unchanged closed native swipe rows refresh callbacks without starting another close animation or requesting layout. Identity, actions, busy state and direction changes still update native geometry/buttons. Gesture ownership and cancellation behavior are unchanged.

Accepted optimized comparisons: `/tmp/chahua-run3-list-before4.xcresult` versus `after4`, repeated as `before5` versus `after5` with the same filename prefix. Each hosts the actual `ChatListView` at a geometry-asserted 360×800pt, with 400 group/text rows built from existing test factories. After 120 warm steps, 360 forward/reverse steps traverse 24,000pt, forcing native layout and transaction flushing with an 8ms run-loop yield. Original sources are supplied to the baseline through a compiler overlay, without checkout/reset. Ranges below are the two observed runs, not confidence intervals.

| Native list stress measurement | Before | After |
| --- | ---: | ---: |
| Whole-process CPU for measured traversal, seconds | 17.56–19.82 | 7.90–10.92 |
| Forced-layout callback mean, ms | 46.85–52.96 | 20.30–28.73 |
| Forced-layout callback p95, ms | 59.19–59.95 | 44.53–51.98 |
| Callbacks exceeding 8.33ms, out of 360 | 360 | 360 |

CPU work decreased in both matched pairs, but **this does not meet the 120Hz budget**. Callback timings include synchronous forced layout and exclude GPU presentation and physical input latency. The workload is offline text/group content, without remote avatars or the authenticated shell. Earlier undersized-host measurements are rejected; only the full-sized, geometry-asserted runs above are accepted. The post-traversal native bitmap was inspected, composited on white to make its transparent background readable.

The forced-layout smoke emits an `NSTableView` reentrancy warning during initial mounting both before and after; this change does not claim to resolve that warning. Focused action-language/eligibility/visual-invalidation regressions and a temporary native closed-update/detach smoke passed. The latter is not physical swipe evidence. Temporary workload sources, overlay inputs and diagnostic smoke are removed; no profiling counters ship. Repeat physical ProMotion scrolling in an optimized Profile capture and check horizontal swipe ownership, vertical scrolling and navigation before refresh-rate acceptance.

Final integration after removing temporary sources: `/tmp/chahua-run3-mac-final.xcresult` ran 500 tests with zero failures and seven existing skips; `/tmp/chahua-run3-ipad-final.xcresult` ran 444 tests with zero failures. Neither full-suite log contained a view-update publication warning. `./format.sh --check` passed.

## Run 4: remove macOS per-cell hosting and marker graphs

Run 4 records 5.40 seconds, 36 hitch entries and 110 outer app-update spans. Outer-update p95 is 70.70ms and maximum 112.51ms. It still attaches to a Debug executable with view debugging enabled. The shorter tail agrees with the user's improvement report, but different gestures/durations prevent treating the hitch counts as a controlled before/after FPS comparison.

The 2,843 main-thread samples include `NSHostingView.layout` in 1,847, AttributeGraph update-stack work in 1,790, automatic table-row-height updates in 460, swipe configuration in 123, hidden button configuration in 81 and button initialization in 59. These are overlapping inclusive stacks. SwiftUI view-struct nesting alone does not imply extra hosting views; the concrete remaining hierarchy cost was `List`'s native table and per-cell hosting/sizing.

This iteration:

- Uses `ScrollView` + `LazyVStack` on macOS instead of `List`, preserving shared variable-height row content, action/navigation callbacks, selection and explicit sidebar insets. iOS retains `List`. This removes the native table-height/per-cell-host path without implementing a custom AppKit data source or hardcoding row heights.
- Replaces macOS per-row scroll/scroller marker bridges with one viewport bridge, including empty/loading content. Public geometry identifies the owned `NSScrollView`; cached ownership is geometry-validated, without repeated row-tree traversal or private SwiftUI class names. Remounts adopt one driver, and pending restoration targets survive scope/search transitions.
- Defers native swipe clips, layers and action buttons until the corresponding side is actually revealed. Closed-row updates still refresh callbacks and action values. Hidden controls do not allocate/configure just because a new row enters the viewport.

The optimized 400-row, 360×800pt, 120-warm/360-measured-step workload from Run 3 is retained. `/tmp/chahua-run4-before.xcresult` uses exact pre-iteration sources through a compiler overlay. `/tmp/chahua-run4-native-list.xcresult` isolates deferred controls/single markers while retaining `List`; `/tmp/chahua-run4-ready.xcresult` exercises the completed scrolling-tree cutover and passes all five temporary render/interaction/lifecycle scenarios.

| Forced-layout stress measurement | Before | Native reductions, still List | Lazy scrolling tree |
| --- | ---: | ---: | ---: |
| Measured traversal CPU, seconds | 17.67 | 14.41 | 7.16 |
| Callback mean, ms | 47.50 | 39.25 | 19.13 |
| Callback p95, ms | 55.54 | 49.63 | 21.47 |
| Callbacks over 8.33ms, out of 360 | 360 | 360 | 358 |

This stress path forces layout/transaction flushing while moving approximately 133pt per callback; it does not measure delivered FPS or replay the user's gestures. It still exceeds the 120Hz budget. The new actual-view smoke asserts one viewport marker, no `NSTableView`, overlay scrollers and active native offset observation. Its bitmap was inspected with transparency composited onto white.

A separate Time Profiler capture, `/tmp/chahua-run4-flat-cpu.trace`, successfully saved despite the recording command timing out during shutdown. The matching workload `/tmp/chahua-run4-flat-profile.xcresult` passed (CPU 7.36s, callback p95 21.94ms). This capture includes warm-up/setup as well as measured scrolling; its 12,393 main-thread samples still predominantly traverse the single root hosting view's SwiftUI graph/layout machinery (`NSHostingView.layout` 8,658, AttributeGraph update stack 6,727, layout-engine sizing 2,097). Those stacks are not evidence that per-cell hosting remains, nor proof of GPU presentation timing.

Temporary native smokes construct phased wheel events and click real action buttons, and exercise viewport discovery/rejection, ownership transfer, resize, teardown and scope/search restoration. The initial wheel helper encoded AppKit phases as CoreGraphics phases; its invalid input was corrected. A live-owner style-restoration scenario was also corrected to keep the departing viewport alive, exposing a real stale-geometry cache bug that is now guarded. Deferred scroller-scope release also prevents replacement backgrounds from recapturing modified overlay/autohide settings as native defaults. All five final diagnostic scenarios pass; earlier failed scenarios are not passing evidence. The temporary sources and compiler-overlay inputs are removed. Physical swipe arbitration, VoiceOver/navigation and authenticated ProMotion scrolling still require a Profile run on the actual app.

A permanent macOS regression in `ConversationScopeTests` checks that detach immediately disables reconciliation while retaining original native policy for replacement adoption. It uses actual AppKit views in the existing test class, with no new fixture. The final lifetime guard does not alter the measured steady-state scrolling path.

Final integration: `/tmp/chahua-run4-mac-release-check.xcresult` ran 501 tests with zero failures, including the teardown/replacement regression. `/tmp/chahua-run4-ipad-final.xcresult` ran 444 tests with zero failures; the final follow-on guard and regression are macOS-only. Neither full-suite log contains a view-update publication warning. `./format.sh --check` passes.

## Profile build: mixed scrolling on a 60Hz display

`Untitled2.trace` records 22.22 seconds and confirms the Profile executable, without the previous Debug view/backtrace instrumentation. The user identifies the display as 60Hz. There are 97 hitch entries (hitch-duration p95 50.00ms, maximum 150.01ms) and 447 outer app-update spans (p95 25.24ms, maximum 126.36ms; 75 above 16.67ms). Hitch duration and app-update duration are different measures; neither is delivered FPS.

CPU stacks attribute the following approximate windows, rather than recorded input annotations:

| Window | Predominant activity | Outer updates | Update p95, ms | Updates over 16.67ms |
| --- | --- | ---: | ---: | ---: |
| 8–15s | Chat list | 179 | 26.66 | 48 |
| 15–19s | Conversation transition and scrolling | 143 | 19.11 | 14 |
| 19–22.22s | Chat list | 101 | 21.54 | 13 |

The sidebar remains the principal steady-scrolling concern. In its targeted 8–15s and 19–21s windows, inclusive stacks contain 609 lazy-placement samples, 555 lazy-stack length/spacing samples, 193 index/position resolutions and 176 backward measurements. Row-body samples total only 41, summary-body samples 24, scope callbacks four and native swipe-container layout zero. These overlap; the evidence points to variable-height lazy placement/remeasurement, not an observer feedback loop or hidden swipe buttons.

A two-child title layout was tested to avoid HStack's minimum/maximum priority probes. Matched stress/60Hz-paced traversal results were essentially unchanged, so the custom layout and its cache were removed. Existing shared row layout, RTL, accessibility sizing and callback behavior remain untouched. This experiment is not reported as a speedup.

Conversation scrolling has a separate cost: in three later 45–65ms update windows, native installation appears in 28–36 main-thread samples, with preparation and binding below it. The 126.36ms update at 15.316s is different: 78 of its 103 samples traverse SwiftUI graph updates and 26 traverse generic type metadata lookup, with composer/chrome construction present and almost no table-install work. The first cold conversation surface is not fixed by the sizing changes below.

Retained changes:

- `TimelineLayoutEngine` requests intrinsic text width without calculating and discarding intrinsic height, then performs the final constrained layout. Sender-header glyph metrics are measured once and reused for natural width and fitted frames instead of producing discarded intermediate frame arrays.
- `MessageTextLayout` caches that intrinsic width with the existing text/metadata/geometry invalidation rules. Full `idealSize` behavior remains available. A permanent reuse/metadata/typography/CJK/emoji/spoiler/fenced-code regression compares final line breaks, footer placement and code geometry with the full intrinsic-size path.

Accepted native workload: 400 existing-fixture messages alternating senders, with formatted text/links and 80 twelve-line code blocks, in a geometry-asserted 900×700pt window. Readiness requires all 401 native rows and a 45,276pt document, not merely a mounted empty table. The scheduler retains its existing run-loop test source and preparation budget. After mounting, 120 warm steps precede 360 stress steps over 24,000pt and 360 steps over 3,000pt paced to a 60Hz deadline; actual native live-scroll notifications and layout/transaction flushing are exercised.

Paired `/tmp/chahua-mixed-cold-before.xcresult` and `/tmp/chahua-mixed-cold-after.xcresult`:

| Native workload measurement | Before | After |
| --- | ---: | ---: |
| Mount/load to all rows installed, ms | 5057.85 | 3814.92 |
| Warm stress traversal CPU, ms | 2805.06 | 2808.89 |
| Warm stress callback p95, ms | 10.31 | 11.99 |
| 60Hz-paced callback p95, ms | 12.20 | 11.98 |
| 60Hz-paced callbacks over 16.67ms, out of 360 | 0 | 2 |

Initial heavy-fixture preparation improves by approximately 25%; warm scrolling does not materially improve. This mount interval is not the authenticated app's normal conversation-open latency, and the workload does not replay the user's messages or input. Do not call this a 60/120fps fix. The actual native post-scroll image was inspected for code, sender headers, timestamps, inline metadata and delivery glyphs. Twenty-seven optimized text-layout regressions passed.

Earlier temporary scenarios with invalid fixture JSON or a three-second readiness failure are excluded. The fixture's existing structured fields path supplies escaped multiline text; readiness is explicitly guarded before accepting any timing. Temporary workloads and compiler-overlay sources are removed. No fixed row heights, scheduler throttling or speculative sidebar layout ship.

Final integration after temporary source removal: `/tmp/chahua-mixed-mac-final.xcresult` ran 502 tests with zero failures; `/tmp/chahua-mixed-ipad-final.xcresult` ran 445 tests with zero failures. Neither log contains a view-update publication warning. `./format.sh --check` passed.

