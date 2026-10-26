import SwiftUI

extension View {
    func settingsEditorControls(
        isDirty: Bool,
        canSave: Bool,
        isSaving: Bool,
        accountID: Int32?,
        onSave: @escaping () -> Void,
        onFinish: @escaping () -> Void
    ) -> some View {
        modifier(
            SettingsEditorControls(
                isDirty: isDirty, canSave: canSave, isSaving: isSaving,
                accountID: accountID, onSave: onSave, onFinish: onFinish))
    }
}

private struct SettingsEditorControls: ViewModifier {
    let isDirty: Bool
    let canSave: Bool
    let isSaving: Bool
    let accountID: Int32?
    let onSave: () -> Void
    let onFinish: () -> Void
    @State private var showsDiscardConfirmation = false
    @State private var discardAccountID: Int32?

    private var primarySave: Bool { isSaving || (isDirty && canSave) }

    func body(content: Content) -> some View {
        content
            .disabled(isSaving)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                // SwiftUI has no native Back/swipe veto; the bridge preserves the system controls.
                .background {
                    SettingsEditorNavigationGuard(
                        blocksBack: isDirty || isSaving, onBackAttempt: requestDismiss
                    )
                    .frame(width: 0, height: 0)
                }
            #endif
            .toolbar {
                #if os(macOS)
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Back", action: requestDismiss)
                            .disabled(isSaving)
                            .keyboardShortcut(.cancelAction)
                    }
                #endif
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onSave) {
                        Group {
                            if isSaving {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(primarySave ? .white : .primary)
                                    .accessibilityLabel("Saving…")
                            } else {
                                Text("Save")
                            }
                        }
                        .foregroundStyle(primarySave ? Color.white : Color.primary)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 36)
                        .background(
                            primarySave ? Color.blue : Color.clear,
                            in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                    .tint(.primary)
                }
            }
            .interactiveDismissDisabled(isDirty || isSaving)
            .preference(key: SettingsEditorExitProtectionKey.self, value: isDirty || isSaving)
            .alert("Discard unsaved changes?", isPresented: $showsDiscardConfirmation) {
                Button("Discard Changes", role: .destructive) {
                    guard !isSaving, discardAccountID == accountID else { return }
                    onFinish()
                }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("Your changes haven’t been saved.")
            }
            .onChange(of: accountID) { _, _ in
                showsDiscardConfirmation = false
                discardAccountID = nil
            }
    }

    private func requestDismiss() {
        guard !isSaving else { return }
        if isDirty {
            discardAccountID = accountID
            showsDiscardConfirmation = true
        } else {
            onFinish()
        }
    }
}
