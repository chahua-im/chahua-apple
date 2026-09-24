#if os(iOS)
    import ChahuaAPI
    import SwiftUI
    import UIKit

    /// UIKit is intentional: SwiftUI-hosted timeline rows repeat layout and
    /// AttributeGraph work. Native sections retain their views and TextKit selection
    /// while the measured TimelineRowLayout remains the sole sizing authority.
    @MainActor
    final class TimelineBubbleContentView: UIView {
        private(set) var binding: TimelineRowBinding?
        override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
            didSet { updateAccessibilityActions() }
        }
        private let surface = CAShapeLayer()
        private let sections = UIView(frame: .zero)
        private let sectionMask = CAShapeLayer()
        private var localFrames: [TimelineSectionID: CGRect] = [:]
        private var headerView: TimelineHeaderView?
        private var replyView: TimelineReplyView?
        private var mediaView: TimelineMediaView?
        private var voiceView: (UIView & UIContentView)?
        private var voiceController: VoicePlaybackController?
        private var textView: UIKitMessageTextView?
        private var metadataView: TimelineMetadataView?
        private var standaloneView: BubbleStandaloneView?
        private var visible = false

        private struct SurfaceGeometry: Equatable {
            let bounds: CGRect
            let outgoing: Bool
            let tail: Bool
            let filled: Bool
        }
        private var surfaceGeometry: SurfaceGeometry?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            clipsToBounds = false
            isAccessibilityElement = false
            surface.actions = [
                "path": NSNull(), "fillColor": NSNull(), "bounds": NSNull(), "position": NSNull(),
            ]
            layer.addSublayer(surface)
            sectionMask.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
            sections.layer.mask = sectionMask
            addSubview(sections)
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
                (view: TimelineBubbleContentView, _: UITraitCollection) in
                view.updateSurface()
            }
        }

        required init?(coder: NSCoder) { nil }

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
            let presentation = binding.presentation
            let environment = presentation.environment
            if localFrames[.title] != nil, let title = presentation.title {
                let view = headerView ?? makeHeader()
                view.isHidden = false
                view.configure(
                    title: title, row: row, fontSize: environment.captionSize,
                    frames: binding.layout.titleFrames)
            } else {
                headerView?.clear()
                headerView?.isHidden = true
            }
            if localFrames[.reply] != nil, let reply = presentation.reply {
                let view = replyView ?? makeReply()
                view.isHidden = false
                view.configure(
                    reply, outgoing: row.isOutgoing, filled: isFilled,
                    fontSize: environment.captionSize,
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
                let view: UIKitMessageTextView
                if let textView {
                    view = textView
                } else {
                    view = UIKitMessageTextView(geometry: geometry)
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
                        metadata: localFrames[.media] == nil ? presentation.metadata : nil,
                        failureAction: failureAction, geometry: geometry,
                        fontSize: environment.bodySize
                    ), resetSelection: resetSelection)
            } else {
                textView?.clear()
                textView?.isHidden = true
            }
            if localFrames[.metadata] != nil, let metadata = presentation.metadata {
                let view = metadataView ?? makeMetadata()
                view.isHidden = false
                view.configure(
                    metadata, overlay: presentation.metadataIsOverlay && localFrames[.media] != nil,
                    failureAction: failureAction)
                // A reused cell may create its media section after this view.
                sections.bringSubviewToFront(view)
            } else {
                metadataView?.clear()
                metadataView?.isHidden = true
            }
            if localFrames[.standalone] != nil, let text = presentation.standaloneText {
                let view = standaloneView ?? makeStandalone()
                view.isHidden = false
                view.configure(
                    text: text, deleted: row.entry.remoteMessage?.isDeleted == true,
                    outgoing: row.isOutgoing && isFilled, fontSize: environment.bodySize,
                    symbolSize: binding.layout.standaloneSymbolSize,
                    gap: binding.layout.standaloneLabelGap)
            } else {
                standaloneView?.clear()
                standaloneView?.isHidden = true
            }
            updateAccessibilityActions()
            updateSurface()
            setNeedsLayout()
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
            accessibilityCustomActions = nil
            surface.path = nil
            sectionMask.path = nil
            surfaceGeometry = nil
        }

        func setVisible(_ visible: Bool) {
            guard self.visible != visible else { return }
            self.visible = visible
            mediaView?.setVisible(visible && mediaView?.isHidden == false)
            if !visible, let controller = voiceController {
                // UIKit hosting configuration may be updated in a SwiftUI view pass.
                DispatchQueue.main.async { [weak self, weak controller] in
                    guard let self, !self.visible, self.voiceController === controller else {
                        return
                    }
                    controller?.stop()
                }
            }
            configureAudio()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { setVisible(false) }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Only translate the row's cached rectangles into bubble coordinates.
            // Preview hosts can assign bubble-only bounds without resizing the row.
            sections.frame = bounds
            headerView?.frame = localFrames[.title] ?? .zero
            replyView?.frame = localFrames[.reply] ?? .zero
            mediaView?.frame = localFrames[.media] ?? .zero
            voiceView?.frame = localFrames[.audio] ?? .zero
            textView?.frame = localFrames[.text] ?? .zero
            metadataView?.frame = localFrames[.metadata] ?? .zero
            standaloneView?.frame = localFrames[.standalone] ?? .zero
            updateSurface()
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard !isHidden, alpha > 0, isUserInteractionEnabled,
                self.point(inside: point, with: event)
            else { return nil }
            // The retry symbol is measured inside metadata, but its 44-point target
            // may extend beyond that section. Do not enlarge the cached section.
            if let metadataView, !metadataView.isHidden,
                let target = metadataView.hitTestFailureButton(
                    metadataView.convert(point, from: self), with: event)
            {
                return target
            }
            return super.hitTest(point, with: event)
        }

        /// The row's swipe/hold recognizer must yield to the shared control's gestures.
        func ownsVoiceTouch(_ touch: UITouch) -> Bool {
            guard visible, binding?.context.isInteractionPreview == false,
                let frame = localFrames[.audio]
            else { return false }
            return frame.contains(touch.location(in: self))
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
            let dark = traitCollection.userInterfaceStyle == .dark
            let color =
                row.isOutgoing
                ? ChahuaTheme.ChatBubble.outgoingBackground
                : ChahuaTheme.ChatBubble.incomingBackground(for: dark ? .dark : .light)
            surface.fillColor = UIColor(color).resolvedColor(with: traitCollection).cgColor
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
                guard let binding = self?.binding, let reply = binding.presentation.reply else {
                    return
                }
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
            // Exception to native timeline sections: the existing UIKit timeline must
            // retain measured row geometry, but playback/seek is one shared SwiftUI
            // control. UIHostingConfiguration bridges only audio, not an entire row.
            let configuration = UIHostingConfiguration {
                VoiceMessageBubbleView(
                    controller: controller, url: binding.presentation.audioURL,
                    isOutgoing: row.isOutgoing,
                    isActive: visible && !binding.context.isInteractionPreview,
                    metrics: binding.presentation.voiceMetrics,
                    localeIdentifier: environment.localeIdentifier,
                    layoutDirection: environment.layoutDirection)
            }.margins(.all, 0)
            if let voiceView {
                voiceView.configuration = configuration
            } else {
                let view = configuration.makeContentView()
                view.backgroundColor = .clear
                sections.addSubview(view)
                voiceView = view
            }
        }

        private func clearAudio() {
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

        private func updateAccessibilityActions() {
            headerView?.accessibilityCustomActions = accessibilityCustomActions
            replyView?.accessibilityCustomActions = accessibilityCustomActions
            mediaView?.accessibilityCustomActions = accessibilityCustomActions
            textView?.rowAccessibilityActions = accessibilityCustomActions
            metadataView?.rowAccessibilityActions = accessibilityCustomActions
            standaloneView?.accessibilityCustomActions = accessibilityCustomActions
        }
    }

    /// Labels draw in assigned engine rectangles; no intrinsic sizing or constraints.
    private final class BubbleLabel: UILabel {
        init() {
            super.init(frame: .zero)
            numberOfLines = 1
            lineBreakMode = .byTruncatingTail
            isAccessibilityElement = false
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { nil }
    }

    @MainActor
    private final class TimelineHeaderView: UIView {
        private let name = BubbleLabel()
        private let group = BubbleLabel()
        private let gender = BubbleLabel()
        private let groupSurface = CALayer()
        private var title: TitleContent?
        private var row: TimelineMessageRow?
        private var itemFrames: [CGRect] = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            groupSurface.cornerRadius = 2
            groupSurface.actions = [
                "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(),
            ]
            layer.addSublayer(groupSurface)
            addSubview(name)
            addSubview(group)
            addSubview(gender)
            isAccessibilityElement = true
            accessibilityTraits = .staticText
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
                (view: TimelineHeaderView, _: UITraitCollection) in
                view.updateColors()
            }
        }

        required init?(coder: NSCoder) { nil }

        func configure(
            title: TitleContent, row: TimelineMessageRow, fontSize: CGFloat, frames: [CGRect]
        ) {
            self.title = title
            self.row = row
            itemFrames = frames
            name.text = title.name
            name.font = .systemFont(ofSize: fontSize, weight: .semibold)
            group.text = title.groupName ?? ""
            group.font = .systemFont(ofSize: fontSize)
            gender.text = title.genderGlyph ?? ""
            gender.font = .systemFont(ofSize: fontSize)
            group.isHidden = title.groupName == nil || frames.count < 2 || frames[1].isEmpty
            groupSurface.isHidden = group.isHidden
            gender.isHidden = title.genderGlyph == nil || frames.count < 3 || frames[2].isEmpty
            accessibilityLabel = [title.name, title.groupName, title.genderGlyph].compactMap { $0 }
                .joined(separator: " ")
            updateColors()
            setNeedsLayout()
        }

        func clear() {
            title = nil
            row = nil
            itemFrames.removeAll(keepingCapacity: true)
            name.text = nil
            group.text = nil
            gender.text = nil
            accessibilityLabel = nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            name.frame = itemFrames.first ?? .zero
            let groupFrame = itemFrames.count > 1 ? itemFrames[1] : .zero
            groupSurface.frame = groupFrame
            group.frame = groupFrame.insetBy(dx: min(5, groupFrame.width / 2), dy: 0)
            gender.frame = itemFrames.count > 2 ? itemFrames[2] : .zero
        }

        private func updateColors() {
            guard let row, let title else { return }
            let dark = traitCollection.userInterfaceStyle == .dark
            name.textColor =
                row.isOutgoing
                ? .white
                : UIColor(bubbleColorForUser(uid: row.entry.senderID, dark: dark))
                    .withAlphaComponent(0.85)
            group.textColor = UIColor.white.withAlphaComponent(0.85)
            var color = UIColor.gray.withAlphaComponent(0.44)
            if let info = title.userGroup {
                let darkHex = info.chatGroupColorDark.flatMap { $0.isEmpty ? nil : $0 }
                if let hex = dark ? darkHex ?? info.chatGroupColor : info.chatGroupColor,
                    let value = bubbleColor(hex: hex)
                {
                    color = UIColor(value)
                }
            }
            let resolved = color.resolvedColor(with: traitCollection)
            groupSurface.backgroundColor =
                resolved.withAlphaComponent(resolved.cgColor.alpha * 0.85).cgColor
            gender.textColor =
                title.genderGlyph.flatMap { bubbleColor(hex: $0 == "♂" ? "3cb4f0" : "ff8080") }.map
            { UIColor($0) } ?? .label
        }
    }

    @MainActor
    private final class TimelineReplyView: UIControl {
        var onActivate: (() -> Void)?
        private let author = BubbleLabel()
        private let previewLabel = BubbleLabel()
        private let stripe = CALayer()
        private let marker = MessageRowGestureMarker(frame: .zero)
        private var preview: MessagePreview?
        private var outgoing = false
        private var filled = false
        private var contentFrames: [CGRect] = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.cornerRadius = 6
            clipsToBounds = true
            stripe.actions = [
                "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(),
            ]
            layer.addSublayer(stripe)
            addSubview(author)
            addSubview(previewLabel)
            marker.frame = bounds
            marker.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(marker)
            addTarget(self, action: #selector(activate), for: .touchUpInside)
            isAccessibilityElement = true
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
                (view: TimelineReplyView, _: UITraitCollection) in
                view.updateColors()
            }
        }

        required init?(coder: NSCoder) { nil }

        func configure(
            _ preview: MessagePreview, outgoing: Bool, filled: Bool, fontSize: CGFloat,
            frames: [CGRect], enabled: Bool
        ) {
            self.preview = preview
            self.outgoing = outgoing
            self.filled = filled
            contentFrames = frames
            author.text =
                preview.sender.name.flatMap { $0.isEmpty ? nil : $0 }
                ?? "User \(preview.sender.uid)"
            author.font = .systemFont(ofSize: fontSize * 11 / 12, weight: .semibold)
            previewLabel.text = messagePreview(preview)
            previewLabel.font = .systemFont(ofSize: fontSize)
            isEnabled = enabled
            accessibilityTraits = isEnabled ? .button : .staticText
            accessibilityLabel = "\(author.text ?? ""), \(previewLabel.text ?? "")"
            if isEnabled {
                marker.configure(.tap { [weak self] in self?.activate() })
            } else {
                marker.stop()
            }
            updateColors()
            setNeedsLayout()
        }

        func clear() {
            preview = nil
            contentFrames.removeAll(keepingCapacity: true)
            author.text = nil
            previewLabel.text = nil
            isEnabled = false
            accessibilityLabel = nil
            marker.stop()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            stripe.frame = CGRect(x: 0, y: 0, width: min(3, bounds.width), height: bounds.height)
            author.frame = contentFrames.first ?? .zero
            previewLabel.frame = contentFrames.count > 1 ? contentFrames[1] : .zero
        }

        @objc private func activate() {
            guard isEnabled, preview != nil else { return }
            onActivate?()
        }

        override func accessibilityActivate() -> Bool {
            guard isEnabled else { return false }
            activate()
            return true
        }

        private func updateColors() {
            guard let preview else { return }
            let dark = traitCollection.userInterfaceStyle == .dark
            let color =
                outgoing && filled
                ? UIColor.white : UIColor(bubbleColorForUser(uid: preview.sender.uid, dark: dark))
            author.textColor = color.withAlphaComponent(0.85)
            previewLabel.textColor = color.withAlphaComponent(0.7)
            backgroundColor = (outgoing && filled ? UIColor.black : color).withAlphaComponent(0.1)
            stripe.backgroundColor =
                color.withAlphaComponent(outgoing ? 0.5 : 1).resolvedColor(with: traitCollection)
                .cgColor
        }
    }

    @MainActor
    private final class TimelineMetadataView: UIView {
        var rowAccessibilityActions: [UIAccessibilityCustomAction]? {
            didSet { updateAccessibilityActions() }
        }
        private var metadata: MessageMetadata?
        private var overlay = false
        private var failureAction: (() -> Void)?
        private var failureButton: TimelineFailureButton?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            contentMode = .redraw
            layer.masksToBounds = true
            isAccessibilityElement = true
            accessibilityTraits = .staticText
            registerForTraitChanges([
                UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self,
                UITraitUserInterfaceLevel.self, UITraitDisplayGamut.self, UITraitDisplayScale.self,
            ]) { (view: TimelineMetadataView, _: UITraitCollection) in
                view.setNeedsDisplay()
            }
        }

        required init?(coder: NSCoder) { nil }

        func configure(_ metadata: MessageMetadata, overlay: Bool, failureAction: (() -> Void)?) {
            self.metadata = metadata
            self.overlay = overlay
            self.failureAction = failureAction
            backgroundColor = overlay ? UIColor.black.withAlphaComponent(0.45) : .clear
            accessibilityLabel = metadata.accessibilityLabel
            if metadata.state == .failed, failureAction != nil {
                let button: TimelineFailureButton
                if let failureButton {
                    button = failureButton
                } else {
                    button = TimelineFailureButton(frame: .zero)
                    button.isAccessibilityElement = false
                    button.onActivate = { [weak self] in self?.openFailure() }
                    addSubview(button)
                    self.failureButton = button
                }
                button.configure(symbol: metadata.symbol)
                button.isHidden = false
                // Keep timestamp and status together, with retry available on the
                // same element even when the drawn symbol is too small to target.
                accessibilityTraits = .button
                accessibilityHint = String(localized: "Failed to send. Retry options")
            } else {
                failureButton?.clear()
                failureButton?.isHidden = true
                accessibilityTraits = .staticText
                accessibilityHint = nil
            }
            updateAccessibilityActions()
            setNeedsLayout()
            setNeedsDisplay()
        }

        func clear() {
            metadata = nil
            failureAction = nil
            failureButton?.clear()
            failureButton?.isHidden = true
            accessibilityLabel = nil
            accessibilityHint = nil
            rowAccessibilityActions = nil
            accessibilityTraits = .staticText
            setNeedsDisplay()
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

        override func layoutSubviews() {
            super.layoutSubviews()
            layer.cornerRadius = overlay ? min(bounds.width, bounds.height) / 2 : 0
            failureButton?.setSymbolFrame(metadata?.symbolFrame(in: drawingFrame) ?? .zero)
        }

        func hitTestFailureButton(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard let failureButton, !failureButton.isHidden else { return nil }
            return failureButton.hitTest(failureButton.convert(point, from: self), with: event)
        }

        private func updateAccessibilityActions() {
            var actions = rowAccessibilityActions ?? []
            if metadata?.state == .failed, failureAction != nil {
                actions.append(
                    UIAccessibilityCustomAction(
                        name: String(localized: "Failed to send. Retry options"),
                        target: self, selector: #selector(performAccessibleFailureAction)
                    ))
            }
            accessibilityCustomActions = actions.isEmpty ? nil : actions
        }

        override func draw(_ rect: CGRect) {
            super.draw(rect)
            metadata?.draw(in: drawingFrame, drawsSymbol: failureButton?.isHidden != false)
        }

        @objc private func openFailure() {
            guard metadata?.state == .failed else { return }
            failureAction?()
        }

        @objc private func performAccessibleFailureAction() -> Bool {
            guard metadata?.state == .failed, failureAction != nil else { return false }
            openFailure()
            return true
        }

        override func accessibilityActivate() -> Bool { performAccessibleFailureAction() }
    }

    @MainActor
    private final class BubbleStandaloneView: UIView {
        private var text = ""
        private var deleted = false
        private var outgoing = false
        private var fontSize: CGFloat = 17
        private var symbolSize: CGSize = .zero
        private var gap: CGFloat = 0
        private var attributed = NSAttributedString(string: "")
        private var symbol: UIImage?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            contentMode = .redraw
            isAccessibilityElement = true
            accessibilityTraits = .staticText
            clipsToBounds = true
            registerForTraitChanges([
                UITraitUserInterfaceStyle.self, UITraitDisplayScale.self,
                UITraitLayoutDirection.self,
            ]) { (view: BubbleStandaloneView, _: UITraitCollection) in
                view.updatePaint()
            }
        }

        required init?(coder: NSCoder) { nil }

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
            accessibilityLabel = text
            updatePaint()
        }

        func clear() {
            text = ""
            attributed = NSAttributedString(string: "")
            symbol = nil
            accessibilityLabel = nil
            setNeedsDisplay()
        }

        private func updatePaint() {
            let dark = traitCollection.userInterfaceStyle == .dark
            let foreground = UIColor(
                outgoing
                    ? ChahuaTheme.ChatBubble.outgoingForeground
                    : ChahuaTheme.ChatBubble.incomingForeground(for: dark ? .dark : .light))
            let font =
                deleted
                ? UIFont.italicSystemFont(ofSize: fontSize) : UIFont.systemFont(ofSize: fontSize)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            attributed = NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: foreground, .paragraphStyle: paragraph])
            let configuration = UIImage.SymbolConfiguration(pointSize: fontSize, weight: .regular)
                .applying(UIImage.SymbolConfiguration(paletteColors: [foreground]))
            symbol =
                deleted
                ? nil
                : UIImage(
                    systemName: "questionmark.square.dashed", withConfiguration: configuration)
            setNeedsDisplay()
        }

        override func draw(_ rect: CGRect) {
            super.draw(rect)
            let offset = deleted ? 0 : symbolSize.width + gap
            symbol?.draw(in: CGRect(origin: .zero, size: symbolSize))
            attributed.draw(
                with: CGRect(
                    x: offset, y: 0, width: max(0, bounds.width - offset), height: bounds.height),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
    }

    /// The same circular corners and droplet as the macOS native bubble surface.
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
