#if os(iOS)
    import ChahuaAPI
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
        func testHeaderBoundsThreadControlsWithoutCroppingScaledAvatars() throws {
            let api = FixtureReactionClient()
            let root = try TimelineTestFixtures.message(
                id: 1, senderID: 2, at: 0,
                text: "A long thread title that must truncate in its capsule")
            api.install([root])
            let store = ChatStore(
                apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {}
            )
            let subscription = ThreadSubscriptionModel(chatID: "chat", threadID: "1", store: store)
            let available = CGSize(width: 402, height: 800)
            let thread = UIHostingController(
                rootView: ChatFloatingHeader(
                    title: "Thread", onBack: {}, trailingIsControl: true
                ) {
                    ThreadSubscriptionMenu(model: subscription)
                })
            let threadSize = thread.sizeThatFits(in: available)
            XCTAssertLessThan(
                threadSize.height, available.height / 4,
                "A thread control must not turn the floating header into a full-screen overlay.")

            let parent = ChatListItem(
                id: "chat", name: "Design team", lastMessageAt: root.createdAt,
                unreadCount: 0, lastMessage: root.replyPreview, mutedUntil: nil, archived: false,
                kind: .group, peer: nil)
            let leadingAvatar = ThreadHeaderAvatar(
                key: .init(chatID: "chat", threadID: "1"), parent: parent, store: store,
                currentUserID: 1, diameter: ChatFloatingHeader<EmptyView>.avatarDiameter,
                root: root)
            for dynamicType in [DynamicTypeSize.large, .accessibility5] {
                for width in [CGFloat(320), CGFloat(402)] {
                    let proposal = CGSize(width: width, height: available.height)
                    let leadingHost = UIHostingController(
                        rootView: leadingAvatar.environment(\.dynamicTypeSize, dynamicType))
                    let threadWithAvatar = UIHostingController(
                        rootView: ChatFloatingHeader(
                            title: root.message ?? "Thread", subtitle: parent.name, onBack: {},
                            trailingIsControl: true, leadingAvatar: leadingAvatar
                        ) {
                            ThreadSubscriptionMenu(model: subscription)
                        }
                        .environment(\.dynamicTypeSize, dynamicType))
                    let size = threadWithAvatar.sizeThatFits(in: proposal)
                    XCTAssertLessThanOrEqual(
                        size.width, proposal.width,
                        "The avatar and long identity must fit between the edge controls.")
                    XCTAssertLessThan(
                        size.height, proposal.height / 4,
                        "A leading avatar must not let the thread control fill the screen.")
                    XCTAssertGreaterThanOrEqual(
                        size.height, leadingHost.sizeThatFits(in: proposal).height,
                        "The identity must accommodate the scaled thread avatar without clipping.")
                }
            }

            let avatar = AvatarView(url: nil, displayName: "Ada", diameter: 38, isOnline: true)
            let avatarHost = UIHostingController(
                rootView: avatar.environment(\.dynamicTypeSize, .accessibility5))
            let profile = UIHostingController(
                rootView: ChatFloatingHeader(title: "Ada") { avatar }
                    .environment(\.dynamicTypeSize, .accessibility5))
            XCTAssertGreaterThanOrEqual(
                profile.sizeThatFits(in: available).height,
                avatarHost.sizeThatFits(in: available).height,
                "Bounding controls must not reintroduce clipping of scaled online avatars.")
        }

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
