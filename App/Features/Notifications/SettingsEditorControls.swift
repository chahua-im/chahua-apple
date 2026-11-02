import SwiftUI

private struct SettingsUsesSplitLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var settingsUsesSplitLayout: Bool {
        get { self[SettingsUsesSplitLayoutKey.self] }
        set { self[SettingsUsesSplitLayoutKey.self] = newValue }
    }
}

extension View {
    func settingsEditorControls(
        title: LocalizedStringKey,
        isDirty: Bool,
        canSave: Bool,
        isSaving: Bool,
        accountID: Int32?,
        onSave: @escaping () -> Void,
        onRevert: @escaping () -> Void,
        onFinish: @escaping () -> Void
    ) -> some View {
        modifier(
            SettingsEditorControls(
                title: title, isDirty: isDirty, canSave: canSave, isSaving: isSaving,
                accountID: accountID, onSave: onSave, onRevert: onRevert, onFinish: onFinish))
    }
}

private struct SettingsEditorControls: ViewModifier {
    let title: LocalizedStringKey
    let isDirty: Bool
    let canSave: Bool
    let isSaving: Bool
    let accountID: Int32?
    let onSave: () -> Void
    let onRevert: () -> Void
    let onFinish: () -> Void
    @Environment(\.settingsUsesSplitLayout) private var usesSplitLayout
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsDiscardConfirmation = false
    @State private var discardAccountID: Int32?

    private var canCommit: Bool { isDirty && canSave && !isSaving }

    func body(content: Content) -> some View {
        Group {
            if usesSplitLayout {
                VStack(spacing: 0) {
                    splitHeader
                    content
                        .disabled(isSaving)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #if os(macOS)
                        // The macOS reference keeps commit controls out of the title toolbar.
                        if isDirty { macSaveBar }
                    #endif
                }
                .background(colorScheme == .dark ? Color(white: 0.11) : Color.white)
            } else {
                content.disabled(isSaving)
            }
        }
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(usesSplitLayout ? .hidden : .visible, for: .navigationBar)
            // SwiftUI has no native Back/swipe veto; only phone navigation needs the bridge.
            .background {
                if !usesSplitLayout {
                    SettingsEditorNavigationGuard(
                        blocksBack: isDirty || isSaving, onBackAttempt: requestDismiss
                    )
                    .frame(width: 0, height: 0)
                }
            }
        #endif
        .toolbar {
            if !usesSplitLayout {
                #if os(macOS)
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Back", action: requestDismiss)
                            .disabled(isSaving)
                            .keyboardShortcut(.cancelAction)
                    }
                #endif
                ToolbarItem(placement: .confirmationAction) {
                    saveButton
                }
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

    private var splitHeader: some View {
        HStack(spacing: 8) {
            Text(title)
                #if os(macOS)
                    .font(.system(size: 17, weight: .bold))
                #else
                    .font(.system(size: 20, weight: .bold))
                #endif
                .frame(maxWidth: .infinity, alignment: .leading)
            #if os(iOS)
                // iPad keeps Save visible even when clean, unlike the macOS dirty-only footer.
                saveButton
            #endif
        }
        .padding(.leading, 28)
        .padding(.trailing, 20)
        #if os(macOS)
            .frame(minHeight: 56)
        #else
            .frame(minHeight: 64)
        #endif
    }

    private var saveButton: some View {
        Button(action: onSave) {
            Group {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .tint(isDirty ? .white : .secondary)
                        .accessibilityLabel("Saving…")
                } else {
                    Text("Save")
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isDirty ? Color.white : Color.secondary)
            .padding(.horizontal, 18)
            .frame(minHeight: 36)
            .background(
                isDirty ? Color.blue : Color.primary.opacity(0.06),
                in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canCommit)
    }

    #if os(macOS)
        private var macSaveBar: some View {
            HStack(spacing: 8) {
                Text("Unsaved changes")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Revert", action: onRevert)
                    .disabled(isSaving)
                Button(action: onSave) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Saving…")
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(!canCommit)
            }
            .controlSize(.regular)
            .padding(.leading, 28)
            .padding(.trailing, 20)
            .frame(height: 52)
            .background(Color.primary.opacity(0.025))
            .overlay(alignment: .top) { Divider() }
        }
    #endif

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
