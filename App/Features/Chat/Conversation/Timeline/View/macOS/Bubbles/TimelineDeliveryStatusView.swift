#if os(macOS)
    import AppKit
    import SwiftUI

    /// Native selection and cached geometry require AppKit row ownership. The trace
    /// still shows NSHostingView layout/AttributeGraph work after redundant root writes
    /// were removed, so static decorations reuse bounded images of the canonical
    /// SwiftUI content. Only sending retains a live host for its real animation.
    @MainActor
    final class TimelineDeliveryStatusView: NSView {
        private struct RasterKey: Hashable {
            let status: String
            let size: CGFloat
            let separation: CGFloat
            let checkHeight: CGFloat?
            let width: CGFloat
            let height: CGFloat
            let scale: CGFloat
            let appearance: String
            let foreground: NSColor
            let systemRed: NSColor
        }

        private struct RasterContent: View {
            let indicator: MessageDeliveryStatusContent
            let scale: CGFloat

            var body: some View { indicator.environment(\.displayScale, scale) }
        }

        // The key includes the fitted slot, not just the nominal symbol size: the
        // canonical GeometryReader centers/scales checks within that exact slot.
        private static let rasterLimit = 64
        private static var rasters: [RasterKey: NSImage] = [:]
        private static var rasterOrder: [RasterKey] = []
        private static var nextEviction = 0
        // One offscreen host lets AppKit supply the real local appearance/contrast
        // environment. ImageRenderer cannot publicly set colorSchemeContrast.
        private static var rasterHost: NSHostingView<RasterContent>?
        private var content: MessageDeliveryStatusContent?
        private var foreground: NSColor?
        private var host: NSHostingView<MessageDeliveryStatusContent>?
        private var requestedVisible = true
        private var drawnSize = CGSize.zero

        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(false)
            setAccessibilityHidden(true)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(_ metadata: MessageMetadata?) {
            guard let next = metadata?.statusContent else {
                content = nil
                foreground = nil
                removeHost()
                isHidden = true
                needsDisplay = true
                return
            }
            let previous = content
            content = next
            foreground = metadata?.foreground
            isHidden = false
            if next.status == .sending {
                updateAnimatedContent()
            } else {
                // Dropping the old host also tears down a sending animation when it
                // transitions to a static state; no hidden per-row graph is retained.
                removeHost()
            }
            if previous?.status != next.status || previous?.size != next.size
                || previous?.foreground != next.foreground
                || previous?.checkSeparation != next.checkSeparation
                || previous?.checkHeight != next.checkHeight
            {
                needsDisplay = true
            }
        }

        func setVisible(_ visible: Bool) {
            requestedVisible = visible
            updateAnimatedContent()
        }

        // The native timestamp/retry button retain selection and accessibility.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            if host?.frame != bounds { host?.frame = bounds }
            if drawnSize != bounds.size {
                drawnSize = bounds.size
                needsDisplay = true
            }
            updateAnimatedContent()
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard let content, content.status != .sending, let foreground,
                bounds.width > 0, bounds.height > 0,
                bounds.width.isFinite, bounds.height.isFinite
            else { return }
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
            let appearance = effectiveAppearance
            var resolvedForeground: NSColor?
            var resolvedRed: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolvedForeground = foreground.usingColorSpace(.extendedSRGB)
                resolvedRed = NSColor.systemRed.usingColorSpace(.extendedSRGB)
            }
            guard let resolvedForeground, let resolvedRed else {
                installHost(content)
                return
            }
            let key = RasterKey(
                status: content.status.rawValue, size: content.size,
                separation: content.checkSeparation, checkHeight: content.checkHeight,
                width: bounds.width, height: bounds.height, scale: scale,
                appearance: appearance.name.rawValue, foreground: resolvedForeground,
                systemRed: resolvedRed)
            let image: NSImage
            if let cached = Self.rasters[key] {
                image = cached
            } else {
                let resolvedContent = MessageDeliveryStatusContent(
                    status: content.status, size: content.size,
                    foreground: Color(resolvedForeground),
                    checkSeparation: content.checkSeparation, checkHeight: content.checkHeight)
                let root = RasterContent(indicator: resolvedContent, scale: scale)
                let renderer: NSHostingView<RasterContent>
                if let cached = Self.rasterHost {
                    renderer = cached
                    renderer.rootView = root
                } else {
                    renderer = NSHostingView(rootView: root)
                    renderer.sizingOptions = []
                    Self.rasterHost = renderer
                }
                renderer.appearance = appearance
                renderer.frame = CGRect(origin: .zero, size: bounds.size)
                renderer.layoutSubtreeIfNeeded()
                let width = Int(ceil(bounds.width * scale))
                let height = Int(ceil(bounds.height * scale))
                guard
                    let bitmap = NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                else {
                    // Preserve real shared rendering if an image cannot be produced.
                    // Normal static rows never allocate or attach this fallback host.
                    installHost(content)
                    return
                }
                // Round only the bitmap's extent, never the canonical layout slot.
                // Drawing back at this size avoids stretching fractional-pixel slots.
                let rasterSize = CGSize(
                    width: CGFloat(width) / scale, height: CGFloat(height) / scale)
                bitmap.size = rasterSize
                NSGraphicsContext.saveGraphicsState()
                appearance.performAsCurrentDrawingAppearance {
                    renderer.cacheDisplay(in: CGRect(origin: .zero, size: rasterSize), to: bitmap)
                }
                NSGraphicsContext.restoreGraphicsState()
                image = NSImage(size: rasterSize)
                image.addRepresentation(bitmap)
                if Self.rasterOrder.count == Self.rasterLimit {
                    Self.rasters.removeValue(forKey: Self.rasterOrder[Self.nextEviction])
                    Self.rasterOrder[Self.nextEviction] = key
                    Self.nextEviction = (Self.nextEviction + 1) % Self.rasterLimit
                } else {
                    Self.rasterOrder.append(key)
                }
                Self.rasters[key] = image
            }
            removeHost()
            NSGraphicsContext.saveGraphicsState()
            image.draw(
                in: CGRect(origin: bounds.origin, size: image.size), from: .zero,
                operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            needsDisplay = true
            updateAnimatedContent()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            needsDisplay = true
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            updateAnimatedContent()
        }

        override func viewDidHide() {
            super.viewDidHide()
            updateAnimatedContent()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            updateAnimatedContent()
        }

        private func removeHost() {
            host?.removeFromSuperview()
            host = nil
        }

        private func installHost(_ content: MessageDeliveryStatusContent) {
            if let host {
                let previous = host.rootView
                guard
                    previous.status != content.status || previous.size != content.size
                        || previous.foreground != content.foreground
                        || previous.isVisible != content.isVisible
                        || previous.checkSeparation != content.checkSeparation
                        || previous.checkHeight != content.checkHeight
                else { return }
                host.rootView = content
            } else {
                let host = NSHostingView(rootView: content)
                host.sizingOptions = []
                host.setAccessibilityElement(false)
                host.setAccessibilityHidden(true)
                host.frame = bounds
                addSubview(host)
                self.host = host
            }
        }

        private func updateAnimatedContent() {
            guard var content, content.status == .sending else { return }
            content.isVisible =
                requestedVisible && window != nil
                && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
            installHost(content)
        }
    }
#endif
