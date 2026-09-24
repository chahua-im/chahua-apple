import Combine
import CoreFoundation
import SwiftUI

/// The native editor owns editing, selection, undo, and IME. The draft binding
/// contains only committed wire text; editorText is its visible representation.
@MainActor
final class ComposerInputState: ObservableObject {
    @Published private(set) var editorText: String?
    @Published private(set) var isComposing = false
    @Published private(set) var mentionQuery: ComposerMentionQuery?
    var onMentionKey: ((ComposerMentionKey) -> Bool)?
    weak var nativeInput: (any ComposerNativeInput)?
    private(set) var mentionText = NSAttributedString(string: "")

    private var mentionNames: [Int32: String] = [:]
    private var draft: Binding<String>?
    private var compositionChanged: ((Bool) -> Void)?
    private var hasPendingEdit = false
    private var settlementObserver: CFRunLoopObserver?
    private var endingSnapshot: ComposerInputSnapshot?
    private var endingMentionText: NSAttributedString?
    // An editing-end notification can be sent synchronously while SwiftUI is
    // reconciling a representable's focus. Keep its query dismissal and IME
    // gate private until the existing run-loop settlement boundary publishes
    // the settled native snapshot.
    private var mentionQueryToClearAfterEditingEnd: ComposerMentionQuery?
    private var hasPendingComposition = false

    func configure(draft: Binding<String>, onCompositionChanged: ((Bool) -> Void)?) {
        self.draft = draft
        compositionChanged = onCompositionChanged
    }

    func receiveExternalText(_ text: String) {
        // Restoration must not replace an in-flight user edit. A binding echo of
        // our own commit must not recreate spans or erase the native undo stack.
        guard !isComposing, !hasPendingComposition, !hasPendingEdit else { return }
        guard ComposerMentionText.wireText(mentionText) != text || editorText == nil else { return }
        mentionText = ComposerMentionText.expand(text, names: mentionNames)
        editorText = mentionText.string
        nativeInput?.installMentionText(mentionText)
        refreshMentionQuery()
    }

    func setMentionNames(_ names: [Int32: String]) {
        mentionNames.merge(names.filter { !$0.value.isEmpty }, uniquingKeysWith: { _, new in new })
        hydrateMentionNames()
    }

    private func hydrateMentionNames() {
        guard !isComposing, !hasPendingComposition, !hasPendingEdit,
            nativeInput?.canHydrateMentionLabels != false
        else { return }
        let hydrated = NSMutableAttributedString(attributedString: mentionText)
        for (span, range) in ComposerMentionText.spans(in: mentionText).reversed() {
            guard let name = mentionNames[span.uid], span.text != "@" + name else { continue }
            hydrated.replaceCharacters(
                in: range, with: ComposerMentionText.mention(uid: span.uid, label: name))
        }
        guard hydrated.string != mentionText.string else { return }
        mentionText = hydrated
        editorText = hydrated.string
        nativeInput?.installMentionText(hydrated)
        refreshMentionQuery()
    }

    func receiveEditorText(_ text: String) {
        // UIKit echoes the binding when focus/editability changes. An unchanged
        // value is not a pending user edit and must not block draft restoration.
        if editorText != text {
            editorText = text
            hasPendingEdit = true
        }
        nativeInputChanged()
    }

    func nativeInputChanged(isEdit: Bool = false) {
        hasPendingEdit = hasPendingEdit || isEdit
        if case .marked = nativeInput?.snapshot() { beginComposition() }
        scheduleSettlement()
    }

    func nativeEditingBegan() {
        // A new native editor session supersedes a pending focus-loss state.
        mentionQueryToClearAfterEditingEnd = nil
        hasPendingComposition = false
    }

    func nativeEditingEnded(
        _ snapshot: ComposerInputSnapshot, visibleText: NSAttributedString? = nil
    ) {
        endingSnapshot = snapshot
        endingMentionText = visibleText ?? nativeInput?.attributedText
        if case .marked = snapshot {
            hasPendingComposition = true
        } else {
            mentionQueryToClearAfterEditingEnd = mentionQuery
        }
        scheduleSettlement()
    }

    func refreshMentionQuery() {
        // The end snapshot may still hold IME preedit while SwiftUI is
        // reconciling focus. Settlement publishes its composition state.
        guard !hasPendingComposition else { return }
        guard !isComposing, let nativeInput,
            case .committed = nativeInput.snapshot(),
            let text = nativeInput.attributedText, let selection = nativeInput.selection
        else {
            if mentionQuery != nil { mentionQuery = nil }
            return
        }
        let query = ComposerMentionText.query(in: text, selection: selection)
        if mentionQuery != query { mentionQuery = query }
    }

    func insertMention(uid: Int32, label: String, query: ComposerMentionQuery) -> Bool {
        refreshMentionQuery()
        guard !isComposing, !hasPendingComposition, mentionQuery == query, let nativeInput else {
            return false
        }
        let replacement = NSMutableAttributedString(
            attributedString: ComposerMentionText.mention(uid: uid, label: label))
        replacement.append(NSAttributedString(string: " "))
        guard nativeInput.replaceMention(in: query.range, with: replacement) else { return false }
        mentionNames[uid] = label
        hasPendingEdit = true
        finishEditing(snapshot: nativeInput.snapshot())
        return true
    }

    func prepareSubmission(allowEmptyUnfocused: Bool = false) -> Bool {
        // Treat a marked editing-end snapshot as composing until settlement;
        // a candidate-confirmation Return must not send in that interval.
        guard !hasPendingComposition else { return false }
        var snapshot = nativeInput?.snapshot() ?? .unavailable
        if case .unavailable = snapshot { snapshot = endingSnapshot ?? .unavailable }
        if case .marked = snapshot {
            beginComposition()
            scheduleSettlement()
        }
        // A candidate-confirmation Return never sends, including Latin preedit
        // which unmarks without changing its string in this same transaction.
        if allowEmptyUnfocused, !isComposing, !hasPendingEdit,
            (editorText ?? draft?.wrappedValue ?? "").isEmpty, case .unavailable = snapshot
        {
            return true
        }
        guard !isComposing, case .committed = snapshot else { return false }
        hasPendingEdit = true
        finishEditing(snapshot: snapshot)
        return true
    }

    func prepareExplicitSubmission(allowEmptyUnfocused: Bool = false) -> Bool {
        // The button is an explicit commit, not an input-method Return. Unmark
        // accepts the visible preedit; never synthesize a key or select a candidate.
        var snapshot = nativeInput?.commitMarkedText() ?? .unavailable
        if case .unavailable = snapshot {
            snapshot = endingSnapshot ?? .unavailable
            if case .marked = snapshot, let endingMentionText {
                // Focus loss may already have relinquished the shared editor.
                // Only this transaction's owned visible snapshot may be committed.
                snapshot = .committed(ComposerMentionText.wireText(endingMentionText))
            }
        }
        if allowEmptyUnfocused, !isComposing, !hasPendingEdit,
            (editorText ?? draft?.wrappedValue ?? "").isEmpty, case .unavailable = snapshot
        {
            return true
        }
        guard case .committed = snapshot else { return false }
        hasPendingEdit = true
        finishEditing(snapshot: snapshot)
        return true
    }

    private func beginComposition() {
        hasPendingComposition = false
        mentionQuery = nil
        guard !isComposing else { return }
        isComposing = true
        compositionChanged?(true)
    }

    private func scheduleSettlement() {
        guard settlementObserver == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.settleNativeInput() }
        }
        settlementObserver = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func settleNativeInput() {
        var snapshot = nativeInput?.snapshot() ?? .unavailable
        if case .unavailable = snapshot { snapshot = endingSnapshot ?? .unavailable }
        if case .marked = snapshot {
            beginComposition()
            return
        }
        finishEditing(snapshot: snapshot)
        if let query = mentionQueryToClearAfterEditingEnd, mentionQuery == query {
            mentionQuery = nil
        }
        mentionQueryToClearAfterEditingEnd = nil
    }

    func detach(finalSnapshot: ComposerInputSnapshot? = nil) {
        var snapshot = finalSnapshot ?? .unavailable
        if case .unavailable = snapshot { snapshot = endingSnapshot ?? .unavailable }
        finishEditing(snapshot: snapshot)
        mentionQuery = nil
    }

    func detachAfterViewUpdate(finalSnapshot: ComposerInputSnapshot? = nil) {
        stopObserving()
        DispatchQueue.main.async { self.detach(finalSnapshot: finalSnapshot) }
    }

    private func finishEditing(snapshot: ComposerInputSnapshot) {
        let shouldPublish = hasPendingEdit || isComposing || hasPendingComposition
        let visible = nativeInput?.attributedText ?? endingMentionText
        hasPendingEdit = false
        hasPendingComposition = false
        endingSnapshot = nil
        endingMentionText = nil
        stopObserving()
        if shouldPublish, case .committed(let text) = snapshot {
            if let visible, ComposerMentionText.wireText(visible) == text {
                mentionText = visible
            } else {
                mentionText = ComposerMentionText.expand(text, names: mentionNames)
            }
        } else if case .unavailable = snapshot, let text = draft?.wrappedValue {
            mentionText = ComposerMentionText.expand(text, names: mentionNames)
        } else if case .marked = snapshot, let text = draft?.wrappedValue {
            // An unresolved teardown must not persist preedit.
            mentionText = ComposerMentionText.expand(text, names: mentionNames)
        }
        if editorText != mentionText.string { editorText = mentionText.string }
        if shouldPublish, case .committed(let text) = snapshot, draft?.wrappedValue != text {
            draft?.wrappedValue = text
        }
        if isComposing {
            isComposing = false
            compositionChanged?(false)
        }
        hydrateMentionNames()
        refreshMentionQuery()
    }

    private func stopObserving() {
        if let settlementObserver { CFRunLoopObserverInvalidate(settlementObserver) }
        settlementObserver = nil
    }
}
