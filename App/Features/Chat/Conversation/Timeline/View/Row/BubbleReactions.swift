import ChahuaAPI
import SwiftUI

struct BubbleReactions: View {
    let reactions: [ReactionSummary]
    let isOutgoing: Bool
    let size: CGSize
    let itemFrames: [CGRect]
    var isPending = false
    var toggle: ((String) -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineItemLayout(size: size, frames: itemFrames) {
            ForEach(Array(reactions.sorted(by: TimelineRowPresentation.reactionOrder).enumerated()), id: \.element.emoji) { index, reaction in
                if let toggle {
                    MessageRowActionButton { toggle(reaction.emoji) } label: { pill(reaction).frame(width: itemFrames[index].width, height: itemFrames[index].height).clipped() }
                        .disabled(isPending)
                } else {
                    pill(reaction).frame(width: itemFrames[index].width, height: itemFrames[index].height).clipped()
                }
            }
        }
        .opacity(isPending ? 0.6 : 1)
    }

    private func pill(_ reaction: ReactionSummary) -> some View {
        let active = reaction.reactedByMe == true
        let colored = isOutgoing || active
        let reactors = Array((reaction.reactors ?? []).prefix(5))
        return HStack(spacing: 2) {
            Text(reaction.emoji).font(.system(size: 18.5)).padding(.leading, 6)
            if !reactors.isEmpty {
                HStack(spacing: -9) {
                    ForEach(Array(reactors.enumerated()), id: \.element.uid) { index, reactor in
                        AvatarView(url: reactor.avatarUrl.flatMap(URL.init(string:)), displayName: reactor.name ?? "User \(reactor.uid)", diameter: 23)
                        .overlay(Circle().strokeBorder(colored ? Color.white : ChahuaTheme.ChatBubble.incomingForeground(for: colorScheme), lineWidth: 1))
                        .zIndex(Double(5 - index))
                    }
                }
                .padding(.vertical, 1.5)
                if reaction.count > 5 {
                    Text("+\(reaction.count - 5)").font(.system(size: 11)).opacity(0.7).padding(.trailing, 4)
                }
            } else if reaction.count > 1 {
                Text("\(reaction.count)").font(.system(size: 12)).opacity(0.7).padding(.trailing, 6)
            }
        }
        .padding(.trailing, 1.5)
        .frame(minHeight: 26)
        .foregroundStyle(colored ? .white : ChahuaTheme.ChatBubble.incomingForeground(for: colorScheme))
        .background(background(active: active), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(reaction.emoji), \(reaction.count) reactions"))
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func background(active: Bool) -> Color {
        if isOutgoing && active { return Color(.sRGB, red: 38 / 255, green: 107 / 255, blue: 180 / 255, opacity: 1) }
        if isOutgoing || active { return Color(.sRGB, red: 64 / 255, green: 135 / 255, blue: 210 / 255, opacity: 1) }
        return colorScheme == .dark
            ? Color(.sRGB, red: 30 / 255, green: 32 / 255, blue: 35 / 255, opacity: 1)
            : Color(.sRGB, red: 215 / 255, green: 216 / 255, blue: 218 / 255, opacity: 1)
    }
}

