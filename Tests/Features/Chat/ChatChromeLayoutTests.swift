import ChahuaAPI
import Combine
import SwiftUI
import XCTest

@testable import chahua_apple

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

#if os(iOS)

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
                diameter: ChatFloatingHeader<EmptyView>.avatarDiameter,
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

        func testLoadingPlaceholderKeepsFloatingHeaderAtViewportTop() async throws {
            let scene = try XCTUnwrap(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            let probe = ChromeProbe()
            window.rootViewController = UIHostingController(
                rootView: ChahuaLoadingView(title: "Loading conversation")
                    .measured { probe.snapshot.timeline = $0 }
                    .modifier(
                        ChatHeaderOverlay {
                            ChatFloatingHeader(title: "Conversation", onBack: {}) {
                                EmptyView()
                            }
                            .measured { probe.snapshot.header = $0 }
                        }))
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(30))
                if probe.snapshot.header.height > 0 { break }
            }
            window.layoutIfNeeded()
            XCTAssertLessThanOrEqual(
                probe.snapshot.header.minY, window.safeAreaInsets.top + 1,
                "Intrinsic-height placeholders must not center the floating header.")
            XCTAssertLessThan(
                probe.snapshot.header.maxY, window.bounds.midY,
                "Header and centered loading content must occupy separate regions.")
        }

        func testTimelineExtendsEdgeToEdgeWhileChromeStacksWithoutOverlap() async throws {
            let scene = try XCTUnwrap(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            let probe = ChromeProbe()
            let message = try TimelineTestFixtures.message(id: 1, senderID: 2, at: 0)
            window.rootViewController = UIHostingController(
                rootView: ChromeHarness(probe: probe, message: message))
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

            probe.showsPlayback = true
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(30))
                if probe.snapshot.playbackBar.height > 0,
                    abs(probe.snapshot.headerInset - (probe.snapshot.playbackBar.maxY + 8)) < 0.5
                {
                    break
                }
            }
            let playing = probe.snapshot
            XCTAssertEqual(playing.headerInset, playing.playbackBar.maxY + 8, accuracy: 0.5)
            XCTAssertEqual(playing.voiceReferenceInset, layout.headerInset, accuracy: 0.5)
            XCTAssertEqual(playing.timeline, layout.timeline)
            try await Task.sleep(for: .milliseconds(300))  // Capture after the capsule transition.
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Exclusive voice playback header"
            attachment.lifetime = .keepAlways
            add(attachment)

            probe.showsPlayback = false
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(30))
                if abs(probe.snapshot.headerInset - layout.headerInset) < 0.5 { break }
            }
            XCTAssertEqual(probe.snapshot.headerInset, layout.headerInset, accuracy: 0.5)
        }
    }

    private struct ChromeSnapshot: Equatable {
        var timeline = CGRect.zero
        var header = CGRect.zero
        var pinnedBar = CGRect.zero
        var playbackBar = CGRect.zero
        var voiceReferenceInset: CGFloat = 0
        var composer = CGRect.zero
        var headerInset: CGFloat = 0
        var composerInset: CGFloat = 0
    }

    @MainActor
    private final class ChromeProbe: ObservableObject {
        var snapshot = ChromeSnapshot()
        @Published var showsPlayback = false
    }

    private struct ChromeHarness: View {
        @ObservedObject var probe: ChromeProbe
        let message: MessageResponse
        private let playback = VoicePlaybackController()

        var body: some View {
            ProbeTimeline(probe: probe)
                .modifier(
                    ChatSecondaryHeaderOverlay(
                        kind: .select(needsPlayback: probe.showsPlayback, hasPins: true),
                        pinsEligible: true
                    ) {
                        if probe.showsPlayback {
                            VoicePlaybackCapsule(
                                controller: playback,
                                route: VoicePlaybackHeaderRoute(
                                    currentUserID: 2,
                                    chatName: { _ in "Design reviews and product critique" },
                                    open: { _, _, _ in }),
                                message: message
                            )
                            .measured { probe.snapshot.playbackBar = $0 }
                        } else {
                            Color.gray.frame(height: 50).measured { probe.snapshot.pinnedBar = $0 }
                        }
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
        @Environment(\.voiceReferenceHeaderInset) private var voiceReferenceInset
        @Environment(\.chatComposerInset) private var composerInset

        var body: some View {
            Color.clear
                .measured { probe.snapshot.timeline = $0 }
                .onChange(of: headerInset, initial: true) { _, inset in
                    probe.snapshot.headerInset = inset
                }
                .onChange(of: voiceReferenceInset, initial: true) { _, inset in
                    probe.snapshot.voiceReferenceInset = inset ?? 0
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

#if os(macOS)
    @MainActor
    final class ChatChromeLayoutTests: XCTestCase {}
#endif

extension ChatChromeLayoutTests {
    func testVoicePlaybackTakesTheOnlySecondaryHeaderSlot() {
        XCTAssertEqual(
            ChatSecondaryHeaderKind.select(needsPlayback: true, hasPins: true), .playback)
        XCTAssertEqual(ChatSecondaryHeaderKind.select(needsPlayback: false, hasPins: true), .pins)
        XCTAssertEqual(
            ChatSecondaryHeaderKind.select(needsPlayback: true, hasPins: false), .playback)
        XCTAssertNil(ChatSecondaryHeaderKind.select(needsPlayback: false, hasPins: false))
    }

    func testVoiceVisibilityIsIndependentOfInsetClampsForShortTimelines() {
        let withPins = VoiceTimelineVisibility.referenceViewport(
            CGRect(x: 0, y: 0, width: 320, height: 200),
            scrollTop: -70, bottomLimit: -120, headerInset: 70)
        let withPlayback = VoiceTimelineVisibility.referenceViewport(
            CGRect(x: 0, y: 0, width: 320, height: 210),
            scrollTop: -60, bottomLimit: -120, headerInset: 70)

        XCTAssertEqual(withPins, withPlayback)
    }

    func testHalfOfVoiceControlsIsVisibleIncludingExactAreaBoundary() {
        let controls = CGRect(x: 40, y: 150, width: 200, height: 80)
        XCTAssertTrue(
            VoiceTimelineVisibility.containsHalf(
                of: controls, in: CGRect(x: 0, y: 190, width: 320, height: 100)))
        XCTAssertFalse(
            VoiceTimelineVisibility.containsHalf(
                of: controls, in: CGRect(x: 0, y: 191, width: 320, height: 100)))
        XCTAssertTrue(
            VoiceTimelineVisibility.containsHalf(
                of: controls, in: CGRect(x: 90, y: 150, width: 200, height: 60)))
        XCTAssertFalse(
            VoiceTimelineVisibility.containsHalf(
                of: controls, in: CGRect(x: 90, y: 150, width: 200, height: 50)))
    }
}

@MainActor
final class ChatGlassGeometryTests: XCTestCase {
    func testBackBadgeAccessibilityFollowsSnapshotCountingUnit() {
        XCTAssertEqual(
            UnreadBackBadge.accessibilityValue(900, showUnreadMessageCount: true),
            AppLanguage.localized("\(900) unread messages"))
        XCTAssertEqual(
            UnreadBackBadge.accessibilityValue(2, showUnreadMessageCount: false),
            AppLanguage.localized("\(2) unread chats"))
    }

    func testUnreadBackBadgeStaysCircularThenGrowsOnlyHorizontally() {
        func size(_ count: Int) -> CGSize {
            #if os(macOS)
                NSHostingView(rootView: UnreadBackBadge(count: count)).fittingSize
            #else
                UIHostingController(rootView: UnreadBackBadge(count: count))
                    .sizeThatFits(in: CGSize(width: 320, height: 200))
            #endif
        }

        for count in [1, 7, 9] {
            let badge = size(count)
            XCTAssertEqual(badge.width, badge.height, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(badge.width, 22)
        }
        let single = size(1)
        for count in [12, 99, 100, 1000] {
            let badge = size(count)
            XCTAssertGreaterThanOrEqual(badge.width, badge.height)
            XCTAssertEqual(badge.height, single.height, accuracy: 0.01)
        }
        XCTAssertEqual(size(100), size(1000), "The visible count remains capped at 99+.")
        XCTAssertGreaterThan(size(100).width, single.width)
    }
}
