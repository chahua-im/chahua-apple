#if os(iOS)
import SwiftUI
import UIKit

/// Native cell frames are authoritative; the root is installed once per cell.
final class TimelineBubbleHostingController: UIHostingController<TimelineRowHostView> {
    lazy var rowGestures = MessageRowGestureCoordinator(view: view)

    override init(rootView: TimelineRowHostView) {
        super.init(rootView: rootView)
        safeAreaRegions = []
        sizingOptions = []
        view.backgroundColor = .clear
    }

    required init?(coder: NSCoder) { nil }
}

final class TimelineCollectionViewCell: UICollectionViewCell {
    let state = TimelineRowHostState()
    lazy var hosting = TimelineBubbleHostingController(rootView: TimelineRowHostView(state: state))

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

    override func prepareForReuse() {
        super.prepareForReuse()
        hosting.rowGestures.cancel()
        state.clear()
    }

    func attach(to parent: UIViewController) {
        guard hosting.parent !== parent else { return }
        detach()
        parent.addChild(hosting)
        hosting.didMove(toParent: parent)
    }

    func detach() {
        hosting.rowGestures.cancel()
        state.clear()
        guard hosting.parent != nil else { return }
        hosting.willMove(toParent: nil)
        hosting.removeFromParent()
    }
}
#endif
