#if os(iOS)
    import SwiftUI
    import UIKit
    import XCTest

    @testable import chahua_apple

    /// The timeline must run edge to edge on iPhone, under the status bar and home
    /// indicator, while the floating header, pinned bar, and composer stay clear of the
    /// system bars and of each other, and the timeline's insets clear all of them.
    /// Composes the production chrome modifiers in the chat screen's order.
    @MainActor
    final class ChatChromeLayoutTests: XCTestCase {
        func testTimelineExtendsEdgeToEdgeWhileChromeStacksWithoutOverlap() async throws {
            let scene = try XCTUnwrap(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            let probe = ChromeProbe()
            window.rootViewController = UIHostingController(rootView: ChromeHarness(probe: probe))
            window.makeKeyAndVisible()
            defer { window.isHidden = true }

            // Measurements feed back into insets; wait until a full layout pass is stable.
            var previous = probe.snapshot
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(30))
                let current = probe.snapshot
                if current == previous, current.timeline.height > 0 { break }
                previous = current
            }
            // Read after layout: the window reports no safe area before its first pass.
            window.layoutIfNeeded()
            let safeArea = window.safeAreaInsets
            let height = window.bounds.height
            try XCTSkipIf(
                safeArea.top == 0 || safeArea.bottom == 0,
                "Edge-to-edge chrome needs a destination with a status bar and home indicator")
            let layout = probe.snapshot
            XCTAssertEqual(layout.timeline.minY, 0, accuracy: 0.5, "Timeline must start at the top")
            XCTAssertEqual(
                layout.timeline.maxY, height, accuracy: 0.5, "Timeline must reach the bottom")

            XCTAssertGreaterThanOrEqual(
                layout.header.minY, safeArea.top - 0.5, "Header must sit below the status bar")
            XCTAssertGreaterThanOrEqual(
                layout.pinnedBar.minY, layout.header.maxY, "Pinned bar must sit below the header")
            XCTAssertLessThanOrEqual(
                layout.composer.maxY, height - safeArea.bottom + 0.5,
                "Composer must sit above the home indicator")

            XCTAssertGreaterThanOrEqual(
                layout.headerInset, layout.pinnedBar.maxY,
                "Header inset must clear the status bar, header, and pinned bar")
            XCTAssertGreaterThanOrEqual(
                layout.composerInset, height - layout.composer.minY - 0.5,
                "Composer inset must clear the composer and home indicator")
        }
    }

    private struct ChromeSnapshot: Equatable {
        var timeline = CGRect.zero
        var header = CGRect.zero
        var pinnedBar = CGRect.zero
        var composer = CGRect.zero
        var headerInset: CGFloat = 0
        var composerInset: CGFloat = 0
    }

    @MainActor
    private final class ChromeProbe {
        var snapshot = ChromeSnapshot()
    }

    private struct ChromeHarness: View {
        let probe: ChromeProbe

        var body: some View {
            ProbeTimeline(probe: probe)
                .modifier(
                    ChatPinnedBarOverlay(isVisible: true) {
                        Color.gray.frame(height: 50).measured { probe.snapshot.pinnedBar = $0 }
                    }
                )
                .modifier(
                    ChatComposerOverlay {
                        Color.gray.frame(height: 60).measured { probe.snapshot.composer = $0 }
                    }
                )
                .modifier(
                    ChatHeaderOverlay {
                        Color.gray.frame(height: 44).measured { probe.snapshot.header = $0 }
                    }
                )
        }
    }

    private struct ProbeTimeline: View {
        let probe: ChromeProbe
        @Environment(\.chatHeaderInset) private var headerInset
        @Environment(\.chatComposerInset) private var composerInset

        var body: some View {
            Color.clear
                .measured { probe.snapshot.timeline = $0 }
                .onChange(of: headerInset, initial: true) { _, inset in
                    probe.snapshot.headerInset = inset
                }
                .onChange(of: composerInset, initial: true) { _, inset in
                    probe.snapshot.composerInset = inset
                }
        }
    }

    extension View {
        /// Reports the view's frame in window (global) coordinates.
        fileprivate func measured(_ report: @escaping (CGRect) -> Void) -> some View {
            background {
                GeometryReader { geometry in
                    let frame = geometry.frame(in: .global)
                    Color.clear
                        .onAppear { report(frame) }
                        .onChange(of: frame) { _, frame in report(frame) }
                }
            }
        }
    }
#endif
