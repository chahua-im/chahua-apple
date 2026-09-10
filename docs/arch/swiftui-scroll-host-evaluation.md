# Why SwiftUI is not ready for this complex chat scroll host

- **Decision date:** 2026-09-07
- **Status:** Rejected; the SwiftUI scroll-host migration was reverted.
- **Decision:** Keep native UIKit/AppKit scrolling hosts, with shared SwiftUI bubbles and shared timeline state.

For Chahua's requirements, SwiftUI's current public scrolling APIs are not a sufficiently reliable foundation for a fully SwiftUI conversation timeline. This is an architectural decision about a complex, bidirectionally paginated scroll host—not a claim that SwiftUI cannot render chat messages or implement simpler scrolling interfaces.

## The contract is stronger than “scroll to the last message”

A conversation timeline must preserve the reader's place while both its data and its layout change:

- Open at the live edge or the explicitly requested message, and acknowledge navigation only after reaching that destination.
- Preserve the earliest intersecting **message**, including its partially clipped pixel offset, through prepends. A leading date separator must not become the reader anchor.
- Retain that position through wrapping, Dynamic Type, viewport resizing, and content-inset changes. The migration's acceptance tolerance was one point.
- Follow live arrivals only when the model says to follow. Receiving a message while reading history must not move the reader.
- Prefetch older and newer pages during genuine user movement, without letting layout corrections or programmatic navigation trigger pagination.
- Let touch, trackpad, phase-less mouse-wheel, and scrollbar input interrupt programmatic scrolling. Cancellation must prevent a later snap back to the old destination.
- Keep long histories lazy, text selectable, horizontal scrolling absent, and iOS keyboard dismissal interactive.

Opening at the right position and reliably loading history are baseline chat behavior, not optional polish.

## What we evaluated

The prototype replaced the two native hosts with a vertical `ScrollView`, `LazyVStack`, stable-ID `ForEach`, and a typed `ScrollPosition`. It retained `ConversationTimelineModel` and its revisioned `TimelineHostSnapshot` stream.

A shared coordinator consumed scroll geometry, scroll phases, and per-row geometry. It installed snapshots, restored reader anchors, handled bottom/reveal requests, and distinguished user viewports from layout and programmatic viewports. When an anchor was not materialized, it scrolled to the ID first and then attempted a point correction.

The experiment targeted iOS 18/macOS 15 APIs and was built with Xcode 26.6. Hosted validation ran on macOS 26.5.2 and an iOS 26.5 simulator. Those runs do not establish behavior on every supported OS version.

## Why the design did not hold up

### 1. Observing geometry is not controlling a layout transaction

The host needed a coherent sequence:

1. Retain the reader anchor from the installed revision.
2. Install new rows or a new measurement environment.
3. Resolve the retained message's new frame.
4. Apply the exact offset correction.
5. Confirm the settled destination before publishing a viewport or acknowledging a request.

The APIs evaluated did not give this coordinator one transaction that controlled that entire sequence. Row geometry and scroll geometry arrived independently. A row frame could reflect a different layout moment from the content offset used to interpret it.

Serializing model snapshots solved publication ordering, but did not make SwiftUI's separate layout observations atomic.

### 2. Lazy geometry makes point restoration a feedback loop

Off-screen row geometry is not continuously available. During the prototype, a measured last-row edge and a `contentSize`-based bottom calculation disagreed by more than 100 points. We also encountered stale frames from rows that were no longer materialized.

Obtaining a missing frame required scrolling to materialize its row. That scroll changed the viewport, materialized other rows, and could change the estimated content extent again. Correcting the offset then produced another round of observations.

The coordinator consequently accumulated lifecycle tokens, pending correction offsets, materialization state, and destination-refinement passes. It was becoming a second scrolling engine around the framework's scrolling engine, rather than a small presentation adapter.

### 3. User input and layout motion must not be confused

Scroll phases and `ScrollPosition.isPositionedByUser` are useful signals, but the coordinator still had to reconcile them with asynchronously delivered geometry.

For example, filtering out an offset change because `contentSize` changed at the same time can discard genuine wheel movement: lazy measurement changes content size during scrolling. Conversely, treating every offset adjustment as user movement can start pagination during layout or navigation.

Losing user ownership before valid visible-row frames arrive creates another failure: the eventual viewport is reported as layout instead of user movement, so history loading does not start.

These are examples of defects in the prototype, not claims of independently confirmed SwiftUI framework bugs. They demonstrate how much correctness-sensitive inference this design required.

### 4. Animation completion is not settled-layout completion

Reaching the end of an animation does not, by itself, prove that the requested row geometry, lazy content extent, and scroll offset now describe the same settled destination. Later layout adjustments can move the reader again.

The prototype introduced a 32-ms quiet interval before reconciling non-user layout. That reduced some transient failures, but elapsed time is not a layout-completion guarantee. Additional flags and delays cannot establish an ordering guarantee that the host does not control.

The fundamental problem was this mismatch between the contract we needed and the control available through the evaluated API surface—not merely a missing debounce or one incorrect offset formula.

## What the evidence established—and did not establish

At one checkpoint, the prototype passed 52 macOS and 53 iOS hosted application tests, along with both production-API configuration builds. Those results were insufficient for acceptance.

Subsequent user testing in the actual macOS application reported:

- Scrolling upward to trigger history loading was unreliable.
- Opening the conversation sometimes landed at the wrong initial position.

The user had not yet manually verified iOS. Simulator tests must not be presented as evidence that the real iOS interaction was verified.

The test harness also needed corrections of its own: attaching iOS hosting windows to a `UIWindowScene`, handling arbitrary-size fixtures separately from physical safe areas, and distinguishing cached row frames from currently materialized views. These fixture problems are not evidence against SwiftUI. They explain why passing isolated host tests initially gave too much confidence.

Tests that mount an empty host and then load messages also do not fully represent an application that mounts a host around an already-loaded model. Both paths matter. Real application behavior overruled the isolated green test results.

## The retained architecture

Keep the existing separation:

- `ConversationTimelineModel` owns loading, pagination, follow-latest policy, and revisioned navigation requests.
- Stable message identity, row construction, and SwiftUI bubble rendering remain shared.
- `TimelineCollectionViewController` owns the iOS scroll/layout integration.
- `TimelineTableViewController` owns the macOS scroll/layout integration.
- `TimelineRowMeasurer` and `TimelineChange` support explicit native measurement and row updates.

The native hosts require platform-specific code and careful measurement lifecycle management. They are not automatically bug-free. However, they give us direct control of row updates, layout, content offsets, and native input callbacks at the layer responsible for those operations. That is a better fit for exact anchoring and interruption-safe navigation.

At rollback, the app returned to iOS 16.6/macOS 13.5 and the test-target floors stayed at 26.5. The subsequent composer redesign raised the app and ChahuaAPI baselines to iOS 17/macOS 14; it did not change this scroll-host decision. Raising the app's minimum OS solely to access newer scrolling APIs did not resolve the architectural mismatch.

## Conditions for revisiting this decision

Do not retry the production cutover simply because a newer SDK compiles the same approach or a basic chat demo works. First establish one of the following:

- Public APIs provide the layout/scroll coordination needed for this contract.
- A small, isolated prototype demonstrates reliable equivalent behavior without timing-based settlement assumptions or hidden native introspection.
- The product explicitly accepts a weaker contract, such as approximate rather than point-preserving anchoring.

Before replacing the native hosts, validate an app-shaped prototype with preloaded-model mounting, sustained scrolling through lazily measured rows, delayed prepends, heterogeneous message heights, repeated resizing, inset changes, and interruptions at different points in navigation. Exercise real input on both platforms and preserve the one-point/no-late-snap acceptance checks unless the product contract is deliberately changed.

SwiftUI remains appropriate for Chahua's screens and message presentation. **For this complex scroll host today, keep scrolling and layout coordination native.**

## API references

- [Apple: ScrollPosition](https://developer.apple.com/documentation/swiftui/scrollposition)
- [Apple: ScrollGeometry](https://developer.apple.com/documentation/swiftui/scrollgeometry)
- [Apple: LazyVStack](https://developer.apple.com/documentation/swiftui/lazyvstack)

These references describe the APIs considered; the evaluation and rejection above are this project's engineering judgment and observations, not an Apple statement about supported chat architectures.
