#if os(macOS)
import AppKit
import Combine
import SwiftUI
import XCTest
@testable import chahua_apple

@MainActor
final class SidebarWindowControlsTests: XCTestCase {
    func testConversationTitleChangesKeepTrafficLightsInsideSidebar() async throws {
        let selection = Selection()
        let host = NSHostingController(rootView: SelectionSurface(selection: selection))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentViewController = host
        window.orderFront(nil)
        defer { window.close() }
        await settle(window)
        let original = try positions(in: window)

        for title in ["First conversation", "Second conversation", nil] as [String?] {
            selection.chat = title
            await settle(window)
            let actual = try positions(in: window)
            for (before, after) in zip(original, actual) {
                XCTAssertEqual(after.x, before.x, accuracy: 0.5, "Selecting a chat must not move a window button horizontally")
                XCTAssertEqual(after.y, before.y, accuracy: 0.5, "Selecting a chat must not move a window button vertically")
            }
        }
        window.setContentSize(NSSize(width: 1000, height: 650))
        await settle(window)
        let resized = try positions(in: window)
        for (before, after) in zip(original, resized) {
            XCTAssertEqual(after.x, before.x, accuracy: 0.5)
            XCTAssertEqual(after.y, before.y, accuracy: 0.5, "Buttons remain inset from the window top after resize")
        }
    }

    private func settle(_ window: NSWindow) async {
        // SwiftUI title propagation and AppKit's subsequent frame notifications
        // run on separate turns of the main run loop.
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(20))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func positions(in window: NSWindow) throws -> [CGPoint] {
        try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { kind in
            let button = try XCTUnwrap(window.standardWindowButton(kind))
            let frame = button.convert(button.bounds, to: nil)
            return CGPoint(x: frame.minX, y: window.frame.height - frame.maxY)
        }
    }

    private final class Selection: ObservableObject {
        @Published var chat: String?
    }

    private struct SelectionSurface: View {
        @ObservedObject var selection: Selection

        var body: some View {
            HStack(spacing: 12) {
                VStack {
                    SidebarWindowControls().frame(height: 52)
                    Text("Chats")
                    Spacer()
                }
                .frame(width: 320)
                Group {
                    if let chat = selection.chat {
                        Text(chat).navigationTitle(chat)
                    } else {
                        Text("Select a conversation")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(12)
            .frame(minWidth: 900, minHeight: 600)
            .ignoresSafeArea(.container, edges: .top)
        }
    }
}
#endif
