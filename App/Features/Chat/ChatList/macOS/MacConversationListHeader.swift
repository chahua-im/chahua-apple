#if os(macOS)
    import SwiftUI

    struct MacConversationListHeader<Account: View, Actions: View>: View {
        var onBack: (() -> Void)?
        var isUpdating: Bool
        @ViewBuilder var account: () -> Account
        @ViewBuilder var actions: () -> Actions
        @FocusState private var isHeaderFocused: Bool

        var body: some View {
            // Content extends behind the transparent title bar; ordinary padding
            // reserves the native traffic lights without changing window dragging.
            headerActions
                .padding(.leading, 100)
                .padding(.trailing, 16)
                .frame(height: MacConversationWindowChrome.titleBandHeight)
                .padding(.bottom, 8)
                // Keep automatic window-entry focus off Search. Explicit search
                // clicks/shortcuts and the conversation editor retain their own focus.
                .focusable()
                .focusEffectDisabled()
                .focused($isHeaderFocused)
                .defaultFocus($isHeaderFocused, true)
        }

        private var headerActions: some View {
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
