#if os(iOS)
import ChahuaAPI
import SwiftUI

struct MessageSenderHeader: View {
    let row: TimelineMessageRow
    let title: TitleContent
    let fontSize: CGFloat
    let size: CGSize
    let itemFrames: [CGRect]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineItemLayout(size: size, frames: itemFrames) {
            Text(verbatim: title.name)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(row.isOutgoing ? .white : bubbleColorForUser(uid: row.entry.senderID, dark: colorScheme == .dark))
                .opacity(row.isOutgoing ? 1 : 0.85)
                .lineLimit(1)
                .frame(width: itemFrames.first?.width ?? 0, height: size.height, alignment: .leading)
                .clipped()
            Group {
                if let name = title.groupName {
                    Text(verbatim: name)
                        .font(.system(size: fontSize))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .background(groupColor, in: RoundedRectangle(cornerRadius: 2))
                        .opacity(0.85)
                } else { Color.clear }
            }
            .frame(width: itemFrames.count > 1 ? itemFrames[1].width : 0, height: size.height)
            .clipped()
            Group {
                if let glyph = title.genderGlyph {
                    Text(verbatim: glyph).font(.system(size: fontSize))
                        .foregroundStyle(bubbleColor(hex: glyph == "♂" ? "3cb4f0" : "ff8080") ?? .primary)
                } else { Color.clear }
            }
            .frame(width: itemFrames.count > 2 ? itemFrames[2].width : 0, height: size.height)
            .clipped()
        }
    }

    private var groupColor: Color {
        guard let group = row.entry.remoteMessage?.sender.userGroup else { return Color.gray.opacity(0.44) }
        let dark = group.chatGroupColorDark.flatMap { $0.isEmpty ? nil : $0 }
        let hex = colorScheme == .dark ? dark ?? group.chatGroupColor : group.chatGroupColor
        return hex.flatMap(bubbleColor(hex:)) ?? Color.gray.opacity(0.44)
    }
}


#endif
