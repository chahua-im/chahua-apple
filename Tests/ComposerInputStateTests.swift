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

        func testLatinPreeditUnmarksInReturnTransactionWithoutSending() {
            let harness = NativeComposerHarness(text: "draft ")
            defer { harness.input.detach() }
            harness.mark("ni")
            harness.editor.unmarkText()
            XCTAssertFalse(harness.input.prepareSubmission())
            harness.input.settleNativeInput()
            XCTAssertEqual(harness.persisted, "draft ni")
            XCTAssertTrue(harness.input.prepareSubmission())
        }

        func testExplicitSubmissionCommitsVisiblePreeditWithoutChoosingCandidate() {
            let harness = NativeComposerHarness(text: "draft ")
            defer { harness.input.detach() }
            harness.mark("ni")
            XCTAssertTrue(harness.input.prepareExplicitSubmission())
            XCTAssertFalse(harness.editor.hasMarkedText())
            XCTAssertEqual(harness.persisted, "draft ni")
            XCTAssertFalse(harness.input.isComposing)
        }

        func testExplicitSubmissionConsumesOwnedPreeditAfterFocusLoss() {
            let harness = NativeComposerHarness(text: "draft ")
            defer { harness.input.detach() }
            harness.mark("ni")
            harness.input.nativeEditingEnded(.marked, visibleText: harness.editor.attributedString())
            harness.input.nativeInput = nil
            XCTAssertTrue(harness.input.prepareExplicitSubmission())
            XCTAssertEqual(harness.persisted, "draft ni")
            XCTAssertFalse(harness.input.prepareExplicitSubmission())
        }

        func testSelectedMentionKeepsUIDWithoutTokenizingEqualPlainName() throws {
            let harness = NativeComposerHarness(text: "@Ada @a")
            defer { harness.input.detach() }
            harness.input.refreshMentionQuery()
            let query = try XCTUnwrap(harness.input.mentionQuery)
            XCTAssertTrue(harness.input.insertMention(uid: 42, label: "Ada", query: query))
            XCTAssertEqual(harness.editor.string, "@Ada @Ada ")
            XCTAssertEqual(harness.persisted, "@Ada @[uid:42] ")
            XCTAssertFalse(harness.input.insertMention(uid: 99, label: "Ada", query: query), "Stale result must not replace a new caret position.")
        }

        func testRestoredMentionLabelsAndQueryRespectSelectionAndIdentity() {
            let harness = NativeComposerHarness(text: "@[uid:2] @[uid:9] @a")
            defer { harness.input.detach() }
            harness.input.setMentionNames([2: "Ada"])
            XCTAssertEqual(harness.input.editorText, "@Ada @User 9 @a")
            XCTAssertEqual(harness.persisted, "@[uid:2] @[uid:9] @a")
            harness.editor.setSelectedRange(NSRange(location: 3, length: 0))
            harness.input.refreshMentionQuery()
            XCTAssertNil(harness.input.mentionQuery)
            harness.editor.setSelectedRange(NSRange(location: 13, length: 2))
            harness.input.refreshMentionQuery()
            XCTAssertNil(harness.input.mentionQuery)
            harness.editor.setSelectedRange(NSRange(location: 15, length: 0))
            harness.input.refreshMentionQuery()
            XCTAssertEqual(harness.input.mentionQuery?.query, "a")
            harness.mark("b")
            XCTAssertNil(harness.input.mentionQuery)
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
            installMentionText(input.mentionText)
        }

        func snapshot() -> ComposerInputSnapshot {
            editor.hasMarkedText() ? .marked : .committed(ComposerMentionText.wireText(editor.attributedString()))
        }

        func insertNewline() -> Bool {
            guard !editor.hasMarkedText() else { return false }
            editor.insertNewlineIgnoringFieldEditor(nil)
            return true
        }

        var attributedText: NSAttributedString? { editor.attributedString() }
        var selection: NSRange? { editor.selectedRange() }
        var canHydrateMentionLabels: Bool { !editor.hasMarkedText() }

        func installMentionText(_ text: NSAttributedString) {
            guard !editor.hasMarkedText() else { return }
            let range = editor.selectedRange()
            editor.textStorage?.setAttributedString(text)
            let start = min(range.location, text.length)
            editor.setSelectedRange(NSRange(location: start, length: min(range.length, text.length - start)))
        }

        func replaceMention(in range: NSRange, with text: NSAttributedString) -> Bool {
            editor.insertText(text, replacementRange: range)
            return true
        }

        func commitMarkedText() -> ComposerInputSnapshot {
            editor.unmarkText()
            editor.inputContext?.discardMarkedText()
            return snapshot()
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
