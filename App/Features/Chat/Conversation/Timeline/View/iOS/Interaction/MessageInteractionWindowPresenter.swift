#if os(iOS)
    import ChahuaAPI
    import SwiftUI
    import UIKit

    /// Explicit data/callback boundary: no view builder or rendered SwiftUI content crosses it.
    struct MessageInteractionPresentation {
        let row: TimelineMessageRow
        let context: MessageInteractionContext
        let currentUserID: Int32
        let source: MessageInteractionSource
        let mediaContext: AppMediaContext?
        let actions: TimelineBubbleActions
        let interfaceStyle: UIUserInterfaceStyle
        let onBlock: (PendingOutgoingMessage) -> Void
        let onRevoke: (PendingOutgoingMessage) -> Void
        let isReacting: Bool
        let onReaction: (String) -> Void
        let onAction: (MessageMenuAction) -> Void
        let onClose: () -> Void

        var eligibility: MessageReactionEligibility {
            .init(
                canReact: MessageActionPolicy(row: row, context: context).canReact
                    && actions.toggleReaction != nil, isReacting: isReacting,
                reactions: row.entry.remoteMessage?.reactions ?? [])
        }
    }

    /// UIKit owns the full-window interaction because the custom reaction/action layout
    /// cannot use UIContextMenuInteraction, and a timeline overlay stops below chrome.
    /// Keep the originating window/key responder ownership; never reparent a reusable row.
    struct MessageInteractionWindowPresenter: UIViewRepresentable {
        let presentation: MessageInteractionPresentation?
        let reduceMotion: Bool

        func makeCoordinator() -> Coordinator { Coordinator() }
        func makeUIView(context: Context) -> MessageInteractionWindowAnchor {
            let anchor = MessageInteractionWindowAnchor()
            anchor.isUserInteractionEnabled = false
            anchor.windowChanged = { [weak coordinator = context.coordinator] in
                coordinator?.attach(to: $0)
            }
            return anchor
        }
        func updateUIView(_ view: MessageInteractionWindowAnchor, context: Context) {
            context.coordinator.presentation = presentation
            context.coordinator.reduceMotion = reduceMotion
            context.coordinator.attach(to: view.window)
        }
        static func dismantleUIView(
            _ view: MessageInteractionWindowAnchor, coordinator: Coordinator
        ) {
            view.windowChanged = nil
            coordinator.remove()
        }

        @MainActor final class Coordinator {
            var presentation: MessageInteractionPresentation?
            var reduceMotion = false
            private weak var window: UIWindow?
            private var controller: MessageInteractionViewController?
            private var feedback: MessageBubblePressFeedback?
            private var dismissing = false

            func attach(to window: UIWindow?) {
                guard let window else {
                    remove()
                    return
                }
                if self.window !== window { remove() }
                self.window = window
                guard let presentation else {
                    dismiss()
                    return
                }
                if let controller {
                    guard !dismissing else { return }
                    if controller.presentation.row.entry.stableKey
                        != presentation.row.entry.stableKey
                    {
                        remove()
                        attach(to: window)
                    } else {
                        controller.update(presentation)
                    }
                    return
                }
                let controller = MessageInteractionViewController(
                    presentation: presentation, reduceMotion: reduceMotion)
                controller.loadViewIfNeeded()
                controller.view.frame = window.bounds
                controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                // This is a window sibling, not a child of the root controller's view.
                // Explicit appearance transitions keep containment and media lifetime honest.
                controller.beginAppearanceTransition(true, animated: false)
                window.addSubview(controller.view)
                controller.endAppearanceTransition()
                self.controller = controller
                feedback = presentation.source.pressFeedback
                controller.mount(
                    scale: reduceMotion ? 1 : feedback?.scale ?? 1,
                    opacity: feedback?.opacity ?? (reduceMotion ? 0 : 1))
                feedback?.handOff()
                controller.becomeFirstResponder()
                controller.enter()
            }
            private func dismiss() {
                guard let controller, !dismissing else { return }
                dismissing = true
                controller.leave { [weak self, weak controller] in
                    guard let self, self.controller === controller else { return }
                    let window = self.window
                    self.remove()
                    UIAccessibility.post(notification: .screenChanged, argument: nil)
                    if self.presentation != nil { self.attach(to: window) }
                }
            }
            func remove() {
                controller?.cleanup()
                controller?.beginAppearanceTransition(false, animated: false)
                controller?.view.removeFromSuperview()
                controller?.endAppearanceTransition()
                controller = nil
                feedback?.restore()
                feedback = nil
                dismissing = false
                window = nil
            }
        }
    }

    final class MessageInteractionWindowAnchor: UIView {
        var windowChanged: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            windowChanged?(window)
        }
    }

    /// A separately constructed native preview retains the captured measurement and
    /// typography, but live action policy/callbacks still come from the current row.
    @MainActor final class MessageInteractionViewController: UIViewController {
        private(set) var presentation: MessageInteractionPresentation
        var onClose: (() -> Void)?
        private let reduceMotion: Bool
        private let backdrop = UIVisualEffectView(
            effect: UIBlurEffect(style: .systemUltraThinMaterial))
        private let dim = UIControl()
        private let previewViewport = UIView()
        private let previewClip = UIView()
        private let preview = TimelineRowView(frame: .zero)
        private let reactions = MessageInteractionSurface(radius: 26)
        private let reactionStack = UIStackView()
        private let actionsScroll = UIScrollView()
        private let actionStack = UIStackView()
        private let placeholder = UIView()
        private var emojiPicker: NativeReactionEmojiKeyboard?
        private let pickerOutside = UIControl()
        private let pickerSurface = MessageInteractionSurface(radius: 24)
        private let pickerArrow = UIImageView(image: UIImage(systemName: "arrowtriangle.down.fill"))
        private let cache = TimelineLayoutCache()
        private var bubbleSize = CGSize.zero
        private var keyboardFrame = CGRect.zero
        private var entered = false
        private var exiting = false
        private var initialScale: CGFloat = 1
        private var actionHeight: CGFloat = 0
        private var animation: UIViewPropertyAnimator?
        private var settle: DispatchWorkItem?
        private var preferenceObserver: NSObjectProtocol?

        init(presentation: MessageInteractionPresentation, reduceMotion: Bool) {
            self.presentation = presentation
            self.reduceMotion = reduceMotion
            super.init(nibName: nil, bundle: nil)
            onClose = presentation.onClose
        }
        required init?(coder: NSCoder) { nil }
        override func loadView() {
            view = UIView()
            view.accessibilityViewIsModal = true
            view.backgroundColor = .clear
            view.tintColor = UIColor(ChahuaTheme.accent)
            view.addSubview(backdrop)
            backdrop.contentView.addSubview(dim)
            dim.backgroundColor = UIColor.black.withAlphaComponent(0.24)
            dim.addTarget(self, action: #selector(close), for: .touchUpInside)
            dim.isAccessibilityElement = true
            dim.accessibilityTraits = .button
            dim.accessibilityLabel = AppLanguage.localized("Dismiss message actions")
            previewClip.clipsToBounds = true
            previewViewport.accessibilityElementsHidden = true
            previewViewport.layer.shadowColor = UIColor.black.cgColor
            previewViewport.layer.shadowOpacity = 0.24
            previewViewport.layer.shadowRadius = 18
            previewViewport.layer.shadowOffset = CGSize(width: 0, height: 10)
            view.addSubview(previewViewport)
            previewViewport.addSubview(previewClip)
            previewClip.addSubview(preview)
            view.addSubview(reactions)
            reactionStack.axis = .horizontal
            reactionStack.spacing = 2
            reactionStack.distribution = .fillEqually
            reactions.content.addSubview(reactionStack)
            view.addSubview(actionsScroll)
            actionsScroll.showsVerticalScrollIndicator = false
            actionStack.axis = .vertical
            actionStack.spacing = 8
            actionsScroll.addSubview(actionStack)
            view.addSubview(placeholder)
            placeholder.isHidden = true
            placeholder.accessibilityLabel = AppLanguage.localized("Choose a reaction")
            placeholder.accessibilityIdentifier = "reaction-emoji-placeholder"
            let smileSurface = MessageInteractionSurface(radius: 32)
            smileSurface.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
            placeholder.addSubview(smileSurface)
            let smile = UIImageView(image: UIImage(systemName: "face.smiling"))
            smile.preferredSymbolConfiguration = .init(pointSize: 34, weight: .light)
            smile.tintColor = .secondaryLabel
            smile.contentMode = .center
            smile.frame = smileSurface.bounds
            smileSurface.content.addSubview(smile)
            for frame in [
                CGRect(x: 49, y: 56, width: 14, height: 14),
                CGRect(x: 64, y: 70, width: 6, height: 6),
            ] {
                let dot = MessageInteractionSurface(radius: frame.width / 2)
                dot.frame = frame
                placeholder.addSubview(dot)
            }
            let closeSurface = MessageInteractionSurface(radius: 14)
            closeSurface.frame = CGRect(x: 48, y: 0, width: 28, height: 28)
            placeholder.addSubview(closeSurface)
            let closeButton = UIButton(type: .system)
            closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
            closeButton.setPreferredSymbolConfiguration(
                .init(pointSize: 10, weight: .bold), forImageIn: .normal)
            closeButton.tintColor = .label
            closeButton.accessibilityLabel = AppLanguage.localized("Close emoji picker")
            closeButton.accessibilityIdentifier = "reaction-emoji-close"
            closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
            closeButton.frame = closeSurface.bounds
            closeSurface.content.addSubview(closeButton)
            pickerOutside.addTarget(self, action: #selector(close), for: .touchUpInside)
            pickerOutside.isHidden = true
            view.addSubview(pickerOutside)
            view.addSubview(pickerSurface)
            view.addSubview(pickerArrow)
            pickerSurface.isHidden = true
            pickerArrow.isHidden = true
            pickerArrow.tintColor = .secondarySystemBackground
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardChanged(_:)),
                name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardChanged(_:)),
                name: UIResponder.keyboardWillHideNotification, object: nil)
            preferenceObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuildControls() }
            }
            registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
                (controller: MessageInteractionViewController, _) in
                controller.rebuildControls()
            }
            update(presentation)
        }
        override func viewSafeAreaInsetsDidChange() {
            super.viewSafeAreaInsetsDidChange()
            view.setNeedsLayout()
        }
        override var canBecomeFirstResponder: Bool { true }
        override var keyCommands: [UIKeyCommand]? {
            [
                UIKeyCommand(
                    input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close))
            ]
        }
        override func accessibilityPerformEscape() -> Bool {
            close()
            return true
        }
        @objc private func close() { onClose?() }
        func update(_ value: MessageInteractionPresentation) {
            presentation = value
            onClose = value.onClose
            guard isViewLoaded else { return }
            overrideUserInterfaceStyle = value.interfaceStyle
            view.semanticContentAttribute =
                value.source.presentation.environment.layoutDirection == .rightToLeft
                ? .forceRightToLeft : .forceLeftToRight
            let prepared =
                value.source.presentation.row == .message(value.row)
                ? value.source.presentation
                : TimelineRowPresentation.make(
                    row: .message(value.row),
                    currentUserID: value.currentUserID,
                    isThreadTimeline: value.context.isThreadView,
                    environment: value.source.presentation.environment)
            let layout =
                prepared.layoutKey == value.source.presentation.layoutKey
                ? value.source.layout
                : cache.layout(for: prepared, environment: value.source.presentation.environment)
            bubbleSize = layout.frames[.bubble]?.size ?? value.source.rect.size
            let binding = TimelineRowBinding(
                presentation: prepared, layout: layout,
                context: .init(
                    currentUserID: value.currentUserID,
                    isThreadTimeline: value.context.isThreadView, isInteractionPreview: true),
                actions: value.actions, mediaContext: value.mediaContext)
            if preview.binding.map({ !$0.hasSameRendering(as: binding) }) ?? true {
                preview.bind(binding)
            }
            emojiPicker?.eligibility = value.eligibility
            if emojiPicker != nil && !value.eligibility.canReact { close() }
            rebuildControls()
        }
        private func rebuildControls() {
            guard isViewLoaded else { return }
            for item in reactionStack.arrangedSubviews { item.removeFromSuperview() }
            for item in actionStack.arrangedSubviews { item.removeFromSuperview() }
            for item in reactionStack.subviews where item is UIActivityIndicatorView {
                item.removeFromSuperview()
            }
            let value = presentation
            let policy = MessageActionPolicy(row: value.row, context: value.context)
            let recent =
                UserDefaults.standard.string(forKey: MessageReactionPreferences.recentStorageKey)
                ?? MessageReactionPreferences.defaultRecentStorage
            for emoji in MessageReactionPreferences.quick(from: recent) {
                let button = UIButton(type: .system)
                button.setTitle(emoji, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 24)
                let selected = value.eligibility.isSelected(emoji)
                button.backgroundColor = selected ? view.tintColor.withAlphaComponent(0.18) : .clear
                button.layer.cornerRadius = 22
                button.isEnabled = value.eligibility.canToggle(emoji)
                button.alpha = button.isEnabled ? 1 : 0.4
                button.accessibilityLabel = AppLanguage.localized(
                    selected ? "Remove reaction: \(emoji)" : "React with: \(emoji)")
                if selected { button.accessibilityTraits.insert(.selected) }
                button.addAction(
                    UIAction { [weak self] _ in self?.react(emoji) }, for: .touchUpInside)
                reactionStack.addArrangedSubview(button)
            }
            let more = UIButton(type: .system)
            more.setImage(UIImage(systemName: "plus"), for: .normal)
            more.tintColor = .label
            more.setPreferredSymbolConfiguration(
                .init(pointSize: 21, weight: .medium), forImageIn: .normal)
            more.isEnabled = !value.isReacting && value.actions.toggleReaction != nil
            more.alpha = more.isEnabled ? 1 : 0.4
            more.accessibilityLabel = AppLanguage.localized("More reactions")
            more.accessibilityIdentifier = "more-reactions"
            more.addAction(
                UIAction { [weak self] _ in self?.showEmojiPicker() }, for: .touchUpInside)
            reactionStack.addArrangedSubview(more)
            if value.isReacting {
                let progress = UIActivityIndicatorView(style: .medium)
                progress.center = CGPoint(x: 138, y: 26)
                progress.accessibilityLabel = AppLanguage.localized("Updating reaction")
                progress.startAnimating()
                reactionStack.addSubview(progress)
            }
            let menuActions = policy.actions
            let rowHeight = max(63, UIFontMetrics(forTextStyle: .caption2).scaledValue(for: 63))
            if !menuActions.isEmpty {
                let surface = MessageInteractionSurface(radius: 14)
                let grid = UIStackView()
                grid.axis = .vertical
                grid.spacing = 0
                surface.content.addSubview(grid)
                grid.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    grid.leadingAnchor.constraint(equalTo: surface.content.leadingAnchor),
                    grid.trailingAnchor.constraint(equalTo: surface.content.trailingAnchor),
                    grid.topAnchor.constraint(equalTo: surface.content.topAnchor),
                    grid.bottomAnchor.constraint(equalTo: surface.content.bottomAnchor),
                ])
                for start in stride(from: 0, to: menuActions.count, by: 5) {
                    if start > 0 {
                        let line = UIView()
                        line.backgroundColor = .separator
                        line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale)
                            .isActive = true
                        grid.addArrangedSubview(line)
                    }
                    let row = UIStackView()
                    row.distribution = .fillEqually
                    for offset in 0..<5 {
                        if start + offset < menuActions.count {
                            let action = menuActions[start + offset]
                            var config = UIButton.Configuration.plain()
                            config.image = UIImage(systemName: action.symbol)
                            config.preferredSymbolConfigurationForImage = .init(pointSize: 22)
                            config.imagePlacement = .top
                            config.imagePadding = 4
                            config.contentInsets = .init(top: 5, leading: 3, bottom: 5, trailing: 3)
                            let title =
                                action == .save && value.context.isSaved
                                ? AppLanguage.localized("Remove Saved Message")
                                : action.label(
                                    hasAttachments: value.row.entry.remoteMessage?.hasAttachments
                                        == true)
                            config.title = title
                            config.titleTextAttributesTransformer =
                                UIConfigurationTextAttributesTransformer { incoming in
                                    var outgoing = incoming
                                    outgoing.font = .preferredFont(forTextStyle: .caption2)
                                    return outgoing
                                }
                            config.titleAlignment = .center
                            config.baseForegroundColor = action == .delete ? .systemRed : .label
                            let button = UIButton(configuration: config)
                            button.titleLabel?.numberOfLines = 2
                            button.isEnabled = policy.availability(of: action) == .enabled
                            button.alpha = button.isEnabled ? 1 : 0.4
                            button.accessibilityLabel = title
                            button.accessibilityHint =
                                button.isEnabled
                                ? nil : AppLanguage.localized("Not implemented yet")
                            button.addAction(
                                UIAction { [weak self] _ in
                                    guard let self else { return }
                                    self.presentation.onAction(action)
                                    self.close()
                                }, for: .touchUpInside)
                            row.addArrangedSubview(button)
                        } else {
                            row.addArrangedSubview(UIView())
                        }
                    }
                    row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
                    grid.addArrangedSubview(row)
                }
                surface.heightAnchor.constraint(
                    equalToConstant:
                        CGFloat((menuActions.count + 4) / 5) * rowHeight
                        + CGFloat(max(0, (menuActions.count + 4) / 5 - 1)) / UIScreen.main.scale
                ).isActive = true
                actionStack.addArrangedSubview(surface)
            }
            if case .pending(let pending) = value.row.entry, !pending.dispatchClaimed,
                value.actions.modifiablePendingMessageIDs.contains(pending.clientGeneratedID)
            {
                let surface = MessageInteractionSurface(radius: 14)
                let stack = UIStackView()
                stack.axis = .vertical
                surface.content.addSubview(stack)
                stack.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: surface.content.leadingAnchor),
                    stack.trailingAnchor.constraint(equalTo: surface.content.trailingAnchor),
                    stack.topAnchor.constraint(equalTo: surface.content.topAnchor),
                    stack.bottomAnchor.constraint(equalTo: surface.content.bottomAnchor),
                ])
                for revoke in [false, true] {
                    let title: String.LocalizationValue =
                        revoke ? "Revoke unsent message" : "Move back to composer"
                    var config = UIButton.Configuration.plain()
                    config.title = AppLanguage.localized(title)
                    config.image = UIImage(systemName: revoke ? "trash" : "square.and.pencil")
                    config.imagePadding = 8
                    config.baseForegroundColor = revoke ? .systemRed : .label
                    let button = UIButton(configuration: config)
                    button.isEnabled =
                        revoke
                        ? value.actions.revokePendingMessage != nil
                        : value.actions.blockPendingMessage != nil
                            && [.text, .file].contains(pending.body.messageType)
                    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
                    button.addAction(
                        UIAction { [weak self] _ in
                            guard let self else { return }
                            if revoke {
                                self.presentation.onRevoke(pending)
                            } else {
                                self.presentation.onBlock(pending)
                            }
                        }, for: .touchUpInside)
                    stack.addArrangedSubview(button)
                    if !revoke {
                        let divider = UIView()
                        divider.backgroundColor = .separator
                        divider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale)
                            .isActive = true
                        stack.addArrangedSubview(divider)
                    }
                }
                surface.heightAnchor.constraint(equalToConstant: 88 + 1 / UIScreen.main.scale)
                    .isActive = true
                actionStack.addArrangedSubview(surface)
            }
            view.setNeedsLayout()
        }
        private func react(_ emoji: String) {
            guard presentation.eligibility.canToggle(emoji) else { return }
            if !presentation.eligibility.isSelected(emoji) {
                let key = MessageReactionPreferences.recentStorageKey
                let recent =
                    UserDefaults.standard.string(forKey: key)
                    ?? MessageReactionPreferences.defaultRecentStorage
                UserDefaults.standard.set(
                    MessageReactionPreferences.recording(emoji, in: recent), forKey: key)
            }
            presentation.onReaction(emoji)
            close()
        }
        private func showEmojiPicker() {
            guard emojiPicker == nil, !presentation.isReacting, presentation.eligibility.canReact
            else { return }
            let picker = NativeReactionEmojiKeyboard(eligibility: presentation.eligibility)
            picker.onSelect = { [weak self] in self?.react($0) }
            emojiPicker = picker
            pickerSurface.content.addSubview(picker)
            dim.accessibilityLabel = AppLanguage.localized("Dismiss emoji picker")
            view.setNeedsLayout()
            let changes = { self.view.layoutIfNeeded() }
            UIView.animate(withDuration: reduceMotion ? 0.15 : 0.25, animations: changes)
            UIAccessibility.post(notification: .layoutChanged, argument: picker)
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            backdrop.frame = view.bounds
            dim.frame = backdrop.bounds
            let insets = view.safeAreaInsets
            let safe = view.bounds.inset(by: insets)
            var bottom = safe.maxY
            if !keyboardFrame.isEmpty, let window = view.window {
                let local = view.convert(window.convert(keyboardFrame, from: nil), from: window)
                if local.maxY >= view.bounds.maxY - 1, local.intersects(view.bounds) {
                    bottom = min(bottom, local.minY)
                }
            }
            let isPad = UIDevice.current.userInterfaceIdiom == .pad
            let picking = emojiPicker != nil
            let dockBottom = bottom == safe.maxY ? view.bounds.maxY : bottom
            let keyboardPadding = bottom == safe.maxY ? max(16, insets.bottom) : 16
            let keyboardHeight = min(
                min(300, max(160, view.bounds.height * 0.42)),
                max(1, dockBottom - safe.minY - keyboardPadding))
            let pickerSize = CGSize(
                width: min(360, max(1, safe.width - 32)),
                height: min(
                    max(1, bottom - safe.minY - 108),
                    min(360, max(160, bottom - safe.minY - min(bubbleSize.height, 120) - 140))))
            let popoverSpace = picking && isPad ? pickerSize.height + 16 : 0
            let dockSpace =
                picking && !isPad
                ? max(0, bottom - (dockBottom - keyboardHeight - keyboardPadding)) + 12 : 0
            let bounds = CGRect(
                x: safe.minX, y: safe.minY + popoverSpace, width: safe.width,
                height: max(1, bottom - safe.minY - popoverSpace - dockSpace))
            let width = min(276, max(1, bounds.width - 32))
            actionHeight =
                actionStack.systemLayoutSizeFitting(
                    CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel
                ).height
            let policy = MessageActionPolicy(row: presentation.row, context: presentation.context)
            let placement = MessageOverlayLayout(
                bounds: bounds, source: presentation.source.rect,
                previewSize: bubbleSize, controlsWidth: width,
                reactionHeight: policy.canReact ? (picking ? 76 : 52) : 0,
                actionsHeight: picking ? 0 : actionHeight, isOutgoing: presentation.row.isOutgoing)
            let frame = placement.previewFrame
            previewViewport.bounds = CGRect(origin: .zero, size: frame.size)
            previewViewport.center =
                entered || reduceMotion
                ? CGPoint(x: frame.midX, y: frame.midY)
                : CGPoint(
                    x: presentation.source.rect.midX + (presentation.row.isOutgoing ? 1 : -1)
                        * (bubbleSize.width - frame.width) * initialScale / 2,
                    y: presentation.source.rect.minY + frame.height / 2
                        + (bubbleSize.height - frame.height) * (1 - initialScale) / 2)
            preview.frame = CGRect(
                x: presentation.row.isOutgoing ? frame.width - bubbleSize.width : 0,
                y: 0, width: bubbleSize.width, height: bubbleSize.height)
            previewClip.frame = previewViewport.bounds
            previewViewport.layer.shadowPath =
                UIBezierPath(
                    roundedRect: previewViewport.bounds, cornerRadius: 16
                ).cgPath
            reactions.frame = placement.reactionFrame
            reactionStack.frame = reactions.bounds.insetBy(dx: 6, dy: 4)
            reactions.isHidden = !policy.canReact || picking
            for child in reactionStack.subviews {
                guard let progress = child as? UIActivityIndicatorView else { continue }
                progress.center = CGPoint(
                    x: reactionStack.bounds.midX, y: reactionStack.bounds.midY)
                if picking || exiting || view.window == nil {
                    progress.stopAnimating()
                } else {
                    progress.startAnimating()
                }
            }
            actionsScroll.frame = placement.actionsFrame
            actionStack.frame = CGRect(x: 0, y: 0, width: width, height: actionHeight)
            actionsScroll.contentSize = CGSize(width: width, height: actionHeight)
            actionsScroll.isHidden = picking
            placeholder.isHidden = !picking
            placeholder.frame = CGRect(
                x: min(bounds.maxX - 76, max(bounds.minX, frame.maxX - 76)),
                y: placement.reactionFrame.midY - 38, width: 76, height: 76)
            pickerSurface.isHidden = !picking
            pickerArrow.isHidden = !picking || !isPad
            pickerOutside.frame = view.bounds
            pickerOutside.isHidden = !picking || !isPad
            pickerSurface.accessibilityViewIsModal = picking && isPad
            pickerSurface.setRoundedCorners(
                isPad
                    ? [
                        .layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner,
                        .layerMaxXMaxYCorner,
                    ]
                    : [.layerMinXMinYCorner, .layerMaxXMinYCorner])
            if picking {
                if isPad {
                    let x = min(
                        safe.maxX - pickerSize.width - 16,
                        max(safe.minX + 16, placeholder.frame.midX - pickerSize.width / 2))
                    pickerSurface.frame = CGRect(
                        x: x,
                        y: max(safe.minY, placeholder.frame.minY - pickerSize.height - 12),
                        width: pickerSize.width, height: pickerSize.height)
                    pickerArrow.frame = CGRect(
                        x: placeholder.frame.midX - 10,
                        y: pickerSurface.frame.maxY - 2, width: 20, height: 14)
                    emojiPicker?.frame = pickerSurface.bounds
                } else {
                    pickerSurface.frame = CGRect(
                        x: 0, y: dockBottom - keyboardHeight - keyboardPadding,
                        width: view.bounds.width, height: keyboardHeight + keyboardPadding)
                    emojiPicker?.frame = CGRect(
                        x: insets.left, y: 0,
                        width: safe.width, height: keyboardHeight)
                }
            }
            preview.refreshMediaVisibility(isFullyVisible: frame.size == bubbleSize)
        }
        @objc private func keyboardChanged(_ notification: Notification) {
            keyboardFrame =
                notification.name == UIResponder.keyboardWillHideNotification
                ? .zero
                : (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                    ?? .zero)
            let duration =
                notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
                ?? 0.25
            view.setNeedsLayout()
            UIView.animate(withDuration: duration, animations: { self.view.layoutIfNeeded() })
        }
        func mount(scale: CGFloat, opacity: CGFloat) {
            initialScale = scale
            view.layoutIfNeeded()
            backdrop.alpha = 0
            reactions.alpha = 0
            actionsScroll.alpha = 0
            previewViewport.alpha = opacity
            previewViewport.layer.shadowOpacity = 0
            previewViewport.transform = CGAffineTransform(scaleX: scale, y: scale)
            preview.setVisible(true)
        }
        func enter() {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.exiting, self.view.window != nil else { return }
                self.entered = true
                let animator = UIViewPropertyAnimator(
                    duration: self.reduceMotion ? 0.16 : 0.38,
                    dampingRatio: self.reduceMotion ? 1 : 0.82
                ) { [weak self] in
                    guard let self else { return }
                    self.backdrop.alpha = 1
                    self.reactions.alpha = 1
                    self.actionsScroll.alpha = 1
                    self.previewViewport.alpha = 1
                    self.previewViewport.layer.shadowOpacity = 0.24
                    self.previewViewport.transform =
                        self.reduceMotion
                        ? .identity
                        : CGAffineTransform(scaleX: 1.035, y: 1.035)
                    self.view.setNeedsLayout()
                    self.view.layoutIfNeeded()
                }
                self.animation = animator
                animator.startAnimation()
                UIAccessibility.post(
                    notification: .screenChanged,
                    argument: self.reactions.isHidden ? self.actionsScroll : self.reactions)
                if !self.reduceMotion {
                    let settle = DispatchWorkItem { [weak self] in
                        guard let self, !self.exiting else { return }
                        UIView.animate(
                            withDuration: 0.3, delay: 0,
                            usingSpringWithDamping: 0.8, initialSpringVelocity: 0,
                            options: [.beginFromCurrentState]
                        ) { self.previewViewport.transform = .identity }
                    }
                    self.settle = settle
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: settle)
                }
            }
        }
        func leave(completion: @escaping () -> Void) {
            exiting = true
            settle?.cancel()
            animation?.stopAnimation(true)
            view.endEditing(true)
            view.isUserInteractionEnabled = false
            entered = false
            UIView.animate(
                withDuration: reduceMotion ? 0.15 : 0.28,
                delay: 0, options: [.beginFromCurrentState, .curveEaseOut]
            ) {
                self.backdrop.alpha = 0
                self.reactions.alpha = 0
                self.actionsScroll.alpha = 0
                self.placeholder.alpha = 0
                self.pickerSurface.alpha = 0
                self.pickerArrow.alpha = 0
                self.previewViewport.alpha = self.reduceMotion ? 0 : 1
                self.previewViewport.layer.shadowOpacity = 0
                self.previewViewport.transform = .identity
                self.view.setNeedsLayout()
                self.view.layoutIfNeeded()
            } completion: { _ in
                completion()
            }
        }
        func cleanup() {
            exiting = true
            settle?.cancel()
            animation?.stopAnimation(true)
            stopAnimations(in: view)
            view.endEditing(true)
            preview.setVisible(false)
            preview.clear()
            emojiPicker?.cleanup()
            NotificationCenter.default.removeObserver(self)
            if let preferenceObserver {
                NotificationCenter.default.removeObserver(preferenceObserver)
            }
            preferenceObserver = nil
            onClose = nil
        }
        private func stopAnimations(in view: UIView) {
            view.layer.removeAllAnimations()
            (view as? UIActivityIndicatorView)?.stopAnimating()
            for child in view.subviews { stopAnimations(in: child) }
        }
    }

    @MainActor final class MessageInteractionSurface: UIView {
        let content = UIView()
        private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        private let wash = UIView()
        init(radius: CGFloat) {
            super.init(frame: .zero)
            layer.cornerRadius = radius
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.2
            layer.shadowRadius = 16
            layer.shadowOffset = CGSize(width: 0, height: 8)
            blur.layer.cornerRadius = radius
            blur.clipsToBounds = true
            content.layer.cornerRadius = radius
            content.clipsToBounds = true
            addSubview(blur)
            blur.contentView.addSubview(wash)
            addSubview(content)
            wash.backgroundColor = UIColor { traits in
                (traits.userInterfaceStyle == .dark ? UIColor(white: 0.12, alpha: 1) : .white)
                    .withAlphaComponent(traits.accessibilityContrast == .high ? 1 : 0.65)
            }
        }
        required init?(coder: NSCoder) { nil }
        func setRoundedCorners(_ corners: CACornerMask) {
            layer.maskedCorners = corners
            blur.layer.maskedCorners = corners
            content.layer.maskedCorners = corners
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            blur.frame = bounds
            wash.frame = bounds
            content.frame = bounds
        }
    }
#endif
