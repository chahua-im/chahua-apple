#if os(macOS)
    import SwiftUI

    struct MacConversationListHeader<Account: View, Actions: View>: View {
        var onBack: (() -> Void)?
        var isUpdating: Bool
        @ViewBuilder var account: () -> Account
        @ViewBuilder var actions: () -> Actions
        @State private var sidebarWidth: CGFloat = 300

        var body: some View {
            // The docked title row is 52pt, followed by an 8pt search margin.
            // AppKit still owns the toolbar controls centered at native y26.
            Color.clear.frame(height: 60)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    sidebarWidth = $0
                }
                .toolbar {
                    if #available(macOS 26, *) {
                        accountToolbar.sharedBackgroundVisibility(.hidden)
                    } else {
                        accountToolbar
                    }
                }
        }

        private var accountToolbar: some ToolbarContent {
            ToolbarItem(id: "chahua-sidebar-account-actions", placement: .navigation) {
                toolbarActions
                    // Align the account controls with AppKit's native y26 center.
                    .frame(
                        width: max(100, sidebarWidth - 108),
                        height: MacConversationWindowChrome.titleBandHeight)
            }
        }

        private var toolbarActions: some View {
            HStack(spacing: 9) {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.backward")
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Back to chats")
                }
                Spacer(minLength: 0)
                if isUpdating {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Updating…")
                }
                account()
                    .labelStyle(.iconOnly)
                    .frame(width: 32, height: 32)
                    .accessibilityLabel("Settings")
                if onBack == nil {
                    actions()
                        .labelStyle(.iconOnly)
                        .font(.system(size: 18))
                        .frame(width: 32, height: 32)
                }
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityElement(children: .contain)
        }
    }

#endif
