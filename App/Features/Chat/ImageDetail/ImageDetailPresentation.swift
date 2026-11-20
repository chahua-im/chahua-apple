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

    func body(content: Content) -> some View {
        #if os(iOS)
            content
                .environment(\.imageDetailPresenter, presenter)
                .voicePlaybackCovered(presenter.gallery != nil)
                .fullScreenCover(
                    item: Binding(
                        get: { presenter.gallery }, set: { if $0 == nil { presenter.dismiss() } })
                ) { gallery in
                    ImageDetailVoiceSurface(gallery: gallery, onDismiss: presenter.dismiss)
                        .presentationBackground(.clear)
                        .interactiveDismissDisabled()
                        .statusBarHidden()
                }
        #else
            content
                .environment(\.imageDetailPresenter, presenter)
                .voicePlaybackCovered(presenter.gallery != nil)
                .allowsHitTesting(presenter.gallery == nil)
                .accessibilityHidden(presenter.gallery != nil)
                .overlay {
                    if let gallery = presenter.gallery {
                        ImageDetailVoiceSurface(gallery: gallery, onDismiss: presenter.dismiss)
                            .id(gallery.id)
                            .ignoresSafeArea()
                    }
                }
        #endif
    }
}

private struct ImageDetailVoiceSurface: View {
    let gallery: MessageImageGallery
    let onDismiss: () -> Void
    @Environment(\.mediaContext) private var mediaContext
    @Environment(\.voicePlaybackHeaderRoute) private var route
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var session = VoicePlaybackSession.shared
    @State private var headerBottom: CGFloat = 0
    @State private var barHeight: CGFloat = 0

    var body: some View {
        let controller = route != nil ? session.controller : nil
        let showsPlayback = controller != nil && headerBottom > 0
        ImageDetailPlatformView(
            gallery: gallery, mediaContext: mediaContext, onDismiss: onDismiss,
            playbackClearance: showsPlayback
                ? max(barHeight, VoicePlaybackCapsule.nominalHeight) + 8 : 0,
            onHeaderLayout: { headerBottom = $0 }
        )
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            Group {
                if showsPlayback, let controller {
                    VoicePlaybackBar(controller: controller)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                            barHeight = $0
                        }
                        .transition(VoicePlaybackMotion.transition)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, headerBottom + 8)
            .animation(
                VoicePlaybackMotion.animation(showing: showsPlayback, reduceMotion: reduceMotion),
                value: showsPlayback)
        }
        .voicePlaybackCover(onOpen: onDismiss)
    }
}
