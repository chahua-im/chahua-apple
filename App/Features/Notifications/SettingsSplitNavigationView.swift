import ChahuaAPI
import SwiftUI

/// Wide settings keep category selection outside the detail navigation stack so existing
/// nested destinations cannot replace the sidebar or bypass an editor's exit protection.
struct SettingsSplitNavigationView: View {
    let settings: NotificationSettingsView
    let compact: Bool
    @State private var selection: SettingsPage? = .language
    @State private var protectsEditorEdits = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var metrics: SettingsSplitMetrics { SettingsSplitMetrics(compact: compact) }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                sidebar
                    .frame(width: min(metrics.sidebarWidth, max(220, geometry.size.width * 0.4)))
                Divider()
                detail
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(colorScheme == .dark ? Color.black : Color.white)
        .environment(\.settingsUsesSplitLayout, true)
        .onPreferenceChange(SettingsEditorExitProtectionKey.self) {
            protectsEditorEdits = $0
        }
        .interactiveDismissDisabled(protectsEditorEdits)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Close", systemImage: "xmark") {
                    guard !protectsEditorEdits else { return }
                    if let onClose = settings.onClose {
                        onClose()
                    } else {
                        dismiss()
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: metrics.closeSize, height: metrics.closeSize)
                .background(.primary.opacity(0.07), in: Circle())
                .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    settings.sidebarAccountSummary(compact: compact)
                        .padding(.horizontal, 18)
                        .padding(.top, 2)
                        .padding(.bottom, 10)
                    categoryRow(.savedMessages)
                    categorySection("General", pages: SettingsPage.generalPages)
                    categorySection("Privacy and Security", pages: SettingsPage.privacyPages)
                    categorySection("Stickers", pages: SettingsPage.stickerPages)
                    categorySection("Notifications", pages: [.notifications])
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)

            Divider()
            settings.signOutRow
                .buttonStyle(.plain)
                .font(.system(size: metrics.rowFontSize, weight: .medium))
                .padding(.horizontal, compact ? 18 : 20)
                .padding(.vertical, 8)
        }
        .disabled(protectsEditorEdits)
        .background(
            colorScheme == .dark
                ? Color.white.opacity(0.06)
                : Color(red: 0.96, green: 0.96, blue: 0.97))
    }

    private func categorySection(_ title: LocalizedStringKey, pages: [SettingsPage]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: compact ? 11 : 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, compact ? 20 : 22)
                .padding(.top, compact ? 12 : 16)
                .padding(.bottom, compact ? 4 : 6)
                .accessibilityAddTraits(.isHeader)
            ForEach(pages) { page in
                categoryRow(page)
            }
        }
    }

    private func categoryRow(_ page: SettingsPage) -> some View {
        let selected = selection == page
        return Button {
            guard !protectsEditorEdits else { return }
            selection = page
        } label: {
            HStack(spacing: compact ? 10 : 12) {
                Image(systemName: page.symbol)
                    .symbolVariant(.fill)
                    .font(.system(size: compact ? 13 : 17))
                    .foregroundStyle(.white)
                    .frame(width: metrics.iconSize, height: metrics.iconSize)
                    .background(
                        page.iconColor,
                        in: RoundedRectangle(cornerRadius: compact ? 6 : 8)
                    )
                    .accessibilityHidden(true)
                Text(page.title)
                    .font(.system(size: metrics.rowFontSize))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, compact ? 8 : 10)
            .frame(minHeight: metrics.rowHeight)
            .background(
                selected ? Color(red: 0, green: 0.38, blue: 0.82) : Color.clear,
                in: RoundedRectangle(cornerRadius: compact ? 8 : 12)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var detail: some View {
        if let selection {
            selectedPage(selection)
                .id(
                    "\(selection.rawValue)-\(settings.me.uid)-\(settings.chatStore.sessionRevision)"
                )
        } else {
            ContentUnavailableView("Select a setting", systemImage: "gearshape")
        }
    }

    @ViewBuilder
    private func selectedPage(_ page: SettingsPage) -> some View {
        switch page {
        case .language:
            LanguageSettingsView(store: settings.chatStore, onFinish: finishEditor)
        case .friendRequestPermission:
            FriendVerificationSettingsView(
                store: settings.chatStore, grouped: false, onFinish: finishEditor)
        case .readReceiptPrivacy:
            ReadReceiptPrivacySettingsView(
                store: settings.chatStore, grouped: false, onFinish: finishEditor)
        case .presencePrivacy:
            PresencePrivacySettingsView(
                store: settings.chatStore, grouped: false, onFinish: finishEditor)
        case .savedMessages, .stickerPacks:
            // These pages push real child destinations and retain their native navigation
            // controls (including sticker reordering); no additional title bar is layered on.
            NavigationStack {
                settings.page(page, grouped: true)
            }
        default:
            VStack(spacing: 0) {
                HStack {
                    Text(page.title)
                        .font(.system(size: compact ? 17 : 20, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 28)
                .frame(height: compact ? 56 : 64)
                settings.page(page, grouped: true)
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func finishEditor() {
        // Save stays on the selected page. Only an explicit editor exit clears selection.
        selection = nil
    }
}

private struct SettingsSplitMetrics {
    let compact: Bool

    var sidebarWidth: CGFloat { compact ? 268 : 300 }
    var closeSize: CGFloat { compact ? 28 : 36 }
    var rowHeight: CGFloat { compact ? 30 : 44 }
    var iconSize: CGFloat { compact ? 22 : 29 }
    var rowFontSize: CGFloat { compact ? 13 : 16 }
}
