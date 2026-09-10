import Combine
import CoreFoundation
import SwiftUI

/// The native editor owns editing, selection, undo, and IME. Only committed
/// text crosses the draft binding; marked text belongs to this view's lifetime.
@MainActor
final class ComposerInputState: ObservableObject {
    @Published private(set) var editorText: String?
    @Published private(set) var isComposing = false
    weak var nativeInput: (any ComposerNativeInput)?

    private var draft: Binding<String>?
    private var compositionChanged: ((Bool) -> Void)?
    private var hasPendingEdit = false
    private var settlementObserver: CFRunLoopObserver?
    private var endingSnapshot: ComposerInputSnapshot?

    func configure(draft: Binding<String>, onCompositionChanged: ((Bool) -> Void)?) {
        self.draft = draft
        compositionChanged = onCompositionChanged
    }

    func receiveExternalText(_ text: String) {
        // Restoration must not replace an in-flight user edit. The binding
        // remains the fallback if the editor detaches without a commit.
        guard !isComposing, !hasPendingEdit else { return }
        editorText = text
    }

    func receiveEditorText(_ text: String) {
        // UIKit echoes the binding when focus/editability changes. An unchanged
        // value is not a pending user edit and must not block draft restoration.
        if editorText != text {
            editorText = text
            hasPendingEdit = true
        }
        // Still inspect IME: its marked range can change without a string edit.
        nativeInputChanged()
    }

    func nativeInputChanged(isEdit: Bool = false) {
        hasPendingEdit = hasPendingEdit || isEdit
        if case .marked = nativeInput?.snapshot() { beginComposition() }
        scheduleSettlement()
    }

    func nativeEditingEnded(_ snapshot: ComposerInputSnapshot) {
        endingSnapshot = snapshot
        if case .marked = snapshot { beginComposition() }
        scheduleSettlement()
    }

    func prepareSubmission() -> Bool {
        var snapshot = nativeInput?.snapshot() ?? .unavailable
        // AppKit ends editing before SwiftUI calls onSubmit. This snapshot was
        // captured while the editor still belonged to us, in this transaction.
        if case .unavailable = snapshot { snapshot = endingSnapshot ?? .unavailable }
        if case .marked = snapshot {
            beginComposition()
            scheduleSettlement()
        }
        // Candidate-confirmation Return must not send, even after native unmark
        // but before the composition boundary has settled.
        guard !isComposing, case .committed = snapshot else { return false }
        hasPendingEdit = true
        finishEditing(snapshot: snapshot)
        return true
    }

    private func beginComposition() {
        guard !isComposing else { return }
        isComposing = true
        compositionChanged?(true)
    }

    private func scheduleSettlement() {
        guard settlementObserver == nil else { return }
        // The binding may update before the native marked range. Settle at the
        // transaction boundary, and keep observing only while edits/IME need it.
        // Unmark can commit without changing the string or firing onChange.
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
    }

    func detach(finalSnapshot: ComposerInputSnapshot? = nil) {
        var snapshot = finalSnapshot ?? .unavailable
        if case .unavailable = snapshot { snapshot = endingSnapshot ?? .unavailable }
        finishEditing(snapshot: snapshot)
    }

    func detachAfterViewUpdate(finalSnapshot: ComposerInputSnapshot? = nil) {
        stopObserving()
        // Representable destruction runs inside SwiftUI's graph update. Defer
        // observable publication to avoid reentering its exclusive access.
        DispatchQueue.main.async { self.detach(finalSnapshot: finalSnapshot) }
    }

    private func finishEditing(snapshot: ComposerInputSnapshot) {
        let shouldPublish = hasPendingEdit || isComposing
        hasPendingEdit = false
        endingSnapshot = nil
        stopObserving()
        if shouldPublish, case .committed(let text) = snapshot, draft?.wrappedValue != text {
            draft?.wrappedValue = text
        }
        if editorText != draft?.wrappedValue { editorText = draft?.wrappedValue }
        // Publish the final draft before resuming persistence.
        if isComposing {
            isComposing = false
            compositionChanged?(false)
        }
    }

    private func stopObserving() {
        if let settlementObserver { CFRunLoopObserverInvalidate(settlementObserver) }
        settlementObserver = nil
    }
}
