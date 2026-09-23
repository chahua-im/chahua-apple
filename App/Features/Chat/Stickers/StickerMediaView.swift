import ChahuaAPI
import Kingfisher
import SwiftUI
import WebKit

#if os(iOS)
    import UIKit
    typealias StickerNativeView = UIView
    typealias StickerNativeImage = UIImage
#else
    import AppKit
    typealias StickerNativeView = NSView
    typealias StickerNativeImage = NSImage
#endif

struct StickerMediaView: View {
    let media: MessageStickerMediaResponse
    let emoji: String
    @Environment(\.mediaContext) private var mediaContext
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false

    var body: some View {
        StickerMediaRepresentable(
            media: media, emoji: emoji, mediaContext: mediaContext,
            displayScale: displayScale, visible: visible && scenePhase == .active
        )
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}

#if os(iOS)
    private struct StickerMediaRepresentable: UIViewRepresentable {
        let media: MessageStickerMediaResponse
        let emoji: String
        let mediaContext: AppMediaContext?
        let displayScale: CGFloat
        let visible: Bool

        func makeUIView(context: Context) -> StickerMediaSurfaceView {
            StickerMediaSurfaceView(frame: .zero)
        }
        func updateUIView(_ view: StickerMediaSurfaceView, context: Context) {
            view.configure(
                media: media, emoji: emoji, displayScale: displayScale, mediaContext: mediaContext)
            view.setVisible(visible)
        }
        static func dismantleUIView(_ view: StickerMediaSurfaceView, coordinator: ()) {
            view.clear()
        }
    }
#else
    private struct StickerMediaRepresentable: NSViewRepresentable {
        let media: MessageStickerMediaResponse
        let emoji: String
        let mediaContext: AppMediaContext?
        let displayScale: CGFloat
        let visible: Bool

        func makeNSView(context: Context) -> StickerMediaSurfaceView {
            StickerMediaSurfaceView(frame: .zero)
        }
        func updateNSView(_ view: StickerMediaSurfaceView, context: Context) {
            view.configure(
                media: media, emoji: emoji, displayScale: displayScale, mediaContext: mediaContext)
            view.setVisible(visible)
        }
        static func dismantleNSView(_ view: StickerMediaSurfaceView, coordinator: ()) {
            view.clear()
        }
    }
#endif

/// Shared native pixels keep measured timeline rows out of SwiftUI hosting while
/// giving picker/sheet previews the same account cache, animation and lifecycle.
@MainActor
final class StickerMediaSurfaceView: StickerNativeView {
    private let imageView = TimelineImageView(frame: .zero)
    #if os(iOS)
        private let statusLabel = UILabel(frame: .zero)
        private let progress = UIActivityIndicatorView(style: .medium)
        private weak var observedScrollView: UIScrollView?
        private var scrollObservation: NSKeyValueObservation?
    #else
        private let statusLabel = NSTextField(wrappingLabelWithString: "")
        private let progress = NSProgressIndicator(frame: .zero)
        private weak var observedClipView: NSClipView?
        override var isFlipped: Bool { true }
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
    #endif
    private var video: StickerVideoPlayback?
    private var media: MessageStickerMediaResponse?
    private var mediaContext: AppMediaContext?
    private var emoji = ""
    private var displayScale: CGFloat = 1
    private var imagePixels = CGSize.zero
    private var requestedVisible = false
    private var isVideo = false
    private var failure: String?
    private var videoLoading = false
    private var hasVideoPoster = false
    var onError: ((String?) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if os(iOS)
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            accessibilityTraits = .image
            clipsToBounds = true
            statusLabel.font = .preferredFont(forTextStyle: .caption2)
            statusLabel.textColor = .secondaryLabel
            statusLabel.numberOfLines = 3
            statusLabel.isAccessibilityElement = false
            statusLabel.textAlignment = .center
            progress.hidesWhenStopped = true
            for name in [
                UIApplication.didBecomeActiveNotification,
                UIApplication.willResignActiveNotification,
                UIScene.didActivateNotification, UIScene.willDeactivateNotification,
            ] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(visibilityChanged), name: name, object: nil)
            }
        #else
            wantsLayer = true
            layer?.masksToBounds = true
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
            statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.maximumNumberOfLines = 3
            statusLabel.setAccessibilityElement(false)
            statusLabel.alignment = .center
            progress.style = .spinning
            progress.controlSize = .small
            progress.isDisplayedWhenStopped = false
            for name in [
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                NSWindow.didChangeOcclusionStateNotification,
                NSApplication.didBecomeActiveNotification,
                NSApplication.didResignActiveNotification,
            ] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(visibilityChanged), name: name, object: nil)
            }
        #endif
        addSubview(imageView)
        addSubview(statusLabel)
        addSubview(progress)
        statusLabel.isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
        MainActor.assumeIsolated { video?.stop() }
    }

    func configure(
        media: MessageStickerMediaResponse, emoji: String, displayScale: CGFloat,
        mediaContext: AppMediaContext?
    ) {
        let changed = self.media != media || self.mediaContext !== mediaContext
        if changed {
            imageView.clear()
            video?.stop()
            video?.view.removeFromSuperview()
            video = nil
            imagePixels = .zero
            failure = nil
            videoLoading = false
            hasVideoPoster = false
            #if os(macOS)
                toolTip = nil
            #endif
            setStatus(nil)
            onError?(nil)
        }
        self.media = media
        self.emoji = emoji
        self.displayScale = displayScale
        self.mediaContext = mediaContext
        let type = media.contentType.lowercased()
        isVideo =
            type.hasPrefix("video/") || URL(string: media.url)?.pathExtension.lowercased() == "webm"
        imageView.isHidden = failure != nil || (isVideo && (!hasVideoPoster || !videoLoading))
        if changed {
            guard let url = URL(string: media.url),
                ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
            else {
                showFailure(String(localized: "Sticker media URL is invalid."))
                return
            }
            if isVideo {
                let cache = mediaContext?.cache ?? .default
                if let poster = cache.retrieveImageInMemoryCache(forKey: Self.posterKey(url)) {
                    installVideoPoster(poster)
                }
                let playback = StickerVideoPlayback(
                    url: url, contentType: type,
                    dataStore: mediaContext?.stickerVideoDataStore ?? .nonPersistent())
                playback.onStatus = { [weak self] error, loading in
                    guard let self, self.failure == nil else { return }
                    self.videoLoading = loading
                    if let error {
                        self.showFailure(error)
                    } else {
                        if !loading { self.imageView.isHidden = true }
                        self.setStatus(nil)
                        self.refreshVisibility()
                        self.updateAccessibility()
                    }
                }
                if !hasVideoPoster {
                    playback.onPoster = { image in
                        cache.store(image, forKey: Self.posterKey(url), toDisk: false)
                    }
                }
                video = playback
                addSubview(playback.view)
                // Keep status/error text above the otherwise noninteractive video.
                statusLabel.removeFromSuperview()
                addSubview(statusLabel)
                progress.removeFromSuperview()
                addSubview(progress)
                videoLoading = true
            } else if !type.hasPrefix("image/") {
                showFailure(
                    String(localized: "Unsupported sticker media type: \(media.contentType)"))
                return
            }
        }
        layoutMedia()
        refreshVisibility()
        updateAccessibility()
    }

    func setVisible(_ visible: Bool) {
        requestedVisible = visible
        refreshVisibility()
    }

    func clear() {
        requestedVisible = false
        imageView.clear()
        video?.stop()
        video?.view.removeFromSuperview()
        video = nil
        media = nil
        mediaContext = nil
        failure = nil
        videoLoading = false
        hasVideoPoster = false
        #if os(macOS)
            toolTip = nil
        #endif
        imagePixels = .zero
        setStatus(nil)
        updateProgress(visible: false)
        onError = nil
    }

    #if os(iOS)
        override func layoutSubviews() {
            super.layoutSubviews()
            layoutMedia()
            refreshVisibility()
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            observeScrolling()
            refreshVisibility()
        }
        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            observeScrolling()
            refreshVisibility()
        }
        override var isHidden: Bool { didSet { refreshVisibility() } }
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    #else
        override func layout() {
            super.layout()
            layoutMedia()
            refreshVisibility()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeScrolling()
            refreshVisibility()
        }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            observeScrolling()
            refreshVisibility()
        }
        override func viewDidHide() {
            super.viewDidHide()
            refreshVisibility()
        }
        override func viewDidUnhide() {
            super.viewDidUnhide()
            refreshVisibility()
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif

    // Lazy SwiftUI cells can appear before entering the viewport. Scrolling moves
    // their ancestors, not their bounds, so layout callbacks alone cannot resume media.
    private func observeScrolling() {
        #if os(iOS)
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            let scroll = window == nil ? nil : ancestor as? UIScrollView
            guard observedScrollView !== scroll else { return }
            scrollObservation = nil
            observedScrollView = scroll
            scrollObservation = scroll?.observe(\.contentOffset) { [weak self] _, _ in
                // UIKit scroll mutations and their KVO delivery occur on the main thread.
                MainActor.assumeIsolated { self?.refreshVisibility() }
            }
        #else
            let clip = window == nil ? nil : enclosingScrollView?.contentView
            guard observedClipView !== clip else { return }
            if let observedClipView {
                NotificationCenter.default.removeObserver(
                    self, name: NSView.boundsDidChangeNotification, object: observedClipView)
            }
            observedClipView = clip
            if let clip {
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self, selector: #selector(scrolled),
                    name: NSView.boundsDidChangeNotification, object: clip)
            }
        #endif
    }

    @objc private func scrolled() { refreshVisibility() }

    @objc private func visibilityChanged(_ notification: Notification) {
        #if os(iOS)
            if let scene = notification.object as? UIScene, scene !== window?.windowScene { return }
            if notification.name == UIApplication.willResignActiveNotification
                || notification.name == UIScene.willDeactivateNotification
            {
                imageView.setVisible(false)
                video?.setVisible(false)
                return
            }
        #endif
        refreshVisibility()
    }

    private func refreshVisibility() {
        #if os(iOS)
            let inViewport =
                observedScrollView.map { convert(bounds, to: $0).intersects($0.bounds) } ?? true
            let visible = requestedVisible && timelineMediaIsVisible && inViewport
        #else
            let visible =
                requestedVisible && window?.isVisible == true && window?.isMiniaturized == false
                && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
                && !visibleRect.isEmpty
                && NSApp.isActive
        #endif
        imageView.setVisible(visible && !isVideo && failure == nil)
        video?.setVisible(visible && failure == nil)
        updateProgress(visible: visible)
    }

    private func layoutMedia() {
        imageView.frame = bounds
        video?.view.frame = bounds
        #if os(iOS)
            progress.center = CGPoint(x: bounds.midX, y: bounds.midY)
        #else
            progress.frame = CGRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16)
        #endif
        let height = min(bounds.height, 56)
        statusLabel.frame = CGRect(
            x: 4, y: (bounds.height - height) / 2, width: max(0, bounds.width - 8), height: height)
        guard let media, !isVideo, failure == nil, bounds.width > 0, bounds.height > 0 else {
            return
        }
        let pixels = CGSize(
            width: ceil(bounds.width * displayScale), height: ceil(bounds.height * displayScale))
        guard pixels != imagePixels else { return }
        imagePixels = pixels
        imageView.onLoadFailure = { [weak self] error in self?.showFailure(error) }
        imageView.configure(
            url: URL(string: media.url), contentMode: .fit,
            animates: RemoteImageFormat.isAnimated(contentType: media.contentType),
            showsBlurredBackdrop: false, thumbnailPixelSize: pixels, mediaContext: mediaContext)
    }

    private func showFailure(_ description: String) {
        failure = description
        imageView.isHidden = true
        videoLoading = false
        updateProgress(visible: false)
        imageView.setVisible(false)
        video?.setVisible(false)
        let caption = bounds.width < 120 ? String(localized: "Failed") : description
        setStatus(emoji.isEmpty ? caption : "\(emoji)\n\(caption)")
        #if os(macOS)
            toolTip = description
        #endif
        updateAccessibility()
        onError?(description)
    }

    private static func posterKey(_ url: URL) -> String {
        "sticker-video-poster:" + url.absoluteString
    }

    private func installVideoPoster(_ image: StickerNativeImage) {
        #if os(iOS)
            let pixels = image.cgImage
        #else
            var proposed = CGRect(origin: .zero, size: image.size)
            let pixels = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        #endif
        guard let pixels else { return }
        hasVideoPoster = true
        imageView.configureLocal(
            image: pixels, contentMode: .fit, showsBlurredBackdrop: false, isLoading: false)
        imageView.isHidden = false
    }

    private func updateProgress(visible: Bool) {
        let loading = videoLoading && !hasVideoPoster && failure == nil && visible
        #if os(iOS)
            if loading { progress.startAnimating() } else { progress.stopAnimating() }
        #else
            if loading { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        #endif
    }

    private func setStatus(_ text: String?) {
        #if os(iOS)
            statusLabel.text = text
        #else
            statusLabel.stringValue = text ?? ""
        #endif
        statusLabel.isHidden = text == nil
    }

    private func updateAccessibility() {
        let label =
            emoji.isEmpty ? String(localized: "Sticker") : String(localized: "Sticker \(emoji)")
        #if os(iOS)
            accessibilityLabel = label
            accessibilityValue =
                failure
                ?? (videoLoading && !hasVideoPoster ? String(localized: "Loading sticker") : nil)
        #else
            setAccessibilityLabel(label)
            setAccessibilityValue(
                failure
                    ?? (videoLoading && !hasVideoPoster
                        ? String(localized: "Loading sticker") : nil))
        #endif
    }
}

/// WebKit is intentional: SwiftUI/AVPlayer does not provide WebKit's WebM
/// demuxing/codec support. A control-free native WKWebView streams the original
/// signed media URL, rather than downloading a whole video into Data or a blob.
/// WebM requires iOS/iPadOS 17.4 (macOS support predates our minimum deployment):
/// https://webkit.org/blog/15063/webkit-features-in-safari-17-4/#media
/// VP9-alpha compositing remains an upstream limitation on affected WebKit builds:
/// https://bugs.webkit.org/show_bug.cgi?id=275908
@MainActor
private final class StickerVideoPlayback: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let view: WKWebView
    var onStatus: ((String?, Bool) -> Void)?
    var onPoster: ((StickerNativeImage) -> Void)?
    private var snapshotPending = false
    private let url: URL
    private let contentType: String
    private var visible = false
    private var loaded = false
    private var token = UUID().uuidString
    private var navigation: WKNavigation?

    init(url: URL, contentType: String, dataStore: WKWebsiteDataStore) {
        self.url = url
        self.contentType = url.pathExtension.lowercased() == "webm" ? "video/webm" : contentType
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
            configuration.allowsInlineMediaPlayback = true
            configuration.allowsPictureInPictureMediaPlayback = false
        #endif
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        // A weak relay avoids the user-content-controller/owner retain cycle.
        configuration.userContentController.add(
            StickerVideoMessageRelay(owner: self), name: "sticker")
        view.navigationDelegate = self
        #if os(iOS)
            view.isOpaque = false
            view.backgroundColor = .clear
            view.scrollView.backgroundColor = .clear
            view.scrollView.isScrollEnabled = false
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
        #else
            view.underPageBackgroundColor = .clear
            view.setAccessibilityElement(false)
        #endif
    }

    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        if visible { start() } else { view.evaluateJavaScript("window.stickerSetVisible?.(false)") }
    }

    func stop() {
        visible = false
        guard loaded else { return }
        loaded = false
        navigation = nil
        token = UUID().uuidString
        view.evaluateJavaScript(
            "(() => { const v = document.querySelector('video'); if (v) { v.pause(); v.removeAttribute('src'); v.load(); } })()"
        )
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
    }

    private func start() {
        guard !loaded else {
            view.evaluateJavaScript("window.stickerSetVisible?.(true)")
            return
        }
        #if os(iOS)
            if contentType.hasPrefix("video/webm"), #unavailable(iOS 17.4) {
                onStatus?(String(localized: "WebM stickers require iOS 17.4 or later."), false)
                return
            }
        #endif
        loaded = true
        let identifier = token
        let source = Self.jsonString(url.absoluteString)
        let type = Self.jsonString(contentType)
        let document = """
            <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; media-src https: http:; script-src 'unsafe-inline'; style-src 'unsafe-inline'">
            <style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}video{width:100%;height:100%;object-fit:contain;pointer-events:none}</style></head>
            <body><video muted loop playsinline preload="metadata" disablepictureinpicture></video><script>
            const v = document.querySelector('video');
            const report = (status) => window.webkit.messageHandlers.sticker.postMessage({token:'\(identifier)',status});
            v.muted = true;
            v.addEventListener('loadeddata', () => report('ready'));
            v.addEventListener('playing', () => report('ready'));
            v.addEventListener('error', () => report('error:' + (v.error ? v.error.code : 0)));
            window.stickerSetVisible = active => {
                if (!active) { v.pause(); return; }
                v.play().catch(e => {
                    if (e.name !== 'AbortError') report(e.name === 'NotSupportedError' ? 'unsupported' : 'playback');
                });
            };
            if (!v.canPlayType(\(type))) report('unsupported');
            else v.src = \(source);
            </script></body></html>
            """
        onStatus?(nil, true)
        navigation = view.loadHTMLString(document, baseURL: nil)
    }

    fileprivate func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard loaded, let body = message.body as? [String: String], body["token"] == token else {
            return
        }
        switch body["status"] {
        case "ready":
            onStatus?(nil, false)
            capturePoster()
        case "unsupported", "error:4":
            onStatus?(
                String(localized: "This device cannot decode this sticker’s video format."), false)
        case "error:2":
            onStatus?(String(localized: "Sticker video could not be downloaded."), false)
        case "error:3":
            onStatus?(
                String(localized: "Sticker video is damaged or uses an unsupported codec."), false)
        default: onStatus?(String(localized: "Sticker video playback failed."), false)
        }
    }

    private func capturePoster() {
        guard visible, onPoster != nil, !snapshotPending, !view.bounds.isEmpty else { return }
        snapshotPending = true
        let capturedToken = token
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        view.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let self, self.loaded, self.token == capturedToken else { return }
            self.snapshotPending = false
            guard let image else { return }
            self.onPoster?(image)
            self.onPoster = nil
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard loaded, navigation === self.navigation else { return }
        webView.evaluateJavaScript("window.stickerSetVisible?.(\(visible ? "true" : "false"))")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard loaded, navigation === self.navigation else { return }
        onStatus?(String(localized: "Sticker video could not be loaded."), false)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard loaded else { return }
        onStatus?(String(localized: "Sticker video playback was interrupted."), false)
    }

    private static func jsonString(_ value: String) -> String {
        // JSON quoting plus '<' escaping prevents a server URL closing our script.
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
    }
}

@MainActor
private final class StickerVideoMessageRelay: NSObject, WKScriptMessageHandler {
    weak var owner: StickerVideoPlayback?
    init(owner: StickerVideoPlayback) { self.owner = owner }
    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        owner?.userContentController(userContentController, didReceive: message)
    }
}
