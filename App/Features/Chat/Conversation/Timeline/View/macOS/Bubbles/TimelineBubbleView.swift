#if os(macOS)
    import AppKit
    import ChahuaAPI
    import SwiftUI

    /// AppKit is intentional here: per-row SwiftUI hosts incurred measured layout and
    /// AttributeGraph work. Cached timeline geometry remains the sole sizing authority.
    @MainActor
    final class TimelineBubbleContentView: NSView {
        private(set) var binding: TimelineRowBinding?
        private let surface = CAShapeLayer()
        private let sections = BubbleSectionsView()
        private let sectionMask = CAShapeLayer()
        private var localFrames: [TimelineSectionID: CGRect] = [:]
        private var headerView: TimelineHeaderView?
        private var replyView: TimelineReplyView?
        private var mediaView: TimelineMediaView?
        private var voiceView: NSHostingView<VoiceMessageBubbleView>?
        private var voiceController: VoicePlaybackController?
        private var textView: AppKitMessageTextView?
        private var metadataView: TimelineMetadataView?
        private var standaloneView: BubbleStandaloneView?
        private var threadView: TimelineThreadFooterButton?
        private var visible = false
        private struct SurfaceGeometry: Equatable {
            let bounds: CGRect
            let outgoing: Bool
            let tail: Bool
            let filled: Bool
        }
        private var surfaceGeometry: SurfaceGeometry?

        override var isFlipped: Bool { true }
        override var wantsDefaultClipping: Bool { false }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = false
            surface.actions = [
                "path": NSNull(), "fillColor": NSNull(), "bounds": NSNull(), "position": NSNull(),
            ]
            layer?.addSublayer(surface)
            sections.wantsLayer = true
            sectionMask.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
            sections.layer?.mask = sectionMask
            addSubview(sections)
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func bind(_ binding: TimelineRowBinding) {
            bind(
                binding,
                resetSelection: self.binding?.presentation.row.id != binding.presentation.row.id)
        }

        func bind(_ binding: TimelineRowBinding, resetSelection: Bool) {
            let geometryChanged = self.binding?.layout.frames != binding.layout.frames
            if self.binding?.presentation.row.id != binding.presentation.row.id
                || self.binding?.presentation.audioURL != binding.presentation.audioURL
                || self.binding?.context.isInteractionPreview
                    != binding.context.isInteractionPreview
            {
                clearAudio()
            }
            self.binding = binding
            if geometryChanged {
                let bubble = binding.layout.frames[.bubble] ?? .zero
                localFrames = binding.layout.frames.mapValues {
                    $0.offsetBy(dx: -bubble.minX, dy: -bubble.minY)
                }
            }
            guard case .message(let row) = binding.presentation.row else {
                clear()
                return
            }
            let p = binding.presentation
            let e = p.environment
            if localFrames[.title] != nil, let title = p.title {
                let view = headerView ?? makeHeader()
                view.isHidden = false
                view.configure(
                    title: title, row: row, fontSize: e.captionSize,
                    frames: binding.layout.titleFrames)
            } else {
                headerView?.clear()
                headerView?.isHidden = true
            }
            if localFrames[.reply] != nil, let reply = p.reply {
                let view = replyView ?? makeReply()
                view.isHidden = false
                view.configure(
                    reply, outgoing: row.isOutgoing, filled: isFilled, fontSize: e.captionSize,
                    frames: binding.layout.replyContentFrames,
                    enabled: binding.actions.openReply != nil)
            } else {
                replyView?.clear()
                replyView?.isHidden = true
            }
            if localFrames[.media] != nil {
                let view = mediaView ?? makeMedia()
                view.isHidden = false
                view.bind(binding)
                view.setVisible(visible)
            } else {
                mediaView?.clear()
                mediaView?.isHidden = true
            }
            configureAudio()
            if localFrames[.text] != nil, let geometry = binding.layout.textGeometry {
                let view: AppKitMessageTextView
                if let textView {
                    view = textView
                } else {
                    view = AppKitMessageTextView(geometry: geometry)
                    textView = view
                    sections.addSubview(view)
                }
                view.isHidden = false
                view.apply(
                    MessageTextContent(
                        text: row.entry.text ?? "",
                        mentions: row.entry.remoteMessage?.mentions ?? [],
                        currentUserID: binding.context.currentUserID, isOutgoing: row.isOutgoing,
                        action: binding.actions.openLink,
                        mentionAction: binding.actions.openMention,
                        metadata: localFrames[.media] == nil ? p.metadata : nil,
                        failureAction: failureAction, geometry: geometry, fontSize: e.bodySize
                    ), resetSelection: resetSelection)
            } else {
                textView?.clear()
                textView?.isHidden = true
            }
            if localFrames[.metadata] != nil, let metadata = p.metadata {
                let view = metadataView ?? makeMetadata()
                view.isHidden = false
                view.configure(
                    metadata, overlay: p.metadataIsOverlay && localFrames[.media] != nil,
                    failureAction: failureAction)
                // Audio hosts the shared footer behind native timestamp/status.
                sections.addSubview(view, positioned: .above, relativeTo: nil)
            } else {
                metadataView?.clear()
                metadataView?.isHidden = true
            }
            if localFrames[.standalone] != nil, let text = p.standaloneText {
                let view = standaloneView ?? makeStandalone()
                view.isHidden = false
                view.configure(
                    text: text, deleted: row.entry.remoteMessage?.isDeleted == true,
                    outgoing: row.isOutgoing && isFilled, fontSize: e.bodySize,
                    symbolSize: binding.layout.standaloneSymbolSize,
                    gap: binding.layout.standaloneLabelGap)
            } else {
                standaloneView?.clear()
                standaloneView?.isHidden = true
            }
            if localFrames[.thread] != nil, let label = p.threadLabel {
                let view = threadView ?? makeThread()
                view.isHidden = false
                view.target = self
                view.action = #selector(openThread)
                view.configure(
                    label: label, outgoing: row.isOutgoing, fontSize: e.bodySize,
                    displayScale: e.displayScale, frames: binding.layout.threadContentFrames,
                    enabled: !binding.context.isInteractionPreview && row.entry.remoteMessage != nil
                        && row.entry.remoteMessage?.isDeleted != true
                        && binding.actions.openThread != nil)
            } else {
                threadView?.clear()
                threadView?.isHidden = true
            }
            updateSurface()
            needsLayout = true
        }

        func clear() {
            binding = nil
            localFrames.removeAll(keepingCapacity: true)
            visible = false
            headerView?.clear()
            headerView?.isHidden = true
            replyView?.clear()
            replyView?.isHidden = true
            mediaView?.clear()
            mediaView?.isHidden = true
            clearAudio()
            textView?.clear()
            textView?.isHidden = true
            metadataView?.clear()
            metadataView?.isHidden = true
            standaloneView?.clear()
            standaloneView?.isHidden = true
            threadView?.clear()
            threadView?.isHidden = true
            surface.path = nil
            surfaceGeometry = nil
        }

        func setVisible(_ visible: Bool) {
            guard self.visible != visible else { return }
            self.visible = visible
            mediaView?.setVisible(visible && mediaView?.isHidden == false)
            if !visible, let controller = voiceController {
                // Native row visibility is updated inside NSViewRepresentable.updateNSView.
                // Teardown must publish only after that SwiftUI update completes.
                DispatchQueue.main.async { [weak self, weak controller] in
                    guard let self, !self.visible, self.voiceController === controller else {
                        return
                    }
                    controller?.stop()
                }
            }
            configureAudio()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { setVisible(false) }
        }

        override func layout() {
            super.layout()
            sections.frame = bounds
            headerView?.frame = localFrames[.title] ?? .zero
            replyView?.frame = localFrames[.reply] ?? .zero
            mediaView?.frame = localFrames[.media] ?? .zero
            voiceView?.frame = localFrames[.audio] ?? .zero
            textView?.frame = localFrames[.text] ?? .zero
            metadataView?.frame = localFrames[.metadata] ?? .zero
            standaloneView?.frame = localFrames[.standalone] ?? .zero
            threadView?.frame = localFrames[.thread] ?? .zero
            updateSurface()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateSurface()
        }

        private var isFilled: Bool {
            guard let binding, case .message(let row) = binding.presentation.row else {
                return false
            }
            let sticker =
                row.entry.messageType == .sticker && row.entry.remoteMessage?.isDeleted != true
            let mediaOnly = localFrames[.media] != nil && localFrames[.text] == nil
            return !sticker
                && (!mediaOnly || binding.presentation.reply != nil
                    || binding.presentation.title != nil)
        }

        private var failureAction: (() -> Void)? {
            guard let binding, case .message(let row) = binding.presentation.row, row.isOutgoing,
                case .pending(let pending) = row.entry, pending.state == .failed,
                binding.actions.openFailedMessage != nil
            else { return nil }
            return { [weak self] in
                guard let binding = self?.binding,
                    case .message(let row) = binding.presentation.row,
                    row.isOutgoing, case .pending(let pending) = row.entry, pending.state == .failed
                else { return }
                binding.actions.openFailedMessage?(pending.clientGeneratedID)
            }
        }

        @objc private func openThread() {
            guard let binding, !binding.context.isInteractionPreview,
                localFrames[.thread] != nil, binding.presentation.threadLabel != nil,
                case .message(let row) = binding.presentation.row,
                let message = row.entry.remoteMessage, !message.isDeleted,
                let openThread = binding.actions.openThread
            else { return }
            openThread(message.id)
        }

        private func updateSurface() {
            guard let binding, case .message(let row) = binding.presentation.row else {
                surface.path = nil
                return
            }
            let sticker =
                row.entry.messageType == .sticker && row.entry.remoteMessage?.isDeleted != true
            let mediaOnly = localFrames[.media] != nil && localFrames[.text] == nil
            let tail =
                !sticker && !mediaOnly
                && (row.groupPosition == .single || row.groupPosition == .last)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let geometry = SurfaceGeometry(
                bounds: bounds, outgoing: row.isOutgoing, tail: tail, filled: isFilled)
            if surfaceGeometry != geometry {
                surfaceGeometry = geometry
                surface.frame = bounds
                surface.path =
                    geometry.filled
                    ? bubblePath(
                        in: bounds, outgoing: row.isOutgoing, hasTail: tail, drawsTail: true) : nil
                sectionMask.frame = bounds
                sectionMask.path = bubblePath(
                    in: bounds, outgoing: row.isOutgoing, hasTail: tail, drawsTail: false)
            }
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                surface.fillColor =
                    NSColor(
                        row.isOutgoing
                            ? ChahuaTheme.ChatBubble.outgoingBackground
                            : ChahuaTheme.ChatBubble.incomingBackground(for: dark ? .dark : .light)
                    ).cgColor
            }
            CATransaction.commit()
        }

        private func makeHeader() -> TimelineHeaderView {
            let view = TimelineHeaderView(frame: .zero)
            sections.addSubview(view)
            headerView = view
            return view
        }
        private func makeReply() -> TimelineReplyView {
            let view = TimelineReplyView(frame: .zero)
            view.onActivate = { [weak self] in
                guard let binding = self?.binding, let reply = binding.presentation.reply,
                    !reply.isDeleted
                else { return }
                binding.actions.openReply?(reply.id)
            }
            sections.addSubview(view)
            replyView = view
            return view
        }
        private func makeMedia() -> TimelineMediaView {
            let view = TimelineMediaView(frame: .zero)
            sections.addSubview(view)
            mediaView = view
            return view
        }
        private func configureAudio() {
            guard let binding, localFrames[.audio] != nil,
                case .message(let row) = binding.presentation.row
            else {
                clearAudio()
                return
            }
            let controller = voiceController ?? VoicePlaybackController()
            voiceController = controller
            let environment = binding.presentation.environment
            let content = VoiceMessageBubbleView(
                controller: controller, url: binding.presentation.audioURL,
                isOutgoing: row.isOutgoing,
                isActive: visible && !binding.context.isInteractionPreview,
                metrics: binding.presentation.voiceMetrics,
                localeIdentifier: environment.localeIdentifier,
                layoutDirection: environment.layoutDirection)
            if let voiceView {
                voiceView.rootView = content
            } else {
                // Exception to native timeline sections: AppKit retains the measured
                // row and chrome, while one shared SwiftUI control owns playback and
                // seeking. Hosting only audio avoids duplicate platform control UIs.
                let view = NSHostingView(rootView: content)
                view.sizingOptions = []
                sections.addSubview(view)
                voiceView = view
            }
        }

        private func clearAudio() {
            // A recycled row no longer owns this controller. Retain it until
            // teardown runs after the hosting view has left the update pass.
            if let controller = voiceController {
                DispatchQueue.main.async { controller.stop() }
            }
            voiceView?.removeFromSuperview()
            voiceView = nil
            voiceController = nil
        }

        private func makeMetadata() -> TimelineMetadataView {
            let view = TimelineMetadataView(frame: .zero)
            sections.addSubview(view)
            metadataView = view
            return view
        }
        private func makeStandalone() -> BubbleStandaloneView {
            let view = BubbleStandaloneView(frame: .zero)
            sections.addSubview(view)
            standaloneView = view
            return view
        }
        private func makeThread() -> TimelineThreadFooterButton {
            let view = TimelineThreadFooterButton(frame: .zero)
            sections.addSubview(view)
            threadView = view
            return view
        }
    }

    private final class BubbleSectionsView: NSView {
        override var isFlipped: Bool { true }
    }

    /// Zero-inset native fields consume assigned rectangles; no intrinsic sizing.
    private final class BubbleLabelCell: NSTextFieldCell {
        override func drawingRect(forBounds rect: NSRect) -> NSRect { rect }
        override func titleRect(forBounds rect: NSRect) -> NSRect { rect }
        override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
            // NSTextFieldCell adds text padding internally even with zero-inset
            // drawing/title rectangles. Draw in the engine's measured rectangle.
            attributedStringValue.draw(
                with: cellFrame, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private final class BubbleLabel: NSTextField {
        init() {
            super.init(frame: .zero)
            cell = BubbleLabelCell(textCell: "")
            isEditable = false
            isSelectable = false
            isBordered = false
            drawsBackground = false
            maximumNumberOfLines = 1
            lineBreakMode = .byTruncatingTail
            cell?.wraps = false
            cell?.isScrollable = false
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    private final class TimelineHeaderView: NSView {
        private let name = BubbleLabel()
        private let group = BubbleLabel()
        private let gender = BubbleLabel()
        private let groupSurface = CALayer()
        private var title: TitleContent?
        private var row: TimelineMessageRow?
        private var itemFrames: [CGRect] = []
        override var isFlipped: Bool { true }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            groupSurface.cornerRadius = 2
            groupSurface.actions = [
                "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(),
            ]
            layer?.addSublayer(groupSurface)
            addSubview(name)
            addSubview(group)
            addSubview(gender)
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func configure(
            title: TitleContent, row: TimelineMessageRow, fontSize: CGFloat, frames: [CGRect]
        ) {
            self.title = title
            self.row = row
            itemFrames = frames
            name.stringValue = title.name
            name.font = .systemFont(ofSize: fontSize, weight: .semibold)
            group.stringValue = title.groupName ?? ""
            group.font = .systemFont(ofSize: fontSize)
            gender.stringValue = title.genderGlyph ?? ""
            gender.font = .systemFont(ofSize: fontSize)
            group.isHidden = title.groupName == nil || frames.count < 2 || frames[1].isEmpty
            groupSurface.isHidden = group.isHidden
            gender.isHidden = title.genderGlyph == nil || frames.count < 3 || frames[2].isEmpty
            setAccessibilityLabel(
                [title.name, title.groupName, title.genderGlyph].compactMap { $0 }.joined(
                    separator: " "))
            updateColors()
            needsLayout = true
        }
        func clear() {
            title = nil
            row = nil
            itemFrames.removeAll(keepingCapacity: true)
            name.stringValue = ""
            group.stringValue = ""
            gender.stringValue = ""
            setAccessibilityLabel(nil)
        }
        override func layout() {
            super.layout()
            name.frame = itemFrames.first ?? .zero
            let groupFrame = itemFrames.count > 1 ? itemFrames[1] : .zero
            groupSurface.frame = groupFrame
            group.frame = groupFrame.insetBy(dx: min(5, groupFrame.width / 2), dy: 0)
            gender.frame = itemFrames.count > 2 ? itemFrames[2] : .zero
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColors()
        }
        private func updateColors() {
            guard let row, let title else { return }
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                name.textColor =
                    row.isOutgoing
                    ? .white
                    : NSColor(bubbleColorForUser(uid: row.entry.senderID, dark: dark))
                        .withAlphaComponent(0.85)
                group.textColor = NSColor.white.withAlphaComponent(0.85)
                var color = NSColor.gray.withAlphaComponent(0.44)
                if let info = title.userGroup {
                    let darkHex = info.chatGroupColorDark.flatMap { $0.isEmpty ? nil : $0 }
                    if let hex = dark ? darkHex ?? info.chatGroupColor : info.chatGroupColor,
                        let value = bubbleColor(hex: hex)
                    {
                        color = NSColor(value)
                    }
                }
                groupSurface.backgroundColor =
                    color.withAlphaComponent(color.alphaComponent * 0.85).cgColor
                gender.textColor =
                    title.genderGlyph.flatMap { bubbleColor(hex: $0 == "♂" ? "3cb4f0" : "ff8080") }
                    .map { NSColor($0) } ?? .labelColor
            }
        }
    }

    @MainActor
    private final class TimelineReplyView: NSButton {
        var onActivate: (() -> Void)?
        private let author = BubbleLabel()
        private let previewLabel = BubbleLabel()
        private let stripe = CALayer()
        private var preview: MessagePreview?
        private var outgoing = false
        private var filled = false
        private var fontSize: CGFloat = 12
        private var contentFrames: [CGRect] = []
        override var isFlipped: Bool { true }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            title = ""
            isBordered = false
            setButtonType(.momentaryPushIn)
            target = self
            action = #selector(activate)
            wantsLayer = true
            layer?.cornerRadius = 6
            layer?.masksToBounds = true
            stripe.actions = [
                "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(),
            ]
            layer?.addSublayer(stripe)
            addSubview(author)
            addSubview(previewLabel)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func configure(
            _ preview: MessagePreview, outgoing: Bool, filled: Bool, fontSize: CGFloat,
            frames: [CGRect], enabled: Bool
        ) {
            self.preview = preview
            self.outgoing = outgoing
            self.filled = filled
            self.fontSize = fontSize
            contentFrames = frames
            author.stringValue =
                preview.sender.name.flatMap { $0.isEmpty ? nil : $0 }
                ?? "User \(preview.sender.uid)"
            author.font = .systemFont(ofSize: fontSize * 11 / 12, weight: .semibold)
            previewLabel.stringValue = messagePreview(preview)
            previewLabel.font = .systemFont(ofSize: fontSize)
            isEnabled = enabled
            setAccessibilityLabel("\(author.stringValue), \(previewLabel.stringValue)")
            updateColors()
            needsLayout = true
        }
        func clear() {
            preview = nil
            author.stringValue = ""
            previewLabel.stringValue = ""
            isEnabled = false
            setAccessibilityLabel(nil)
        }
        override func layout() {
            super.layout()
            stripe.frame = CGRect(x: 0, y: 0, width: min(3, bounds.width), height: bounds.height)
            author.frame = contentFrames.first ?? .zero
            previewLabel.frame = contentFrames.count > 1 ? contentFrames[1] : .zero
        }
        override func resetCursorRects() {
            if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColors()
        }
        @objc private func activate() { if isEnabled, preview != nil { onActivate?() } }
        private func updateColors() {
            guard let preview else { return }
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let color =
                    outgoing && filled
                    ? NSColor.white
                    : NSColor(bubbleColorForUser(uid: preview.sender.uid, dark: dark))
                author.textColor = color.withAlphaComponent(0.85)
                previewLabel.textColor = color.withAlphaComponent(0.7)
                layer?.backgroundColor =
                    (outgoing && filled ? NSColor.black : color).withAlphaComponent(0.1).cgColor
                stripe.backgroundColor = color.withAlphaComponent(outgoing ? 0.5 : 1).cgColor
            }
        }
    }

    @MainActor
    private final class TimelineThreadFooterButton: NSButton {
        private let label = BubbleLabel()
        private var symbol: NSImage?
        private var chevron: NSImage?
        private var contentFrames: [CGRect] = []
        private var outgoing = false
        private var fontSize: CGFloat = 14
        private var dividerHeight: CGFloat = 1
        private var backgroundColor = NSColor.clear
        private var dividerColor = NSColor.clear

        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            title = ""
            isBordered = false
            setButtonType(.momentaryPushIn)
            addSubview(label)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(
            label: String, outgoing: Bool, fontSize: CGFloat, displayScale: CGFloat,
            frames: [CGRect], enabled: Bool
        ) {
            self.label.stringValue = label
            self.label.font = .systemFont(ofSize: fontSize)
            self.outgoing = outgoing
            self.fontSize = fontSize
            dividerHeight = 1 / max(1, displayScale)
            contentFrames = frames
            isEnabled = enabled
            setAccessibilityLabel(label)
            updatePaint()
            needsLayout = true
        }

        func clear() {
            label.stringValue = ""
            symbol = nil
            chevron = nil
            contentFrames.removeAll(keepingCapacity: true)
            isEnabled = false
            target = nil
            action = nil
            setAccessibilityLabel(nil)
            needsDisplay = true
        }

        override func layout() {
            super.layout()
            label.frame = contentFrames.count > 1 ? contentFrames[1] : .zero
        }

        override func draw(_ dirtyRect: NSRect) {
            // Only the footer is filled for sticker/media-only bubbles; the shared
            // bubble clip rounds its bottom without filling the transparent content.
            backgroundColor.setFill()
            bounds.fill()
            dividerColor.setFill()
            CGRect(x: 0, y: 0, width: bounds.width, height: dividerHeight).fill()
            if let frame = contentFrames.first {
                symbol?.draw(
                    in: frame, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
            }
            if contentFrames.count > 2 {
                chevron?.draw(
                    in: contentFrames[2], from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
            }
        }

        override func resetCursorRects() {
            if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updatePaint()
        }

        private func updatePaint() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let color = NSColor(
                    outgoing ? ChahuaTheme.ChatBubble.outgoingForeground : ChahuaTheme.accent)
                label.textColor = color
                backgroundColor = NSColor(
                    outgoing
                        ? ChahuaTheme.ChatBubble.outgoingBackground
                        : ChahuaTheme.ChatBubble.incomingBackground(for: dark ? .dark : .light))
                dividerColor = outgoing ? color.withAlphaComponent(0.2) : .separatorColor
                let configuration = NSImage.SymbolConfiguration(
                    pointSize: fontSize, weight: .regular
                )
                .applying(.init(paletteColors: [color]))
                symbol = NSImage(
                    systemSymbolName: "bubble.left.and.bubble.right.fill",
                    accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration)
                chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration)
            }
            needsDisplay = true
        }
    }

    @MainActor
    private final class TimelineMetadataView: NSView {
        private var metadata: MessageMetadata?
        private var overlay = false
        private var failureAction: (() -> Void)?
        private var failureButton: MetadataFailureButton?
        override var isFlipped: Bool { true }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func configure(_ metadata: MessageMetadata, overlay: Bool, failureAction: (() -> Void)?) {
            self.metadata = metadata
            self.overlay = overlay
            self.failureAction = failureAction
            layer?.backgroundColor = overlay ? NSColor.black.withAlphaComponent(0.45).cgColor : nil
            setAccessibilityLabel(metadata.accessibilityLabel)
            if metadata.state == .failed, failureAction != nil {
                let button: MetadataFailureButton
                if let failureButton {
                    button = failureButton
                } else {
                    button = MetadataFailureButton(frame: .zero)
                    button.title = ""
                    button.isBordered = false
                    button.imagePosition = .imageOnly
                    button.imageScaling = .scaleProportionallyUpOrDown
                    button.setButtonType(.momentaryPushIn)
                    button.target = self
                    button.action = #selector(openFailure)
                    button.setAccessibilityLabel(
                        AppLanguage.localized("Failed to send. Retry options"))
                    addSubview(button)
                    self.failureButton = button
                }
                button.image = metadata.symbol
                button.isHidden = false
                setAccessibilityElement(false)
            } else {
                failureButton?.isHidden = true
                setAccessibilityElement(true)
            }
            needsLayout = true
            needsDisplay = true
        }
        func clear() {
            metadata = nil
            failureAction = nil
            failureButton?.isHidden = true
            failureButton?.image = nil
            setAccessibilityLabel(nil)
            needsDisplay = true
        }
        private var drawingFrame: CGRect {
            guard let metadata else { return .zero }
            let padding = overlay ? min(6, bounds.width / 2) : 0
            let width = max(0, bounds.width - 2 * padding)
            let scale = metadata.size.width > 0 ? min(1, width / metadata.size.width) : 1
            let size = CGSize(
                width: metadata.size.width * scale, height: metadata.size.height * scale)
            return CGRect(
                x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                width: size.width, height: size.height)
        }
        override func layout() {
            super.layout()
            layer?.cornerRadius = overlay ? min(bounds.width, bounds.height) / 2 : 0
            failureButton?.frame = metadata?.symbolFrame(in: drawingFrame) ?? .zero
        }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                metadata?.draw(in: drawingFrame, drawsSymbol: failureButton?.isHidden != false)
            }
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
        @objc private func openFailure() { if metadata?.state == .failed { failureAction?() } }
    }

    private final class MetadataFailureButton: NSButton {
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    }

    @MainActor
    private final class BubbleStandaloneView: NSView {
        private var text = ""
        private var deleted = false
        private var outgoing = false
        private var fontSize: CGFloat = 17
        private var symbolSize: CGSize = .zero
        private var gap: CGFloat = 0
        private var attributed = NSAttributedString(string: "")
        private var symbol: NSImage?
        override var isFlipped: Bool { true }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func configure(
            text: String, deleted: Bool, outgoing: Bool, fontSize: CGFloat, symbolSize: CGSize,
            gap: CGFloat
        ) {
            self.text = text
            self.deleted = deleted
            self.outgoing = outgoing
            self.fontSize = fontSize
            self.symbolSize = symbolSize
            self.gap = gap
            setAccessibilityLabel(text)
            updatePaint()
        }
        func clear() {
            text = ""
            attributed = NSAttributedString(string: "")
            symbol = nil
            setAccessibilityLabel(nil)
            needsDisplay = true
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updatePaint()
        }
        private func updatePaint() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let foreground = NSColor(
                    outgoing
                        ? ChahuaTheme.ChatBubble.outgoingForeground
                        : ChahuaTheme.ChatBubble.incomingForeground(for: dark ? .dark : .light))
                var font = NSFont.systemFont(ofSize: fontSize)
                if deleted {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byWordWrapping
                attributed = NSAttributedString(
                    string: text,
                    attributes: [
                        .font: font, .foregroundColor: foreground, .paragraphStyle: paragraph,
                    ])
                symbol =
                    deleted
                    ? nil
                    : NSImage(
                        systemSymbolName: "questionmark.square.dashed",
                        accessibilityDescription: nil)?.withSymbolConfiguration(
                            .init(pointSize: fontSize, weight: .regular).applying(
                                .init(paletteColors: [foreground])))
            }
            needsDisplay = true
        }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let offset = deleted ? 0 : symbolSize.width + gap
            symbol?.draw(
                in: CGRect(origin: .zero, size: symbolSize), from: .zero, operation: .sourceOver,
                fraction: 1, respectFlipped: true, hints: nil)
            attributed.draw(
                with: CGRect(
                    x: offset, y: 0, width: max(0, bounds.width - offset), height: bounds.height),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }

    /// The same circular corners and droplet used by the retained Apple bubble shape.
    private func bubblePath(in rect: CGRect, outgoing: Bool, hasTail: Bool, drawsTail: Bool)
        -> CGPath
    {
        let radius = min(18, rect.width / 2, rect.height / 2)
        let small = min(hasTail ? 0 : 4, radius)
        let bottomLeft = outgoing ? radius : small
        let bottomRight = outgoing ? small : radius
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY + radius), radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        if bottomRight > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY), radius: bottomRight)
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        if bottomLeft > 0 {
            path.addArc(
                tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottomLeft), radius: bottomLeft)
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX + radius, y: rect.minY), radius: radius)
        path.closeSubpath()
        guard hasTail && drawsTail else { return path }
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: 1, y: 17))
        tail.addLine(to: CGPoint(x: 8, y: 17))
        tail.addLine(to: CGPoint(x: 8, y: 0))
        tail.addCurve(
            to: CGPoint(x: 5.9, y: 8.8), control1: CGPoint(x: 7.8, y: 2.84),
            control2: CGPoint(x: 7.1, y: 5.8))
        tail.addCurve(
            to: CGPoint(x: 1.3, y: 15.3), control1: CGPoint(x: 5, y: 11.1),
            control2: CGPoint(x: 3.5, y: 13.3))
        let halfChord = sqrt(CGFloat(2.98)) / 2
        let offset = sqrt(1 - halfChord * halfChord) / (halfChord * 2)
        let center = CGPoint(x: 1.15 + 1.7 * offset, y: 16.15 + 0.3 * offset)
        tail.addArc(
            center: center, radius: 1, startAngle: atan2(15.3 - center.y, 1.3 - center.x),
            endAngle: atan2(17 - center.y, 1 - center.x), clockwise: true)
        tail.closeSubpath()
        let transform =
            outgoing
            ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.maxX + 8, ty: rect.maxY - 17)
            : CGAffineTransform(translationX: rect.minX - 8, y: rect.maxY - 17)
        path.addPath(tail, transform: transform)
        return path
    }
#endif
