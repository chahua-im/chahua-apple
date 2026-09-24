import ChahuaAPI
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
    func testCaptionWaitsForUserFocus() async throws {
        let h = try FocusComposerHarness(text: "caption", enabled: true, caption: true)
        addTeardownBlock { @MainActor in h.close() }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(h.hasFocusedEditor)
        try h.focus()
        try await pause()
        XCTAssertTrue(h.hasFocusedEditor)
    }

    func testVoicePreviewStopInvalidatesPendingLoadWithoutPublishingIdleResets() async throws {
        let playback = VoicePlaybackController()
        var changes = 0
        let observer = playback.objectWillChange.sink { changes += 1 }
        defer { observer.cancel() }
        playback.stop()
        XCTAssertEqual(changes, 0, "An idle preview has no state to publish on teardown.")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        let loading = Task { await playback.load(url: url) }
        try await Task.sleep(for: .milliseconds(50))
        // Like a hosting row leaving the view tree, stop on the next main turn.
        DispatchQueue.main.async { playback.stop() }
        try await Task.sleep(for: .milliseconds(200))
        await loading.value
        XCTAssertFalse(playback.isLoading)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertNil(playback.error)
        let afterStop = changes
        playback.stop()
        XCTAssertEqual(changes, afterStop)
    }

    #if os(macOS)
        func testFinderImagePasteImportsOriginalWithoutInsertingFilename() async throws {
            let h = try await mount(text: "caption")
            let image = NSImage(size: NSSize(width: 16, height: 12), flipped: false) { rect in
                NSColor.red.setFill()
                rect.fill()
                return true
            }
            let data = try XCTUnwrap(image.tiffRepresentation)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("tiff")
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let imported = expectation(description: "Original Finder image imported")
            h.state.onImportImages = { urls in
                XCTAssertEqual(urls.count, 1)
                XCTAssertEqual(try Data(contentsOf: XCTUnwrap(urls.first)), data)
                imported.fulfill()
            }
            try await pause()
            let board = NSPasteboard.general
            let saved = (board.pasteboardItems ?? []).map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) { copy.setData(data, forType: type) }
                }
                return copy
            }
            defer {
                board.clearContents()
                board.writeObjects(saved)
            }
            try h.selectEnd()
            board.clearContents()
            board.setString(" tail", forType: .string)
            try h.focusedEditor().paste(nil)
            try await pause()
            XCTAssertEqual(h.state.text, "caption tail")

            board.clearContents()
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setString(url.lastPathComponent, forType: .string)
            board.writeObjects([item])
            try h.focusedEditor().paste(nil)
            await fulfillment(of: [imported], timeout: 3)
            XCTAssertEqual(h.state.text, "caption tail")
        }
    #endif

    #if os(iOS)
        func testStickerPickerRestoresOnlyDisplacedInputFocus() async throws {
            let h = try await mount(text: "")
            h.state.stickerLibrary = StickerLibrary(apiClient: FakeChatAPI(), onInvalidToken: {})
            try await pause()
            XCTAssertTrue(h.hasFocusedEditor)
            XCTAssertTrue(
                try XCTUnwrap(h.accessibilityElement(named: "Stickers")).accessibilityActivate())
            try await pause()
            XCTAssertFalse(h.hasFocusedEditor)
            XCTAssertTrue(
                try XCTUnwrap(h.accessibilityElement(named: "Close stickers"))
                    .accessibilityActivate())
            try await pause()
            XCTAssertTrue(h.hasFocusedEditor)

            h.blur()
            try await pause()
            XCTAssertTrue(
                try XCTUnwrap(h.accessibilityElement(named: "Stickers")).accessibilityActivate())
            try await pause()
            XCTAssertTrue(
                try XCTUnwrap(h.accessibilityElement(named: "Close stickers"))
                    .accessibilityActivate())
            try await pause()
            XCTAssertFalse(h.hasFocusedEditor)
        }
    #endif

    #if os(iOS)
        func testInputPasteImportsImageWithoutReplacingCaptionAndKeepsTextPasteNative() async throws
        {
            let h = try await mount(text: "caption")
            let imported = expectation(description: "Image imported from input paste")
            h.state.onImportImages = { urls in
                XCTAssertEqual(urls.count, 1)
                let image = try UIImage(data: Data(contentsOf: XCTUnwrap(urls.first)))
                XCTAssertEqual(image?.size, CGSize(width: 16, height: 12))
                imported.fulfill()
            }
            try await pause()
            let editor = try XCTUnwrap(h.focusedEditor() as? UITextView)
            let previousItems = UIPasteboard.general.items
            defer { UIPasteboard.general.items = previousItems }
            try h.selectEnd()
            UIPasteboard.general.string = " tail"
            editor.paste(nil)
            try await pause()
            XCTAssertEqual(h.state.text, "caption tail")

            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            UIPasteboard.general.image = UIGraphicsImageRenderer(
                size: CGSize(width: 16, height: 12), format: format
            ).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
            }
            editor.paste(nil)
            await fulfillment(of: [imported], timeout: 3)
            XCTAssertEqual(
                h.state.text, "caption tail",
                "Images must become attachments, not text replacements.")
        }
    #endif

    func testSendingKeepsEditingSessionThroughDraftCommit() async throws {
        let h = try await mount(text: "send this")
        let editor = try h.focusedEditor()
        #if os(macOS)
            let didEndEditing = NSText.didEndEditingNotification
        #else
            let didEndEditing = UITextView.textDidEndEditingNotification
        #endif
        let observer = NotificationCenter.default.addObserver(
            forName: didEndEditing, object: editor, queue: nil
        ) { _ in MainActor.assumeIsolated { h.state.editingEnded = true } }
        defer { NotificationCenter.default.removeObserver(observer) }
        h.submit()
        try await pause()
        XCTAssertEqual(h.state.submits, 1)
        XCTAssertTrue(try h.focusedEditor() === editor)
        XCTAssertFalse(h.state.editingEnded)
        XCTAssertEqual(h.state.text, "send this", "Do not clear before local enqueue completes.")
        h.state.text = ""
        h.state.canSend = true
        try await pause()
        try h.insertIntoFocusedEditor("next message")
        try await pause()
        XCTAssertEqual(h.state.text, "next message")
        XCTAssertTrue(try h.focusedEditor() === editor)
        XCTAssertFalse(h.state.editingEnded, "Send must not end and restart native editing.")
    }

    #if os(macOS)
        func testSendingExpandedDraftRestoresSingleLineHeight() async throws {
            let h = try await mount(text: "")
            let editor = try h.focusedEditor()
            let singleLineHeight = editor.frame.height
            try h.insertIntoFocusedEditor(
                String(repeating: "A long message that wraps across the composer. ", count: 30))
            try await pause()
            XCTAssertGreaterThan(editor.frame.height, singleLineHeight + 20)
            h.submit()
            try await pause()
            XCTAssertEqual(h.state.submits, 1)
            h.state.text = ""
            h.state.canSend = true
            try await pause()
            XCTAssertEqual(editor.string, "")
            XCTAssertEqual(editor.frame.height, singleLineHeight, accuracy: 1)
            XCTAssertTrue(try h.focusedEditor() === editor)
            try h.insertIntoFocusedEditor("next message")
            try await pause()
            XCTAssertEqual(h.state.text, "next message")
        }
    #endif

    func testSendButtonSubmitsOnceWithoutClearingBeforeCommit() async throws {
        let h = try await mount(text: "send this")
        h.pressSendButton()
        try await pause()
        XCTAssertEqual(h.state.submits, 1)
        XCTAssertEqual(h.state.text, "send this")
        h.pressSendButton()
        try h.selectEnd()
        try h.insertIntoFocusedEditor(" again")
        try await pause()
        XCTAssertEqual(h.state.submits, 1)
        XCTAssertEqual(
            h.state.text, "send this again", "Pending submission must not disable typing.")
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

    func testSendButtonCommitsVisiblePreeditAndSubmitsOnce() async throws {
        let h = try await mount(text: "")
        try h.selectEnd()
        try h.mark("ni")
        try await pause()

        h.pressSendButton()

        try await pause()
        XCTAssertEqual(h.state.submits, 1)
        XCTAssertEqual(h.state.text, "ni")
        XCTAssertFalse(h.state.composing)
        XCTAssertTrue(h.state.enabled)
        h.pressSendButton()
        try await pause()
        XCTAssertEqual(h.state.submits, 1)
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

    func testMentionCompletionDoesNotSendAndSurvivesContinuedTyping() async throws {
        let h = try await mount(text: "")
        var searched = false
        h.state.onSearchMembers = { query in
            if query.mode == "autocomplete", query.q == "a" { searched = true }
            return [.init(uid: 11, username: "Ada")]
        }
        h.state.onSubmit = { [weak state = h.state] text in
            XCTAssertEqual(text, "@[uid:11] hello")
            state?.submits += 1
            return true
        }
        try await pause()
        try h.insertIntoFocusedEditor("@a")
        for _ in 0..<30 {
            if searched { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await pause()
        #if os(iOS)
            XCTAssertTrue(
                h.accessibilityElement(named: "Mention Ada")?.accessibilityActivate() == true)
        #else
            h.pressReturn()
        #endif
        try await pause()
        XCTAssertEqual(h.state.text, "@[uid:11] ")
        XCTAssertEqual(h.state.submits, 0)
        try h.insertIntoFocusedEditor("hello")
        try await pause()
        XCTAssertEqual(h.state.text, "@[uid:11] hello")
        h.pressSendButton()
        try await pause()
        XCTAssertEqual(h.state.submits, 1)
    }

    #if os(macOS)

        func testChatEntryFocusAppendsWithoutSelectingRestoredDraft() async throws {
            let h = try await mount(text: "saved draft")
            try h.insertIntoFocusedEditor("!")
            try await pause()
            XCTAssertEqual(h.state.text, "saved draft!")

            let editor = try h.focusedEditor()
            editor.setSelectedRange(NSRange(location: 1, length: 4))
            h.state.canSend = false
            try await pause()
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 4))
            h.blur()
            h.state.canSend = true
            try await pause()
            XCTAssertFalse(
                h.window.firstResponder === editor,
                "An ordinary update must not reacquire entry focus.")
        }

        func testRestoredTextUsesComposerTypingFont() async throws {
            let h = try await mount(text: "")
            let editor = try h.focusedEditor()
            let typingFont = try XCTUnwrap(
                (editor.typingAttributes[.font] as? NSFont) ?? editor.font)

            h.state.text = "existing message"
            try await pause()

            let loadedFont = try XCTUnwrap(
                editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(loadedFont.fontName, typingFont.fontName)
            XCTAssertEqual(loadedFont.pointSize, typingFont.pointSize)

            try h.selectEnd()
            try h.insertIntoFocusedEditor("!")
            try await pause()
            let typedFont = try XCTUnwrap(
                editor.textStorage?.attribute(
                    .font, at: editor.string.utf16.count - 1, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(typedFont.fontName, typingFont.fontName)
            XCTAssertEqual(typedFont.pointSize, typingFont.pointSize)
        }

        func testChatEntryWaitsForPermissionsWithoutRefocusingOnLaterPermissionChanges()
            async throws
        {
            let h = try await mount(text: "saved draft", enabled: false)
            h.state.enabled = true
            try await pause()
            try h.insertIntoFocusedEditor("!")
            try await pause()
            XCTAssertEqual(h.state.text, "saved draft!")
            let editor = try h.focusedEditor()

            h.blur()
            h.state.enabled = false
            try await pause()
            h.state.enabled = true
            try await pause()
            XCTAssertFalse(h.window.firstResponder === editor)
        }

        func testUserInteractionCancelsDelayedEntryFocus() async throws {
            let h = try await mount(text: "saved draft", enabled: false)
            h.pressBackground()
            h.state.enabled = true
            try await pause()
            XCTAssertFalse(
                h.window.firstResponder is NSTextView,
                "Permission loading must not undo the user's navigation click.")
            XCTAssertEqual(h.state.text, "saved draft")
        }

        func testLongCaptionKeepsCaretAndScrollsInsideSixLineViewport() async throws {
            let caption = (1...30).map { "Caption line \($0)" }.joined(separator: "\n")
            let h = try await mount(text: caption, caption: true)
            let editor = try h.focusedEditor()
            try h.selectEnd()
            try h.insertIntoFocusedEditor("!")
            try await pause()
            XCTAssertEqual(h.state.text, caption + "!")

            let scroll = try XCTUnwrap(editor.enclosingScrollView)
            let font = try XCTUnwrap(editor.font)
            let layout = try XCTUnwrap(editor.layoutManager)
            let viewportHeight = scroll.contentView.bounds.height
            XCTAssertLessThanOrEqual(
                viewportHeight, ceil(layout.defaultLineHeight(for: font) * 6) + 1)
            XCTAssertGreaterThan(editor.bounds.height, viewportHeight)
            editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
            XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
            editor.scrollRangeToVisible(NSRange(location: editor.string.utf16.count, length: 0))
            XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
            XCTAssertEqual(scroll.contentView.bounds.height, viewportHeight)
        }

        func testCaptionNativeSelectionUndoAndMarkedTextSurviveUpdates() async throws {
            let h = try await mount(text: "abcd", caption: true)
            let editor = try h.focusedEditor()
            editor.setSelectedRange(NSRange(location: 1, length: 2))
            h.pressReturn(shift: true)
            try await pause()
            XCTAssertEqual(h.state.text, "a\nd")
            editor.undoManager?.undo()
            try await pause()
            XCTAssertEqual(h.state.text, "abcd")

            try h.selectEnd()
            try h.mark("ni")
            try await pause()
            XCTAssertEqual(h.state.text, "abcd")
            XCTAssertTrue(h.state.composing)
            let selectedRange = editor.selectedRange()
            h.state.canSend = false
            try await pause()
            XCTAssertTrue(editor.hasMarkedText())
            XCTAssertEqual(editor.selectedRange(), selectedRange)
            try h.insertIntoFocusedEditor("你")
            try await pause()
            XCTAssertEqual(h.state.text, "abcd你")
            XCTAssertFalse(h.state.composing)
            XCTAssertEqual(h.state.submits, 0)
        }

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
            XCTAssertFalse(
                h.state.editingEnded, "Return must not end and restart AppKit field editing.")
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

    #if os(iOS)

        func testAttachmentCaptionAndSendRemainAboveKeyboardWithPortraitPreview() async throws {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString + ".png")
            let data = try makeMediaPNG(red: 40, green: 120, blue: 200, width: 300, height: 900)
            try data.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let h = try await mount(text: "Keep this caption", caption: true)
            h.state.media = [
                LocalOutgoingAttachment(
                    id: "portrait", generation: "original", position: 0,
                    sourcePath: file.path, previewPath: file.path, fileName: "portrait.png",
                    mimeType: "image/png", width: 300, height: 900, byteCount: Int64(data.count))
            ]
            // Exercise the presented sheet, not an inline approximation of its root.
            let presented = try XCTUnwrap(h.host.presentedViewController)
            presented.additionalSafeAreaInsets.bottom = 100
            try await Task.sleep(for: .milliseconds(600))
            let root = h.editorRoot
            root.layoutIfNeeded()
            let editor = try XCTUnwrap(try h.focusedEditor() as? UIView)
            let caption = editor.convert(editor.bounds, to: root)
            let send = try XCTUnwrap(h.accessibilityElement(named: "Send"))
            let sendFrame = root.convert(
                h.window.convert(send.accessibilityFrame, from: h.window.screen.coordinateSpace),
                from: h.window)
            let bottom = min(
                root.safeAreaLayoutGuide.layoutFrame.maxY, root.keyboardLayoutGuide.layoutFrame.minY
            )
            XCTAssertGreaterThan(caption.height, 0)
            XCTAssertGreaterThanOrEqual(caption.minY, root.safeAreaLayoutGuide.layoutFrame.minY)
            XCTAssertLessThanOrEqual(caption.maxY, bottom + 1)
            XCTAssertGreaterThan(sendFrame.height, 0)
            XCTAssertLessThanOrEqual(sendFrame.maxY, bottom + 1)
            let hideKeyboard = try XCTUnwrap(h.accessibilityElement(named: "Hide keyboard"))
            XCTAssertTrue(hideKeyboard.accessibilityActivate())
            try await pause()
            XCTAssertFalse(editor.isFirstResponder)
            XCTAssertEqual(h.state.text, "Keep this caption")
        }
    #endif

    private func pause() async throws { try await Task.sleep(for: .milliseconds(200)) }

    private func mount(text: String, enabled: Bool = true, caption: Bool = false) async throws
        -> FocusComposerHarness
    {
        let harness = try FocusComposerHarness(text: text, enabled: enabled, caption: caption)
        addTeardownBlock { @MainActor in harness.close() }
        try await pause()
        #if os(macOS)
            if caption {
                try harness.focus()
                try await pause()
            }
        #else
            if caption { try await Task.sleep(for: .milliseconds(400)) }
            try harness.focus()
            try await pause()
        #endif
        return harness
    }
}

@MainActor
private final class FocusComposerState: ObservableObject {
    let attachments = ComposerAttachmentState()
    @Published var text: String
    @Published var enabled = true
    @Published var canSend = true
    @Published var media: [LocalOutgoingAttachment] = []
    let caption: Bool
    @Published var showsComposer = true
    @Published var onImportImages: (([URL]) async throws -> Void)?
    @Published var stickerLibrary: StickerLibrary?
    @Published var onSearchMembers: ComposerMemberSearch?
    var onSubmit: ((String) async -> Bool)?
    var composing = false
    var submits = 0
    var editingEnded = false
    init(text: String, enabled: Bool, caption: Bool) {
        self.text = text
        self.enabled = enabled
        self.caption = caption
    }
}

private struct FocusComposerRoot: View {
    @ObservedObject var state: FocusComposerState
    var body: some View {
        VStack {
            Spacer()
            if state.caption {
                #if os(iOS)
                    Color.clear.sheet(isPresented: $state.showsComposer) { captionDialog }
                #else
                    captionDialog
                #endif
            } else if state.showsComposer {
                MessageComposerView(
                    text: $state.text, attachmentState: state.attachments,
                    maxHeight: 160, isEnabled: state.enabled, canSend: state.canSend,
                    onSubmit: { text in
                        if let submit = state.onSubmit { return await submit(text) }
                        state.submits += 1
                        state.canSend = false
                        return true
                    }, onCompositionChanged: { state.composing = $0 },
                    attachments: state.media,
                    onImportImages: state.onImportImages,
                    onDiscardAttachments: { state.media = [] },
                    stickerLibrary: state.stickerLibrary, onSendSticker: { _ in true },
                    onSearchMembers: state.onSearchMembers)
            }
        }
    }

    private var captionDialog: some View {
        ComposerAttachmentDialog(
            text: $state.text, attachments: state.media, progress: [:],
            compressionEnabled: true, isEnabled: state.enabled, canSend: state.canSend,
            isAcquiring: false, attachmentError: nil,
            onCompositionChanged: { state.composing = $0 },
            onRemove: { _ in }, onRetry: { _ in }, onCompressionChanged: { _ in },
            onReorder: { _ in }, onImportProviders: { _ in },
            onSubmit: {
                state.submits += 1
                return true
            }, onCancel: {},
            onSearchMembers: state.onSearchMembers)
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
        private static let accessibilityLibrary = dlopen(
            "/usr/lib/libAccessibility.dylib", RTLD_NOW)
        private var restoreAccessibility: (() -> Void)?
    #endif

    init(text: String, enabled: Bool, caption: Bool) throws {
        state = FocusComposerState(text: text, enabled: enabled, caption: caption)
        #if os(macOS)
            host = NSHostingController(rootView: FocusComposerRoot(state: state))
            host.sizingOptions = []
            let height: CGFloat = caption ? 620 : 220
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: height), styleMask: [.titled],
                backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            window.setContentSize(NSSize(width: 800, height: height))
            host.view.frame = NSRect(x: 0, y: 0, width: 800, height: height)
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
            state.showsComposer = false
            host.dismiss(animated: false)
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

    var editorRoot: ComposerTestView {
        #if os(macOS)
            host.view
        #else
            host.presentedViewController?.view ?? host.view
        #endif
    }

    var hasFocusedEditor: Bool {
        #if os(macOS)
            window.firstResponder is NSTextView
        #else
            allViews(editorRoot).contains { $0.isFirstResponder && $0 is any UITextInput }
        #endif
    }

    func focus() throws {
        let views = allViews(editorRoot)
        #if os(macOS)
            if let field = views.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable })
            {
                XCTAssertTrue(window.makeFirstResponder(field))
            } else {
                let editor = try XCTUnwrap(
                    views.compactMap({ $0 as? NSTextView }).first(where: { $0.isEditable }))
                XCTAssertTrue(window.makeFirstResponder(editor))
            }
        #else
            let editor = try XCTUnwrap(
                views.first(where: { $0 is any UITextInput && $0.canBecomeFirstResponder }))
            XCTAssertTrue(editor.becomeFirstResponder())
        #endif
    }

    #if os(macOS)
        func focusedEditor() throws -> NSTextView {
            try XCTUnwrap(
                window.firstResponder as? NSTextView,
                "Typing must not require refocusing the composer.")
        }
    #else
        func focusedEditor() throws -> any UITextInput {
            try XCTUnwrap(
                allViews(editorRoot).first(where: \.isFirstResponder) as? any UITextInput,
                "Typing must not require refocusing the composer.")
        }
    #endif

    func selectEnd() throws {
        let editor = try focusedEditor()
        #if os(macOS)
            editor.setSelectedRange(
                NSRange(location: (editor.string as NSString).length, length: 0))
        #else
            editor.selectedTextRange = editor.textRange(
                from: editor.endOfDocument, to: editor.endOfDocument)
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
            editor.setMarkedText(
                text, selectedRange: NSRange(location: text.utf16.count, length: 0))
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
        func pressBackground() {
            let point = host.view.convert(
                NSPoint(x: 10, y: host.view.isFlipped ? 10 : host.view.bounds.height - 10), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                NSApp.sendEvent(event)
            }
        }

        func pressSendButton() {
            let point = host.view.convert(
                NSPoint(
                    x: host.view.bounds.width - 34,
                    y: host.view.isFlipped ? host.view.bounds.height - 34 : 34), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                NSApp.sendEvent(event)
            }
        }
    #else
        @discardableResult
        func pressSendButton() -> Bool {
            accessibilityElement(named: "Send message")?.accessibilityActivate() ?? false
        }

        func accessibilityElement(named label: String) -> NSObject? {
            func find(_ element: NSObject) -> NSObject? {
                if element.accessibilityLabel == label { return element }
                let count = element.accessibilityElementCount()
                let exposed =
                    count > 0 && count < 1000
                    ? (0..<count).compactMap { element.accessibilityElement(at: $0) } : []
                for child in exposed + ((element as? UIView)?.subviews ?? []) {
                    if let child = child as? NSObject, let match = find(child) { return match }
                }
                return nil
            }
            return find(editorRoot)
        }
    #endif

    func pressReturn(shift: Bool = false) {
        #if os(macOS)
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                keyCode: 36)!
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
