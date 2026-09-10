#if os(macOS)
    import AppKit
    import SwiftUI
    import XCTest
    @testable import chahua_apple

    @MainActor
    final class ComposerInputStateTests: XCTestCase {
        func testBindingBeforeMarkedRangeNeverPublishesIntermediateText() {
            let harness = NativeComposerHarness(text: "draft ")
            defer { harness.input.detach() }

            // SwiftUI's setter can run before the input method installs its mark.
            harness.input.receiveEditorText("draft ni")
            XCTAssertEqual(harness.persisted, "draft ")
            harness.mark("ni")
            harness.input.settleNativeInput()
            XCTAssertEqual(harness.persisted, "draft ")
            XCTAssertEqual(harness.events, ["composing"])

            harness.editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
            harness.input.receiveEditorText(harness.editor.string)
            harness.input.settleNativeInput()
            XCTAssertEqual(harness.persisted, "draft 你")
            XCTAssertEqual(harness.events, ["composing", "write:draft 你", "committed"])
        }

        func testUnmarkWithoutBindingChangePublishesBeforeResumingPersistence() {
            let harness = NativeComposerHarness(text: "")
            defer { harness.input.detach() }
            harness.mark("你好")
            harness.input.settleNativeInput()
            XCTAssertEqual(harness.persisted, "")

            let markedString = harness.editor.string
            harness.editor.unmarkText()
            XCTAssertEqual(harness.editor.string, markedString)
            harness.input.settleNativeInput()
            XCTAssertEqual(harness.persisted, "你好")
            XCTAssertEqual(harness.events, ["composing", "write:你好", "committed"])
        }

        func testCanceledMarkedRangeAndUnresolvedTeardownKeepCommittedDraft() {
            let canceled = NativeComposerHarness(text: "draft ")
            defer { canceled.input.detach() }
            canceled.mark("ni")
            canceled.editor.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
            canceled.editor.unmarkText()
            canceled.input.settleNativeInput()
            XCTAssertEqual(canceled.persisted, "draft ")
            XCTAssertEqual(canceled.events, ["composing", "committed"])

            let detached = NativeComposerHarness(text: "draft ")
            detached.mark("ni")
            detached.input.receiveEditorText(detached.editor.string)
            detached.restore("restored")
            XCTAssertEqual(detached.input.editorText, "draft ni")
            detached.input.detach()
            XCTAssertEqual(detached.persisted, "restored")
            XCTAssertEqual(detached.input.editorText, "restored")
            XCTAssertEqual(detached.events, ["composing", "committed"])
        }

        func testUserCommitWinsRestorationAndMarkedReturnCannotSubmit() {
            let harness = NativeComposerHarness(text: "draft ")
            defer { harness.input.detach() }
            harness.mark("ni")
            harness.input.receiveEditorText(harness.editor.string)
            harness.restore("older server draft")
            var sent: [String] = []
            if harness.input.prepareSubmission() { sent.append(harness.persisted) }
            harness.editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertFalse(harness.input.prepareSubmission(), "The candidate-confirmation transaction must not send.")
            harness.input.settleNativeInput()
            XCTAssertEqual(harness.persisted, "draft 你")
            XCTAssertEqual(sent, [])

            if harness.input.prepareSubmission() { sent.append(harness.persisted) }
            harness.input.settleNativeInput()
            XCTAssertEqual(sent, ["draft 你"])
            harness.restore("")
            XCTAssertEqual(harness.input.editorText, "")
        }

        func testSubmissionUsesOwnedEditingEndSnapshotOnlyWithinItsTransaction() {
            let harness = NativeComposerHarness(text: "draft")
            defer { harness.input.detach() }
            harness.editor.insertText(" final", replacementRange: NSRange(location: NSNotFound, length: 0))
            harness.input.nativeEditingEnded(harness.snapshot())
            harness.input.nativeInput = nil
            XCTAssertTrue(harness.input.prepareSubmission())
            XCTAssertEqual(harness.persisted, "draft final")
            XCTAssertFalse(harness.input.prepareSubmission(), "Do not reuse a consumed editing-end snapshot.")
        }
    }

    @MainActor
    private final class NativeComposerHarness {
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let input = ComposerInputState()
        var persisted: String
        var events: [String] = []

        init(text: String) {
            persisted = text
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            input.configure(
                draft: Binding(
                    get: { [unowned self] in persisted },
                    set: { [unowned self] in
                        persisted = $0
                        events.append("write:\($0)")
                    }
                ),
                onCompositionChanged: { [unowned self] in events.append($0 ? "composing" : "committed") }
            )
            input.nativeInput = self
            input.receiveExternalText(text)
        }

        func snapshot() -> ComposerInputSnapshot {
            editor.hasMarkedText() ? .marked : .committed(editor.string)
        }

        func insertNewline() -> Bool {
            guard !editor.hasMarkedText() else { return false }
            editor.insertNewlineIgnoringFieldEditor(nil)
            return true
        }

        func mark(_ text: String) {
            editor.setMarkedText(
                text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            input.nativeInputChanged()
        }

        func restore(_ text: String) {
            persisted = text
            input.receiveExternalText(text)
        }
    }

    extension NativeComposerHarness: ComposerNativeInput {}
#endif
