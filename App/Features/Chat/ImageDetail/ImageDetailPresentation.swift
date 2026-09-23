import Combine
import SwiftUI

@MainActor
final class ImageDetailPresenter: ObservableObject {
    @Published private(set) var gallery: MessageImageGallery?

    func present(_ gallery: MessageImageGallery) {
        guard self.gallery == nil else { return }
        #if os(iOS)
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { self.gallery = gallery }
    }

    func dismiss() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { gallery = nil }
    }
}

private struct ImageDetailPresenterKey: EnvironmentKey {
    nonisolated static let defaultValue: ImageDetailPresenter? = nil
}

extension EnvironmentValues {
    var imageDetailPresenter: ImageDetailPresenter? {
        get { self[ImageDetailPresenterKey.self] }
        set { self[ImageDetailPresenterKey.self] = newValue }
    }
}

/// Installed around the authenticated scene, so desktop images cover the sidebar
/// and detail together and never survive an account switch.
struct ImageDetailPresentation: ViewModifier {
    @StateObject private var presenter = ImageDetailPresenter()
    @Environment(\.mediaContext) private var mediaContext

    func body(content: Content) -> some View {
        #if os(iOS)
            content
                .environment(\.imageDetailPresenter, presenter)
                .fullScreenCover(
                    item: Binding(
                        get: { presenter.gallery }, set: { if $0 == nil { presenter.dismiss() } })
                ) { gallery in
                    ImageDetailPlatformView(
                        gallery: gallery, mediaContext: mediaContext, onDismiss: presenter.dismiss
                    )
                    .ignoresSafeArea()
                    .presentationBackground(.clear)
                    .interactiveDismissDisabled()
                    .statusBarHidden()
                }
        #else
            content
                .environment(\.imageDetailPresenter, presenter)
                .allowsHitTesting(presenter.gallery == nil)
                .accessibilityHidden(presenter.gallery != nil)
                .overlay {
                    if let gallery = presenter.gallery {
                        ImageDetailPlatformView(
                            gallery: gallery, mediaContext: mediaContext,
                            onDismiss: presenter.dismiss
                        )
                        .id(gallery.id)
                        .ignoresSafeArea()
                    }
                }
        #endif
    }
}
