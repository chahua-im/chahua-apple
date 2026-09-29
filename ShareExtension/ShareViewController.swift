import SwiftUI
import UIKit

/// UIKit is required because a share extension receives its `NSExtensionContext` through a
/// view controller. SwiftUI supplies the sheet itself; the transparent host lets it draw the
/// dimmed backdrop and bottom-aligned rounded cards without UIKit duplicating that interface.
final class ShareViewController: UIViewController {
    private lazy var model = ShareExtensionModel(
        extensionItems: extensionContext?.inputItems as? [NSExtensionItem] ?? [])
    private var host: UIHostingController<ShareExtensionRootView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        modalPresentationStyle = .overFullScreen
        view.backgroundColor = .clear
        view.isOpaque = false
        view.accessibilityViewIsModal = true

        let host = UIHostingController(
            rootView: ShareExtensionRootView(
                model: model,
                onCancel: { [weak self] in self?.cancelShare() },
                onComplete: { [weak self] in self?.completeShare() }
            )
        )
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        host.view.accessibilityViewIsModal = true

        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        self.host = host
    }

    private func cancelShare() {
        model.cancel()
        extensionContext?.cancelRequest(withError: ShareExtensionCancellationError())
    }

    private func completeShare() {
        model.completeAfterConfirmation()
        extensionContext?.completeRequest(returningItems: nil)
    }
}

private struct ShareExtensionCancellationError: LocalizedError {
    var errorDescription: String? { "Sharing was cancelled." }
}
