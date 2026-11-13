import Combine
import SwiftUI

/// A presentation-scoped exit decision. Registrations belong to the form, not its
/// transient child destinations, so pushing a picker must not unregister the form.
@MainActor
final class FormExitGuard: ObservableObject {
    @Published private(set) var isProtected = false
    @Published var showsDiscardConfirmation = false

    private struct Identity: Equatable {
        let owner: UUID
        let accountID: Int32?
        let sessionRevision: Int
    }

    private struct PendingExit {
        let identity: Identity
        let action: () -> Void
        let onCancel: (() -> Void)?
    }

    private var identity: Identity?
    private var isDirty = false
    private var isSubmitting = false
    private var pendingExit: PendingExit?

    func update(
        owner: UUID, isDirty: Bool, isSubmitting: Bool,
        accountID: Int32?, sessionRevision: Int
    ) {
        let next = Identity(owner: owner, accountID: accountID, sessionRevision: sessionRevision)
        if identity != next {
            clearPendingExit()
        }
        identity = next
        self.isDirty = isDirty
        self.isSubmitting = isSubmitting
        let protected = isDirty || isSubmitting
        if isProtected != protected { isProtected = protected }
    }

    func requestExit(_ action: @escaping () -> Void, onCancel: (() -> Void)? = nil) {
        guard !isSubmitting, pendingExit == nil else { return }
        guard isDirty, let identity else {
            action()
            return
        }
        pendingExit = PendingExit(identity: identity, action: action, onCancel: onCancel)
        showsDiscardConfirmation = true
    }

    func confirmDiscard() {
        let pending = pendingExit
        clearPendingExit()
        guard let pending, pending.identity == identity, !isSubmitting else { return }
        pending.action()
    }

    func cancelDiscard() {
        let pending = pendingExit
        clearPendingExit()
        guard let pending, pending.identity == identity else { return }
        pending.onCancel?()
    }

    func unregister(owner: UUID) {
        guard identity?.owner == owner else { return }
        invalidate()
    }

    func invalidate() {
        clearPendingExit()
        identity = nil
        isDirty = false
        isSubmitting = false
        if isProtected { isProtected = false }
    }

    private func clearPendingExit() {
        pendingExit = nil
        if showsDiscardConfirmation { showsDiscardConfirmation = false }
    }
}

extension View {
    func formDiscardConfirmation(_ exitGuard: FormExitGuard) -> some View {
        modifier(FormDiscardConfirmation(exitGuard: exitGuard))
    }

    func formBackProtection(_ exitGuard: FormExitGuard, onBack: @escaping () -> Void) -> some View {
        modifier(FormBackProtection(exitGuard: exitGuard, onBack: onBack))
    }
}

private struct FormDiscardConfirmation: ViewModifier {
    @ObservedObject var exitGuard: FormExitGuard

    func body(content: Content) -> some View {
        content.alert(
            "Discard unsaved changes?",
            isPresented: Binding(
                get: { exitGuard.showsDiscardConfirmation },
                set: { visible in
                    if exitGuard.showsDiscardConfirmation != visible {
                        exitGuard.showsDiscardConfirmation = visible
                    }
                })
        ) {
            Button("Discard Changes", role: .destructive) { exitGuard.confirmDiscard() }
            Button("Keep Editing", role: .cancel) { exitGuard.cancelDiscard() }
        } message: {
            Text("Your changes haven’t been saved.")
        }
    }
}

private struct FormBackProtection: ViewModifier {
    @ObservedObject var exitGuard: FormExitGuard
    let onBack: () -> Void

    func body(content: Content) -> some View {
        content
            #if os(iOS)
                // Keep native Back and swipe behavior, including child-picker ownership.
                .background {
                    SettingsEditorNavigationGuard(
                        blocksBack: exitGuard.isProtected,
                        onBackAttempt: { exitGuard.requestExit(onBack) }
                    )
                    .frame(width: 0, height: 0)
                }
            #elseif os(macOS)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Back") { exitGuard.requestExit(onBack) }
                        .keyboardShortcut(.cancelAction)
                    }
                }
            #endif
    }
}
