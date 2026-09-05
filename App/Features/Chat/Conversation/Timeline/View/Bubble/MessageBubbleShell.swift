import ChahuaAPI
import SwiftUI

struct TimelineMessageRowLayout<Content: View>: View {
    let row: TimelineMessageRow
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .bottom, spacing: ChahuaTheme.Spacing.small) {
            if !row.isOutgoing {
                avatar
            }

            content()

            if row.isOutgoing {
                avatar
            }
        }
        .padding(.horizontal, ChahuaTheme.Spacing.medium)
        .padding(.top, row.groupPosition == .first || row.groupPosition == .single ? ChahuaTheme.Spacing.small : 2)
    }

    @ViewBuilder
    private var avatar: some View {
        if row.groupPosition == .single || row.groupPosition == .last {
            AvatarView(
                url: row.entry.remoteMessage?.sender.avatarUrl.flatMap(URL.init(string:)),
                displayName: senderDisplayName,
                diameter: 36
            )
        } else {
            Color.clear.frame(width: 36, height: 36)
        }
    }

    private var senderDisplayName: String {
        if let name = row.entry.remoteMessage?.sender.name, !name.isEmpty {
            name
        } else {
            "User \(row.entry.senderID)"
        }
    }
}

struct MessageBubbleShell<Content: View>: View {
    let row: TimelineMessageRow
    @ViewBuilder let content: () -> Content

    var body: some View {
        TimelineMessageRowLayout(row: row) {
            HStack {
                if row.isOutgoing { Spacer(minLength: 48) }
                content()
                    .padding(.horizontal, ChahuaTheme.Spacing.medium)
                    .padding(.vertical, ChahuaTheme.Spacing.small)
                    .foregroundStyle(row.isOutgoing ? .white : ChahuaTheme.primaryText)
                    .background(row.isOutgoing ? ChahuaTheme.accent : ChahuaTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: ChahuaTheme.Radius.large, style: .continuous))
                if !row.isOutgoing { Spacer(minLength: 48) }
            }
        }
    }
}
