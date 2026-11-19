import SwiftUI

struct TimelineSelectionRangeOverlay: ViewModifier {
    let range: TimelineSelectionRange
    let actions: TimelineBubbleActions

    func body(content: Content) -> some View {
        content.overlay {
            if actions.isSelectingMessages, !actions.isSelectionBusy,
                let extend = actions.extendMessageSelection
            {
                TimelineSelectionRangeButton(range: range, extend: extend)
            }
        }
    }
}

/// A sibling of the native timeline, not a hosted view inside it. Only the chip
/// observes scroll-driven offers; the timeline and composer do not rebuild.
private struct TimelineSelectionRangeButton: View {
    @ObservedObject var range: TimelineSelectionRange
    let extend: (TimelineSelectionRange.Direction) -> Void
    @Environment(\.chatHeaderInset) private var headerInset
    @Environment(\.chatComposerInset) private var composerInset

    var body: some View {
        if let offer = range.offer {
            let older = offer.direction == .older
            let shape = Capsule(style: .circular)
            Button {
                extend(offer.direction)
            } label: {
                RoundChipLayout(isCircular: false) {
                    HStack(spacing: 6) {
                        Image(systemName: older ? "arrow.down" : "arrow.up")
                            .accessibilityHidden(true)
                        if offer.exceedsLimit {
                            Text("Can select \(offer.remaining) more")
                        } else {
                            Text("Select to here +\(offer.count)")
                        }
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(offer.exceedsLimit ? .secondary : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(minHeight: 44)
                }
                .modifier(ChatGlassSurface(shape: shape, isInteractive: !offer.exceedsLimit))
            }
            .buttonStyle(.plain)
            .disabled(offer.exceedsLimit)
            .padding(.leading, 8)
            .padding(older ? .top : .bottom, (older ? headerInset : composerInset) + 8)
            .frame(
                maxWidth: .infinity, maxHeight: .infinity,
                alignment: older ? .topLeading : .bottomLeading)
        }
    }
}
