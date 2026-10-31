import SwiftUI

struct ConversationListHeader<Account: View, Actions: View>: View {
    @Environment(\.isWideChatLayout) private var isWideChatLayout
    @Binding var selection: ConversationListScope
    var badges = ConversationTabBadges()
    var badgeColor = ConversationListPreferences.defaultUnreadBadgeColor
    var onBack: (() -> Void)? = nil
    var isUpdating = false
    @ViewBuilder let account: () -> Account
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        Group {
            if isWideChatLayout {
                #if os(macOS)
                    MacConversationListHeader(
                        onBack: onBack, isUpdating: isUpdating, account: account, actions: actions)
                #else
                    wideHeader
                #endif
            } else {
                compactHeader
            }
        }
    }

    private var wideHeader: some View {
        HStack(spacing: 8) {
            leadingControl
                .frame(width: 44, height: 44)
            HStack(spacing: 7) {
                if isUpdating {
                    ProgressView().controlSize(.small)
                    Text("Updating…")
                } else {
                    Text(
                        onBack == nil
                            ? LocalizedStringKey("Chats") : LocalizedStringKey("Archived"))
                }
            }
            .font(
                ConversationListMetrics.usesDesktopDensity(isWide: isWideChatLayout)
                    ? .system(size: 14, weight: .semibold) : .title3.bold()
            )
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if onBack == nil {
                actions()
                    .labelStyle(.iconOnly)
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityElement(children: .contain)
    }

    private var compactHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leadingControl
                    .frame(width: 44, height: 44)
                    .modifier(ChatGlassSurface(cornerRadius: 22, isInteractive: true))
                    .frame(width: 52, height: 52)
                Spacer(minLength: 0)
                if onBack == nil {
                    actions()
                        .labelStyle(.iconOnly)
                        .font(.system(size: 22, weight: .regular))
                        .frame(width: 44, height: 44)
                        .modifier(ChatGlassSurface(cornerRadius: 22, isInteractive: true))
                        .frame(width: 52, height: 52)
                } else {
                    Color.clear
                        .frame(width: 52, height: 52)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                HStack(spacing: 7) {
                    if isUpdating {
                        ProgressView().controlSize(.small)
                        Text("Updating…")
                    } else {
                        Text(
                            onBack == nil
                                ? LocalizedStringKey("Chats") : LocalizedStringKey("Archived"))
                    }
                }
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 60)
                .accessibilityAddTraits(.isHeader)
                .allowsHitTesting(false)
            }
            .padding(.horizontal, 8)
            ConversationScopePicker(
                selection: $selection, badges: badges, badgeColor: badgeColor)
            Divider()
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .background(.background)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var leadingControl: some View {
        if let onBack {
            Button(action: onBack) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back to chats")
        } else {
            account()
                .labelStyle(.iconOnly)
                .accessibilityLabel("Settings")
        }
    }
}

struct ConversationListRefreshingKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}
