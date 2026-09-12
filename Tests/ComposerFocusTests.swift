import Combine
import SwiftUI
import XCTest

@testable import chahua_apple

#if os(macOS)
    import AppKit
    private typealias ComposerTestView = NSView
#else
    import UIKit
    private typealias ComposerTestView = UIView
#endif

@MainActor
final class ComposerFocusTests: XCTestCase {
    func testSendingRestoresEditorFocusAfterDraftCommit() async throws {
        let h = try await mount(text: "send this")
        h.submit()
        try await pause()
        XCTAssertEqual(h.state.submits, 1)
        XCTAssertFalse(h.state.enabled)
        XCTAssertEqual(h.state.text, "send this", "Do not clear before local enqueue completes.")
        h.state.text = ""
        h.state.enabled = true
        try await pause()
        try h.insertIntoFocusedEditor("next message")
        try await pause()
        XCTAssertEqual(h.state.text, "next message")
    }

    func testFailedCommitRetainsDraftAndRestoresFocusForRetry() async throws {
        let h = try await mount(text: "send this")
        h.submit()
        try await pause()
        XCTAssertEqual(h.state.submits, 1)
        XCTAssertFalse(h.state.enabled)
        // Storage failure reenables editing without changing the draft.
        h.state.enabled = true
        try await pause()
        try h.selectEnd()
        try h.insertIntoFocusedEditor(" again")
        try await pause()
        XCTAssertEqual(h.state.text, "send this again")
        XCTAssertEqual(h.state.submits, 1)
    }

    func testSendButtonSubmitsOnceWithoutClearingBeforeCommit() async throws {
        let h = try await mount(text: "send this")
        h.pressSendButton()
        try await pause()
        XCTAssertEqual(h.state.submits, 1)
        XCTAssertEqual(h.state.text, "send this")
        XCTAssertFalse(h.state.enabled)
    }

    func testMarkedTextStaysLocalUntilCommitted() async throws {
        let h = try await mount(text: "prefix ")
        try h.selectEnd()
        try h.mark("ni")
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertTrue(h.state.composing)
        XCTAssertEqual(h.state.text, "prefix ")
        try h.insertIntoFocusedEditor("你")
        try await pause()
        XCTAssertEqual(h.state.text, "prefix 你")
        XCTAssertFalse(h.state.composing)
        XCTAssertEqual(h.state.submits, 0)
    }

    func testUnchangedUnmarkAndCommitBeforeFocusLossSurvive() async throws {
        let h = try await mount(text: "prefix ")
        try h.selectEnd()
        try h.mark("hao")
        try await pause()
        XCTAssertEqual(h.state.text, "prefix ")
        try h.unmark()
        try await pause()
        XCTAssertEqual(h.state.text, "prefix hao")
        XCTAssertFalse(h.state.composing)
        try h.mark("ni")
        try await pause()
        try h.insertIntoFocusedEditor("你")
        h.blur()
        try await pause()
        XCTAssertEqual(h.state.text, "prefix hao你")
        XCTAssertEqual(h.state.submits, 0)
    }

    func testCandidateConfirmationReturnDoesNotSend() async throws {
        let h = try await mount(text: "prefix ")
        try h.selectEnd()
        try h.mark("ni")
        try await pause()
        XCTAssertTrue(h.state.composing)
        h.pressReturn()
        try await pause()
        XCTAssertEqual(h.state.submits, 0)
        XCTAssertTrue(h.state.enabled)
    }

    func testSendButtonDuringCompositionLeavesCandidateUnsent() async throws {
        let h = try await mount(text: "prefix ")
        try h.selectEnd()
        try h.mark("ni")
        try await pause()

        h.pressSendButton()

        try await pause()
        XCTAssertEqual(h.state.submits, 0)
        XCTAssertEqual(h.state.text, "prefix ")
        XCTAssertTrue(h.state.composing)
        XCTAssertTrue(h.state.enabled)
    }

    func testRemovingMarkedComposerDoesNotSaveIntermediateText() async throws {
        let h = try await mount(text: "prefix ")
        try h.selectEnd()
        try h.mark("ni")
        try await pause()
        XCTAssertTrue(h.state.composing)
        h.state.showsComposer = false
        try await pause()
        XCTAssertEqual(h.state.text, "prefix ")
        XCTAssertFalse(h.state.composing)
    }

    #if os(macOS)
        func testReturnPreservesSelectionAndEditingSessionBeforeCommit() async throws {
            let h = try await mount(text: "send this")
            let editor = try h.focusedEditor()
            let selection = NSRange(location: 2, length: 0)
            editor.setSelectedRange(selection)
            let observer = NotificationCenter.default.addObserver(
                forName: NSText.didEndEditingNotification, object: editor, queue: nil
            ) { _ in MainActor.assumeIsolated { h.state.editingEnded = true } }
            defer { NotificationCenter.default.removeObserver(observer) }

            h.pressReturn()

            XCTAssertTrue(h.window.firstResponder === editor)
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertEqual(editor.string, "send this")
            XCTAssertFalse(h.state.editingEnded, "Return must not end and restart AppKit field editing.")
            try await pause()
            XCTAssertEqual(h.state.submits, 1)
        }

        func testShiftReturnUsesNativeSelectionAndUndoWithoutSubmitting() async throws {
            let h = try await mount(text: "abcd")
            let editor = try h.focusedEditor()
            editor.setSelectedRange(NSRange(location: 1, length: 2))
            h.pressReturn(shift: true)
            try await pause()
            XCTAssertEqual(h.state.text, "a\nd")
            XCTAssertEqual(h.state.submits, 0)
            XCTAssertTrue(editor.undoManager?.canUndo == true)
            editor.undoManager?.undo()
            XCTAssertEqual(editor.string, "abcd")
            try await pause()
            XCTAssertEqual(h.state.text, "abcd")
            editor.setSelectedRange(NSRange(location: 2, length: 0))
            h.pressReturn(shift: true)
            try await pause()
            XCTAssertEqual(h.state.text, "ab\ncd")
            XCTAssertEqual(h.state.submits, 0)
        }
    #endif

    private func pause() async throws { try await Task.sleep(for: .milliseconds(200)) }

    private func mount(text: String) async throws -> FocusComposerHarness {
        let harness = try FocusComposerHarness(text: text)
        addTeardownBlock { @MainActor in harness.close() }
        try await pause()
        try harness.focus()
        try await pause()
        return harness
    }
}

@MainActor
private final class FocusComposerState: ObservableObject {
    let attachments = ComposerAttachmentState()
    @Published var text: String
    @Published var enabled = true
    @Published var showsComposer = true
    var composing = false
    var submits = 0
    var editingEnded = false
    init(text: String) { self.text = text }
}

private struct FocusComposerRoot: View {
    @ObservedObject var state: FocusComposerState
    var body: some View {
        VStack {
            Spacer()
            if state.showsComposer {
                MessageComposerView(
                    text: $state.text, attachmentState: state.attachments,
                    maxHeight: 160, isEnabled: state.enabled, canSend: true,
                    onSubmit: {
                        state.submits += 1
                        state.enabled = false
                        return true
                    }, onCompositionChanged: { state.composing = $0 })
            }
        }
    }
}

@MainActor
private final class FocusComposerHarness {
    let state: FocusComposerState
    #if os(macOS)
        let host: NSHostingController<FocusComposerRoot>
        let window: NSWindow
    #else
        let host: UIHostingController<FocusComposerRoot>
        let window: UIWindow
        weak var priorKeyWindow: UIWindow?
        // Test-host-only SPI: UIKit's in-process XCTest host does not enable
        // SwiftUI's accessibility tree. Needed to activate the real Send button.
        private static let accessibilityLibrary = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW)
        private var restoreAccessibility: (() -> Void)?
    #endif

    init(text: String) throws {
        state = FocusComposerState(text: text)
        #if os(macOS)
            host = NSHostingController(rootView: FocusComposerRoot(state: state))
            host.sizingOptions = []
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 220), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            window.setContentSize(NSSize(width: 800, height: 220))
            host.view.frame = NSRect(x: 0, y: 0, width: 800, height: 220)
            window.makeKeyAndOrderFront(nil)
        #else
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let library = try XCTUnwrap(Self.accessibilityLibrary)
            let setSymbol = try XCTUnwrap(dlsym(library, "_AXSApplicationAccessibilitySetEnabled"))
            let getSymbol = try XCTUnwrap(dlsym(library, "_AXSApplicationAccessibilityEnabled"))
            let setEnabled = unsafeBitCast(setSymbol, to: (@convention(c) (Bool) -> Void).self)
            let wasEnabled = unsafeBitCast(getSymbol, to: (@convention(c) () -> Bool).self)()
            setEnabled(true)
            restoreAccessibility = { setEnabled(wasEnabled) }
            host = UIHostingController(rootView: FocusComposerRoot(state: state))
            priorKeyWindow = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
        #endif
    }

    func close() {
        #if os(macOS)
            window.close()
        #else
            window.isHidden = true
            window.rootViewController = nil
            priorKeyWindow?.makeKey()
            restoreAccessibility?()
            restoreAccessibility = nil
        #endif
    }

    private func allViews(_ view: ComposerTestView) -> [ComposerTestView] {
        [view] + view.subviews.flatMap(allViews)
    }

    func focus() throws {
        let views = allViews(host.view)
        #if os(macOS)
            if let field = views.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }) {
                XCTAssertTrue(window.makeFirstResponder(field))
            } else {
                let editor = try XCTUnwrap(views.compactMap({ $0 as? NSTextView }).first(where: { $0.isEditable }))
                XCTAssertTrue(window.makeFirstResponder(editor))
            }
        #else
            let editor = try XCTUnwrap(views.first(where: { $0 is any UITextInput && $0.canBecomeFirstResponder }))
            XCTAssertTrue(editor.becomeFirstResponder())
        #endif
    }

    #if os(macOS)
        func focusedEditor() throws -> NSTextView {
            try XCTUnwrap(window.firstResponder as? NSTextView, "Typing must not require refocusing the composer.")
        }
    #else
        func focusedEditor() throws -> any UITextInput {
            try XCTUnwrap(
                allViews(host.view).first(where: \.isFirstResponder) as? any UITextInput,
                "Typing must not require refocusing the composer.")
        }
    #endif

    func selectEnd() throws {
        let editor = try focusedEditor()
        #if os(macOS)
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        #else
            editor.selectedTextRange = editor.textRange(from: editor.endOfDocument, to: editor.endOfDocument)
        #endif
    }

    func insertIntoFocusedEditor(_ text: String) throws {
        let editor = try focusedEditor()
        #if os(macOS)
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        #else
            editor.insertText(text)
        #endif
    }

    func mark(_ text: String) throws {
        let editor = try focusedEditor()
        #if os(macOS)
            editor.setMarkedText(
                text, selectedRange: NSRange(location: text.utf16.count, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
        #else
            editor.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
        #endif
    }

    func unmark() throws { try focusedEditor().unmarkText() }

    func blur() {
        #if os(macOS)
            window.makeFirstResponder(nil)
        #else
            window.endEditing(true)
        #endif
    }

    func submit() {
        #if os(macOS)
            pressReturn()
        #else
            XCTAssertTrue(pressSendButton())
        #endif
    }

    #if os(macOS)
        func pressSendButton() {
            let point = host.view.convert(
                NSPoint(
                    x: host.view.bounds.width - 34,
                    y: host.view.isFlipped ? host.view.bounds.height - 34 : 34), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                NSApp.sendEvent(event)
            }
        }
    #else
        @discardableResult
        func pressSendButton() -> Bool {
            func activate(_ element: NSObject) -> Bool {
                if element.accessibilityLabel == "Send message" { return element.accessibilityActivate() }
                let count = element.accessibilityElementCount()
                let exposed =
                    count > 0 && count < 1000
                    ? (0..<count).compactMap { element.accessibilityElement(at: $0) } : []
                return (exposed + ((element as? UIView)?.subviews ?? [])).contains {
                    guard let child = $0 as? NSObject else { return false }
                    return activate(child)
                }
            }
            return activate(host.view)
        }
    #endif

    func pressReturn(shift: Bool = false) {
        #if os(macOS)
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            NSApp.sendEvent(event)
        #else
            // UIKit asks its delegate before inserting keyboard text. Calling
            // insertText alone bypasses SwiftUI's native submission decision.
            guard let editor = try? focusedEditor() as? UITextView else {
                XCTFail("Expected SwiftUI's multiline UITextView")
                return
            }
            let shouldInsert =
                editor.delegate?.textView?(
                    editor, shouldChangeTextIn: editor.selectedRange, replacementText: "\n") ?? true
            if shouldInsert { editor.insertText("\n") }
        #endif
    }
}
