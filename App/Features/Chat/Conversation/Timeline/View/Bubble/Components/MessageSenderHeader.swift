import ChahuaAPI
import SwiftUI

struct MessageSenderHeader: View {
    let row: TimelineMessageRow
    let currentUserProfile: MeResponse?
    let usesOutgoingForeground: Bool
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption) private var fontSize: CGFloat = 12

    private var message: MessageResponse? { row.entry.remoteMessage }
    private var senderName: String {
        message?.sender.name.flatMap { $0.isEmpty ? nil : $0 }
            ?? (row.isOutgoing ? currentUserProfile?.username : nil)
            ?? "User \(row.entry.senderID)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(senderName)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(usesOutgoingForeground ? .white : bubbleColorForUser(uid: row.entry.senderID, dark: colorScheme == .dark))
                .opacity(0.85)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let group = message?.sender.userGroup, let name = group.name, !name.isEmpty {
                Text(name)
                    .font(.system(size: fontSize * 10 / 12))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .background(groupColor(group), in: RoundedRectangle(cornerRadius: 2))
                    .opacity(0.85)
            }
            if let gender = message?.sender.gender, gender == 1 || gender == 2 {
                Text(gender == 1 ? "♂" : "♀")
                    .font(.system(size: fontSize))
                    .foregroundStyle(bubbleColor(hex: gender == 1 ? "3cb4f0" : "ff8080") ?? .primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func groupColor(_ group: UserGroupTagInfo) -> Color {
        let darkOverride = group.chatGroupColorDark.flatMap { $0.isEmpty ? nil : $0 }
        let hex = colorScheme == .dark ? (darkOverride ?? group.chatGroupColor) : group.chatGroupColor
        return hex.flatMap(bubbleColor(hex:)) ?? Color.gray.opacity(0.44)
    }
}
