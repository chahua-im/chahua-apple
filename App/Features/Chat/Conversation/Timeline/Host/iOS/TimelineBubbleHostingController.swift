#if os(iOS)
import SwiftUI
import UIKit

/// A row is not a screen: the collection view owns safe-area insets. Use the
/// public hosting control for both visible and measuring roots so scrolling
/// under a status bar cannot change a bubble's measured height.
final class TimelineBubbleHostingController: UIHostingController<TimelineBubbleView> {
    override init(rootView: TimelineBubbleView) {
        super.init(rootView: rootView)
        safeAreaRegions = []
        sizingOptions = .intrinsicContentSize
        view.backgroundColor = .clear
    }

    required init?(coder: NSCoder) { nil }
}

final class TimelineCollectionViewCell: UICollectionViewCell {
    let hosting = TimelineBubbleHostingController(
        rootView: TimelineBubbleView(row: .dateSeparator(.init(day: .now, ordinalDay: 0)), context: .init())
    )

    override init(frame: CGRect) {
        super.init(frame: frame)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func attach(to parent: UIViewController) {
        guard hosting.parent !== parent else { return }
        detach()
        parent.addChild(hosting)
        hosting.didMove(toParent: parent)
    }

    func detach() {
        guard hosting.parent != nil else { return }
        hosting.willMove(toParent: nil)
        hosting.removeFromParent()
    }
}
#endif
