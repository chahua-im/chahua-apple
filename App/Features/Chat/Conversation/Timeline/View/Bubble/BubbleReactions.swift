import ChahuaAPI
import SwiftUI

struct BubbleReactions: View {
    let reactions: [ReactionSummary]
    let isOutgoing: Bool
    let isMeasuring: Bool
    var isPending = false
    var toggle: ((String) -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ReactionFlowLayout(isOutgoing: isOutgoing) {
            ForEach(reactions.sorted {
                $0.count == $1.count ? $0.emoji < $1.emoji : $0.count > $1.count
            }, id: \.emoji) { reaction in
                if let toggle, !isMeasuring {
                    Button { toggle(reaction.emoji) } label: { pill(reaction) }
                        .buttonStyle(.plain)
                        .disabled(isPending)
                } else {
                    pill(reaction)
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
                        Group {
                            if isMeasuring {
                                Color.clear.frame(width: 23, height: 23)
                            } else {
                                AvatarView(url: reactor.avatarUrl.flatMap(URL.init(string:)), displayName: reactor.name ?? "User \(reactor.uid)", diameter: 23)
                            }
                        }
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

/// Reactions wrap independently of the content kind and align to its sending side.
private struct ReactionFlowLayout: Layout {
    let isOutgoing: Bool
    private let gap: CGFloat = 4

    private func rows(width: CGFloat, subviews: Subviews) -> [[CGSize]] {
        var rows: [[CGSize]] = [[]]
        var used: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.init(width: width, height: nil))
            if used > 0 && used + gap + size.width > width {
                rows.append([])
                used = 0
            }
            rows[rows.count - 1].append(size)
            used += (used == 0 ? 0 : gap) + size.width
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width + gap } - gap
        let rows = rows(width: max(0, width), subviews: subviews)
        return CGSize(width: max(0, width), height: rows.reduce(CGFloat.zero) { $0 + ($1.map(\.height).max() ?? 0) } + CGFloat(max(0, rows.count - 1)) * gap)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var index = 0
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            let width = row.reduce(CGFloat.zero) { $0 + $1.width } + CGFloat(max(0, row.count - 1)) * gap
            var x = isOutgoing ? bounds.maxX - width : bounds.minX
            for size in row {
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .init(size))
                x += size.width + gap
                index += 1
            }
            y += (row.map(\.height).max() ?? 0) + gap
        }
    }
}
