import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// SwiftUI Text cannot exclude the thumbnail from only intersecting lines. Keep the
/// card, Link, and image in SwiftUI; use the same inert TextKit drawing and exact-width
/// measurement as timeline previews rather than a second wrapping implementation.
struct DraftLinkPreviewFlow: View {
    let title: String
    let description: String?
    let domain: String
    let thumbnailSource: String?
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        DraftLinkPreviewTextBridge(
            title: title, description: description, domain: domain,
            hasThumbnail: thumbnailSource != nil, rightToLeft: layoutDirection == .rightToLeft
        )
        .overlay {
            if let thumbnailSource {
                GeometryReader { geometry in
                    let frame = LinkPreviewFlowLayout.thumbnailFrame(
                        width: geometry.size.width, thumbnailSize: 60, gap: 10,
                        titleFont: DraftLinkPreviewTextBridge.titleFont,
                        rightToLeft: layoutDirection == .rightToLeft)
                    DraftLinkPreviewThumbnail(source: thumbnailSource)
                        .frame(width: frame.width, height: frame.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .position(x: frame.midX, y: frame.midY)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, description, domain].compactMap { $0 }.joined(separator: ", "))
    }
}

private struct DraftLinkPreviewTextBridge {
    let title: String
    let description: String?
    let domain: String
    let hasThumbnail: Bool
    let rightToLeft: Bool

    @MainActor
    static var titleFont: BubbleNativeFont {
        #if os(macOS)
            NSFont.systemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
                weight: .semibold)
        #else
            UIFont.systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize,
                weight: .semibold)
        #endif
    }

    @MainActor
    func layout(width: CGFloat) -> LinkPreviewFlowLayout {
        #if os(macOS)
            let caption = NSFont.preferredFont(forTextStyle: .caption1)
        #else
            let caption = UIFont.preferredFont(forTextStyle: .caption1)
        #endif
        return LinkPreviewFlowLayout(
            title: title, description: description, domain: domain, width: max(1, width),
            titleFont: Self.titleFont, descriptionFont: caption, domainFont: caption,
            thumbnailSize: hasThumbnail ? 60 : 0, gap: 10, rightToLeft: rightToLeft,
            titleLineLimit: 2, descriptionLineLimit: 3, sectionSpacing: 4)
    }

    @MainActor
    func configure(_ view: DraftLinkPreviewDrawingView) {
        #if os(macOS)
            view.foregroundColor = .labelColor
            view.secondaryColor = .secondaryLabelColor
        #else
            view.foregroundColor = .label
            view.secondaryColor = .secondaryLabel
        #endif
        view.layoutProvider = { layout(width: $0) }
        view.flowLayout = layout(width: view.bounds.width)
    }

    @MainActor
    func measuredSize(_ proposal: ProposedViewSize, view: DraftLinkPreviewDrawingView) -> CGSize {
        let width = proposal.width ?? 300
        let flow = layout(width: width)
        view.flowLayout = flow
        return CGSize(width: width, height: flow.height)
    }
}

#if os(macOS)
    extension DraftLinkPreviewTextBridge: NSViewRepresentable {
        func makeNSView(context: Context) -> DraftLinkPreviewDrawingView {
            let view = DraftLinkPreviewDrawingView(frame: .zero)
            configure(view)
            return view
        }

        func updateNSView(_ view: DraftLinkPreviewDrawingView, context: Context) { configure(view) }

        func sizeThatFits(
            _ proposal: ProposedViewSize, nsView: DraftLinkPreviewDrawingView, context: Context
        ) -> CGSize? {
            measuredSize(proposal, view: nsView)
        }
    }
#else
    extension DraftLinkPreviewTextBridge: UIViewRepresentable {
        func makeUIView(context: Context) -> DraftLinkPreviewDrawingView {
            let view = DraftLinkPreviewDrawingView(frame: .zero)
            configure(view)
            return view
        }

        func updateUIView(_ view: DraftLinkPreviewDrawingView, context: Context) { configure(view) }

        func sizeThatFits(
            _ proposal: ProposedViewSize, uiView: DraftLinkPreviewDrawingView, context: Context
        ) -> CGSize? {
            measuredSize(proposal, view: uiView)
        }
    }
#endif

@MainActor
private final class DraftLinkPreviewDrawingView: LinkPreviewFlowTextView {
    var layoutProvider: ((CGFloat) -> LinkPreviewFlowLayout)?

    private func refreshWidth() {
        guard bounds.width > 0, flowLayout?.width != bounds.width else { return }
        flowLayout = layoutProvider?(bounds.width)
    }

    #if os(macOS)
        override func layout() {
            super.layout()
            refreshWidth()
        }
    #else
        override func layoutSubviews() {
            super.layoutSubviews()
            refreshWidth()
        }
    #endif
}
