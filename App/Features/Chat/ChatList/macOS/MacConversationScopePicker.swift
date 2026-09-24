#if os(macOS)
    import SwiftUI

    /// Desktop scopes use content-sized tabs that share leftover width, unlike iOS's picker.
    struct MacConversationScopePicker: View {
        @Binding var selection: ConversationListScope
        var badges: ConversationTabBadges

        var body: some View {
            GrowingScopeTabs {
                ForEach(ConversationListScope.allCases) { scope in
                    Button {
                        selection = scope
                    } label: {
                        VStack(spacing: 0) {
                            HStack(spacing: 4) {
                                Text(scope.localizedTitle)
                                    .font(.system(size: 14, weight: .medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                if badges[scope] > 0 {
                                    Text(badges[scope] > 999 ? "999+" : String(badges[scope]))
                                        .font(.caption2.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .frame(minHeight: 18)
                                        .background(Color.accentColor, in: Capsule())
                                        .accessibilityHidden(true)
                                }
                            }
                            .foregroundStyle(selection == scope ? .primary : .secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            Capsule()
                                .fill(selection == scope ? Color.accentColor : .clear)
                                .frame(height: 3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(scope.localizedTitle))
                    .accessibilityValue(
                        badges[scope] > 0
                            ? Text("\(badges[scope]) unread conversations") : Text("")
                    )
                    .accessibilityAddTraits(selection == scope ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)
            .background(alignment: .bottom) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
            }
        }
    }

    /// CSS flex-grow behavior: preserve each tab's intrinsic width, then share spare space.
    private struct GrowingScopeTabs: Layout {
        func sizeThatFits(
            proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
        ) -> CGSize {
            var width: CGFloat = 0
            var height: CGFloat = 0
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                width += size.width
                height = max(height, size.height)
            }
            if let proposedWidth = proposal.width, proposedWidth.isFinite {
                width = max(0, proposedWidth)
            }
            return CGSize(width: width, height: height)
        }

        func placeSubviews(
            in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
        ) {
            guard !subviews.isEmpty else { return }
            var intrinsicTotal: CGFloat = 0
            for subview in subviews {
                intrinsicTotal += subview.sizeThatFits(.unspecified).width
            }
            let growth = max(0, bounds.width - intrinsicTotal) / CGFloat(subviews.count)
            let shrink = intrinsicTotal > bounds.width ? bounds.width / intrinsicTotal : 1
            var x = bounds.minX
            for subview in subviews {
                let width = subview.sizeThatFits(.unspecified).width * shrink + growth
                subview.place(
                    at: CGPoint(x: x, y: bounds.minY),
                    proposal: ProposedViewSize(width: width, height: bounds.height))
                x += width
            }
        }
    }

    #if DEBUG
        #Preview("macOS scope tabs with badges") {
            MacConversationScopePickerPreview()
        }

        private struct MacConversationScopePickerPreview: View {
            private var badges: ConversationTabBadges {
                var counts = ConversationTabBadges()
                counts.groups = 2
                counts.dms = 3
                counts.threads = 1
                return counts
            }

            var body: some View {
                MacConversationScopePicker(selection: .constant(.messages), badges: badges)
                    .frame(width: 440)
                    .padding(24)
            }
        }
    #endif
#endif
