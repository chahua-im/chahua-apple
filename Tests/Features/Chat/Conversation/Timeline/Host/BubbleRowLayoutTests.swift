#if os(macOS)
    import AppKit
    import SwiftUI
    import XCTest
    @testable import chahua_apple

    @MainActor
    final class BubbleRowLayoutTests: XCTestCase {
        func testReactionsStayBelowBubbleAndAvatarOnBothSides() async throws {
            for outgoing in [false, true] {
                for bubbleHeight: CGFloat in [24, 80] {
                    for reactionHeight: CGFloat in [26, 78] {
                        let bubble = NSView()
                        let avatar = NSView()
                        let reactions = NSView()
                        let content = BubbleRowLayout(isOutgoing: outgoing, avatarSize: 36) {
                            Marker(view: bubble).frame(width: 180, height: bubbleHeight)
                            Marker(view: avatar).frame(width: 36, height: 36)
                            Marker(view: reactions).frame(width: 180, height: reactionHeight)
                        }.frame(width: 400, height: 200, alignment: .top)
                        let host = NSHostingController(rootView: content)
                        let window = mount(host, size: CGSize(width: 400, height: 200))
                        try await Task.sleep(for: .milliseconds(50))
                        host.view.layoutSubtreeIfNeeded()
                        let bubbleFrame = bubble.convert(bubble.bounds, to: host.view)
                        let avatarFrame = avatar.convert(avatar.bounds, to: host.view)
                        let reactionFrame = reactions.convert(reactions.bounds, to: host.view)
                        XCTAssertEqual(avatarFrame.maxY, bubbleFrame.maxY, accuracy: 0.5)
                        XCTAssertGreaterThanOrEqual(reactionFrame.minY, avatarFrame.maxY - 0.5)
                        XCTAssertEqual(
                            outgoing ? reactionFrame.maxX : reactionFrame.minX,
                            outgoing ? bubbleFrame.maxX : bubbleFrame.minX, accuracy: 0.5)
                        window.close()
                    }
                }
            }
        }


        private func mount<V: View>(_ host: NSHostingController<V>, size: CGSize) -> NSWindow {
            host.sizingOptions = []
            let window = NSWindow(
                contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            window.setContentSize(size)
            host.view.frame = CGRect(origin: .zero, size: size)
            window.makeKeyAndOrderFront(nil)
            return window
        }
    }

    private struct Marker: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }
#endif
