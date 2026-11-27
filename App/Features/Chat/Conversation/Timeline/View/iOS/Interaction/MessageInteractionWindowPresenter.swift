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
        let onEditPending: (PendingOutgoingMessage) -> Void
        let onRemovePending: (PendingOutgoingMessage) -> Void
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
                    let action = controller?.takeDeferredAction()
                    self.remove()
                    UIAccessibility.post(notification: .screenChanged, argument: nil)
                    if self.presentation != nil { self.attach(to: window) }
                    action?()
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
        private let reactions = MessageInteractionSurface(radius: MessageMenuLayout.radius)
        private let reactionStack = UIView()
        private var reactionSlots: [UIView] = []
        private let actionsPanel = UIView()
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
        private var preferenceObserver: NSObjectProtocol?
        private var menuPage = 0
        private var keyboardButtons: [UIButton] = []
        private var keyboardIndex: Int?
        private var deferredAction: (() -> Void)?

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
            dim.backgroundColor = UIColor(
                red: 34 / 255, green: 36 / 255, blue: 40 / 255, alpha: 0.25)
            dim.addTarget(self, action: #selector(close), for: .touchUpInside)
            dim.isAccessibilityElement = true
            dim.accessibilityTraits = .button
            dim.accessibilityLabel = AppLanguage.localized("Dismiss message actions")
            previewViewport.accessibilityElementsHidden = true
            previewViewport.layer.shadowColor = UIColor.black.cgColor
            previewViewport.layer.shadowOpacity = 0.24
            previewViewport.layer.shadowRadius = 18
            previewViewport.layer.shadowOffset = CGSize(width: 0, height: 10)
            view.addSubview(previewViewport)
            previewViewport.addSubview(previewClip)
            previewClip.addSubview(preview)
            view.addSubview(reactions)
            reactions.content.addSubview(reactionStack)
            view.addSubview(actionsPanel)
            actionStack.axis = .vertical
            actionStack.spacing = 8
            actionsPanel.addSubview(actionStack)
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
            NotificationCenter.default.addObserver(
                self, selector: #selector(updateTransparency),
                name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
            updateTransparency()
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
            let escape = UIKeyCommand(
                input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close))
            guard emojiPicker == nil else { return [escape] }
            return [
                escape,
                UIKeyCommand(
                    input: UIKeyCommand.inputLeftArrow, modifierFlags: [],
                    action: #selector(moveKeyboardFocus(_:))),
                UIKeyCommand(
                    input: UIKeyCommand.inputRightArrow, modifierFlags: [],
                    action: #selector(moveKeyboardFocus(_:))),
                UIKeyCommand(
                    input: UIKeyCommand.inputUpArrow, modifierFlags: [],
                    action: #selector(moveKeyboardFocus(_:))),
                UIKeyCommand(
                    input: UIKeyCommand.inputDownArrow, modifierFlags: [],
                    action: #selector(moveKeyboardFocus(_:))),
                UIKeyCommand(
                    input: "\t", modifierFlags: [], action: #selector(moveKeyboardFocus(_:))),
                UIKeyCommand(
                    input: "\t", modifierFlags: [.shift], action: #selector(moveKeyboardFocus(_:))),
                UIKeyCommand(
                    input: "\r", modifierFlags: [], action: #selector(activateKeyboardFocus)),
                UIKeyCommand(
                    input: " ", modifierFlags: [], action: #selector(activateKeyboardFocus)),
            ]
        }
        @objc private func moveKeyboardFocus(_ command: UIKeyCommand) {
            guard !keyboardButtons.isEmpty else { return }
            let backwards =
                command.input == UIKeyCommand.inputLeftArrow
                || command.input == UIKeyCommand.inputUpArrow
                || command.modifierFlags.contains(.shift)
            let step = backwards ? -1 : 1
            var index = keyboardIndex ?? (backwards ? 0 : -1)
            for _ in keyboardButtons.indices {
                index = (index + step + keyboardButtons.count) % keyboardButtons.count
                if keyboardButtons[index].isEnabled { break }
            }
            guard keyboardButtons[index].isEnabled else { return }
            for button in keyboardButtons {
                (button as? MessageInteractionButton)?.keyboardFocused = false
            }
            keyboardIndex = index
            let button = keyboardButtons[index]
            (button as? MessageInteractionButton)?.keyboardFocused = true
            UIAccessibility.post(notification: .layoutChanged, argument: button)
        }
        @objc private func activateKeyboardFocus() {
            if keyboardIndex == nil {
                moveKeyboardFocus(
                    UIKeyCommand(
                        input: "\t", modifierFlags: [], action: #selector(moveKeyboardFocus(_:))))
            }
            guard let keyboardIndex, keyboardButtons.indices.contains(keyboardIndex),
                keyboardButtons[keyboardIndex].isEnabled
            else { return }
            keyboardButtons[keyboardIndex].sendActions(for: .touchUpInside)
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
            keyboardButtons.removeAll(keepingCapacity: true)
            reactionSlots.removeAll(keepingCapacity: true)
            for item in reactionStack.subviews { item.removeFromSuperview() }
            for item in actionStack.arrangedSubviews { item.removeFromSuperview() }
            let value = presentation
            let policy = MessageActionPolicy(row: value.row, context: value.context)
            let recent =
                UserDefaults.standard.string(forKey: MessageReactionPreferences.recentStorageKey)
                ?? MessageReactionPreferences.defaultRecentStorage
            for emoji in MessageReactionPreferences.quick(from: recent) {
                let button = MessageInteractionButton(type: .system)
                button.setTitle(emoji, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 28)
                let selected = value.eligibility.isSelected(emoji)
                button.showsSelection = selected
                button.layer.cornerRadius = 10
                button.isEnabled = value.eligibility.canToggle(emoji)
                button.alpha = button.isEnabled ? 1 : 0.5
                button.accessibilityLabel = AppLanguage.localized(
                    selected ? "Remove reaction: \(emoji)" : "React with: \(emoji)")
                if selected { button.accessibilityTraits.insert(.selected) }
                button.addAction(
                    UIAction { [weak self] _ in self?.react(emoji) }, for: .touchUpInside)
                reactionSlots.append(button)
                reactionStack.addSubview(button)
                if policy.canReact { keyboardButtons.append(button) }
            }
            if !value.eligibility.distinctLimitReached {
                let more = MessageInteractionButton(type: .system)
                more.setImage(UIImage(systemName: "plus"), for: .normal)
                more.tintColor = .secondaryLabel
                more.layer.cornerRadius = 10
                more.setPreferredSymbolConfiguration(
                    .init(pointSize: 26, weight: .regular), forImageIn: .normal)
                more.isEnabled = !value.isReacting && value.eligibility.canReact
                more.alpha = more.isEnabled ? 1 : 0.5
                more.accessibilityLabel = AppLanguage.localized("More reactions")
                more.accessibilityIdentifier = "more-reactions"
                more.addAction(
                    UIAction { [weak self] _ in self?.showEmojiPicker() }, for: .touchUpInside)
                reactionSlots.append(more)
                reactionStack.addSubview(more)
                if policy.canReact { keyboardButtons.append(more) }
            } else {
                let placeholder = UIView()
                reactionSlots.append(placeholder)
                reactionStack.addSubview(placeholder)
            }
            if value.isReacting {
                let progress = UIActivityIndicatorView(style: .medium)
                progress.accessibilityLabel = AppLanguage.localized("Updating reaction")
                progress.startAnimating()
                reactionStack.addSubview(progress)
            }
            let page = MessageMenuPage(actions: policy.actions, page: menuPage)
            menuPage = page.page
            let rowHeight = MessageMenuLayout.rowHeight
            if !page.actions.isEmpty {
                let surface = MessageInteractionSurface(radius: MessageMenuLayout.radius)
                let grid = UIStackView()
                grid.axis = .vertical
                grid.spacing = 0
                surface.content.addSubview(grid)
                grid.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    grid.leadingAnchor.constraint(
                        equalTo: surface.content.leadingAnchor, constant: MessageMenuLayout.padding),
                    grid.trailingAnchor.constraint(
                        equalTo: surface.content.trailingAnchor,
                        constant: -MessageMenuLayout.padding),
                    grid.topAnchor.constraint(
                        equalTo: surface.content.topAnchor, constant: MessageMenuLayout.padding),
                    grid.bottomAnchor.constraint(
                        equalTo: surface.content.bottomAnchor, constant: -MessageMenuLayout.padding),
                ])
                let count = page.actions.count + (page.hasNavigation ? 1 : 0)
                var actionIndex = page.actions.startIndex
                for start in stride(from: 0, to: count, by: MessageMenuLayout.columns) {
                    let row = UIStackView()
                    row.distribution = .fillEqually
                    for offset in 0..<MessageMenuLayout.columns {
                        let slot = start + offset
                        if slot >= count {
                            row.addArrangedSubview(UIView())
                            continue
                        }
                        let button: MessageInteractionButton
                        if slot == page.navigationSlot {
                            button = gridButton(
                                title: page.navigationLabel, symbol: page.navigationSymbol,
                                destructive: false, showsTitle: false)
                            button.accessibilityIdentifier = "message-menu-page"
                            button.addAction(
                                UIAction { [weak self] _ in self?.changePage() },
                                for: .touchUpInside)
                        } else {
                            let action = page.actions[actionIndex]
                            page.actions.formIndex(after: &actionIndex)
                            button = gridButton(
                                title: action.label(
                                    isSaved: value.context.isSaved,
                                    isFavorite: value.context.isFavoriteSticker),
                                symbol: action.symbol(
                                    isSaved: value.context.isSaved,
                                    isFavorite: value.context.isFavoriteSticker),
                                destructive: action == .delete)
                            button.isEnabled =
                                policy.availability(of: action) == .enabled
                                && callbackAvailable(for: action)
                            button.alpha = button.isEnabled ? 1 : 0.5
                            button.addAction(
                                UIAction { [weak self] _ in
                                    guard let self else { return }
                                    if action == .favorite || action == .toSticker
                                        || action == .copy || action == .copyLink
                                    {
                                        let callback = self.presentation.onAction
                                        self.deferredAction = { callback(action) }
                                    } else {
                                        self.presentation.onAction(action)
                                    }
                                    self.close()
                                }, for: .touchUpInside)
                        }
                        row.addArrangedSubview(button)
                        keyboardButtons.append(button)
                    }
                    row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
                    grid.addArrangedSubview(row)
                }
                surface.heightAnchor.constraint(
                    equalToConstant:
                        CGFloat((count + MessageMenuLayout.columns - 1) / MessageMenuLayout.columns)
                        * rowHeight + MessageMenuLayout.padding * 2
                ).isActive = true
                actionStack.addArrangedSubview(surface)
            }
            if case .pending(let pending) = value.row.entry,
                value.actions.canEditPendingMessage(pending)
                    || value.actions.canRemovePendingMessage(pending)
            {
                let surface = MessageInteractionSurface(radius: MessageMenuLayout.radius)
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
                let canEdit = value.actions.canEditPendingMessage(pending)
                let canRemove = value.actions.canRemovePendingMessage(pending)
                for remove in [false, true] where (remove ? canRemove : canEdit) {
                    let title: String.LocalizationValue =
                        remove ? "Remove from Outbox" : "Edit queued message"
                    var config = UIButton.Configuration.plain()
                    config.title = AppLanguage.localized(title)
                    config.image = UIImage(systemName: remove ? "trash" : "square.and.pencil")
                    config.imagePadding = 8
                    config.baseForegroundColor = remove ? .systemRed : .label
                    let button = UIButton(configuration: config)
                    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
                    button.addAction(
                        UIAction { [weak self] _ in
                            guard let self else { return }
                            if remove {
                                self.presentation.onRemovePending(pending)
                            } else {
                                self.presentation.onEditPending(pending)
                            }
                        }, for: .touchUpInside)
                    stack.addArrangedSubview(button)
                    keyboardButtons.append(button)
                    if !remove && canRemove {
                        let divider = UIView()
                        divider.backgroundColor = .separator
                        divider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale)
                            .isActive = true
                        stack.addArrangedSubview(divider)
                    }
                }
                let hasBoth = canEdit && canRemove
                surface.heightAnchor.constraint(
                    equalToConstant: hasBoth ? 88 + 1 / UIScreen.main.scale : 44
                ).isActive = true
                actionStack.addArrangedSubview(surface)
            }
            view.accessibilityElements =
                emojiPicker == nil
                ? [reactions, actionsPanel, dim] : [placeholder, pickerSurface, dim]
            if let keyboardIndex, !keyboardButtons.indices.contains(keyboardIndex) {
                self.keyboardIndex = nil
            }
            view.setNeedsLayout()
            if let keyboardIndex {
                (keyboardButtons[keyboardIndex] as? MessageInteractionButton)?.keyboardFocused =
                    true
            }
        }
        private func callbackAvailable(for action: MessageMenuAction) -> Bool {
            switch action {
            case .favorite:
                presentation.actions.toggleStickerFavorite != nil
                    && !(presentation.row.entry.remoteMessage?.sticker.map {
                        presentation.actions.pendingStickerIDs.contains($0.id)
                    } ?? false)
            case .toSticker: presentation.actions.addMessageToStickerPack != nil
            default: true
            }
        }
        private func gridButton(
            title: String, symbol: String, destructive: Bool, showsTitle: Bool = true
        ) -> MessageInteractionButton {
            let button = MessageInteractionButton(type: .system)
            button.isGridAction = true
            button.setImage(
                UIImage(
                    systemName: symbol,
                    withConfiguration: UIImage.SymbolConfiguration(
                        pointSize: MessageMenuLayout.actionIcon, weight: .regular)),
                for: .normal)
            button.imageView?.contentMode = .scaleAspectFit
            if showsTitle { button.setTitle(title, for: .normal) }
            button.titleLabel?.font = .systemFont(ofSize: MessageMenuLayout.labelSize)
            button.titleLabel?.textAlignment = .center
            button.tintColor =
                destructive
                ? UIColor {
                    $0.userInterfaceStyle == .dark
                        ? .systemRed : UIColor(red: 197 / 255, green: 0, blue: 15 / 255, alpha: 1)
                }
                : .label
            button.setTitleColor(button.tintColor, for: .normal)
            button.titleLabel?.numberOfLines = 1
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.5
            button.titleLabel?.lineBreakMode = .byClipping
            button.layer.cornerRadius = 10
            button.isAccessibilityElement = true
            button.accessibilityLabel = title
            return button
        }
        private func changePage() {
            let page = MessageMenuPage(
                actions: MessageActionPolicy(row: presentation.row, context: presentation.context)
                    .actions,
                page: menuPage)
            menuPage = page.nextPage
            keyboardIndex = nil
            rebuildControls()
            view.layoutIfNeeded()
            UIAccessibility.post(notification: .layoutChanged, argument: actionsPanel)
        }
        @objc private func updateTransparency() {
            backdrop.effect =
                UIAccessibility.isReduceTransparencyEnabled
                ? nil : UIBlurEffect(style: .systemMaterial)
            backdrop.backgroundColor =
                UIAccessibility.isReduceTransparencyEnabled ? .systemBackground : .clear
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
            view.accessibilityElements = [placeholder, pickerSurface, dim]
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
            let width = min(MessageMenuLayout.width, max(1, bounds.width - 32))
            actionHeight =
                actionStack.systemLayoutSizeFitting(
                    CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel
                ).height
            let policy = MessageActionPolicy(row: presentation.row, context: presentation.context)
            let placement = MessageOverlayLayout(
                bounds: bounds, source: presentation.source.rect,
                previewSize: bubbleSize, controlsWidth: width,
                reactionHeight: policy.canReact
                    ? (picking ? 76 : MessageMenuLayout.reactionHeight) : 0,
                actionsHeight: picking ? 0 : actionHeight, isOutgoing: presentation.row.isOutgoing,
                pressPoint: presentation.source.pressPoint)
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
            let clipsWidth = frame.width < bubbleSize.width
            // Clip oversized content only on its inward edge. The native droplet
            // extends past the measured body on the outward edge.
            let leadingOverflow =
                clipsWidth && !presentation.row.isOutgoing ? bubbleSize.width : 0
            let trailingOverflow =
                clipsWidth && presentation.row.isOutgoing ? bubbleSize.width : 0
            previewClip.frame = CGRect(
                x: -leadingOverflow, y: 0,
                width: frame.width + leadingOverflow + trailingOverflow, height: frame.height)
            preview.frame = CGRect(
                x: leadingOverflow
                    + (presentation.row.isOutgoing ? frame.width - bubbleSize.width : 0),
                y: 0, width: bubbleSize.width, height: bubbleSize.height)
            // Let the rendered native contour, including the tail and asymmetric
            // group corners, supply the shadow instead of a generic rounded path.
            previewClip.clipsToBounds = clipsWidth
            reactions.bounds = CGRect(origin: .zero, size: placement.reactionFrame.size)
            let offsetY = entered || reduceMotion ? 0 : presentation.source.rect.minY - frame.minY
            reactions.center = CGPoint(
                x: placement.reactionFrame.midX, y: placement.reactionFrame.midY + offsetY)
            reactionStack.frame = reactions.bounds.insetBy(
                dx: MessageMenuLayout.padding, dy: MessageMenuLayout.padding)
            // UIStackView pixel-rounds arranged frames and can shave a pixel off a
            // 44-point target at fractional source positions. Preserve the exact
            // slot sizes here, as the native macOS reaction row does.
            let reactionWidth =
                reactionStack.bounds.width / CGFloat(max(1, reactionSlots.count))
            let isRightToLeft = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            for (index, slot) in reactionSlots.enumerated() {
                let position = isRightToLeft ? reactionSlots.count - index - 1 : index
                slot.frame = CGRect(
                    x: CGFloat(position) * reactionWidth, y: 0,
                    width: reactionWidth, height: reactionStack.bounds.height)
            }
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
            actionsPanel.bounds = CGRect(origin: .zero, size: placement.actionsFrame.size)
            actionsPanel.center = CGPoint(
                x: placement.actionsFrame.midX, y: placement.actionsFrame.midY + offsetY)
            actionStack.frame = CGRect(x: 0, y: 0, width: width, height: actionHeight)
            actionsPanel.isHidden = picking
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
            preview.refreshMediaVisibility(
                isFullyVisible: frame.size == bubbleSize && view.bounds.contains(frame))
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
        func mount(opacity: CGFloat) {
            initialScale = reduceMotion ? 1 : 0.92
            view.layoutIfNeeded()
            backdrop.alpha = 0
            reactions.alpha = 0
            actionsPanel.alpha = 0
            previewViewport.alpha = opacity
            previewViewport.layer.shadowOpacity = 0
            previewViewport.transform = CGAffineTransform(scaleX: initialScale, y: initialScale)
            preview.setVisible(true)
            if !reduceMotion {
                reactions.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
                actionsPanel.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            }
        }
        func enter() {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.exiting, self.view.window != nil else { return }
                self.entered = true
                let animator = UIViewPropertyAnimator(
                    duration: 0.18, curve: .easeOut
                ) { [weak self] in
                    guard let self else { return }
                    self.backdrop.alpha = 1
                    self.reactions.alpha = 1
                    self.actionsPanel.alpha = 1
                    self.previewViewport.alpha = 1
                    self.previewViewport.layer.shadowOpacity = 0.24
                    self.previewViewport.transform = .identity
                    self.reactions.transform = .identity
                    self.actionsPanel.transform = .identity
                    self.view.setNeedsLayout()
                    self.view.layoutIfNeeded()
                }
                self.animation = animator
                animator.startAnimation()
                UIAccessibility.post(
                    notification: .screenChanged,
                    argument: self.reactions.isHidden ? self.actionsPanel : self.reactions)
            }
        }
        func takeDeferredAction() -> (() -> Void)? {
            let action = deferredAction
            deferredAction = nil
            return action
        }
        func leave(completion: @escaping () -> Void) {
            exiting = true
            animation?.stopAnimation(true)
            view.endEditing(true)
            view.isUserInteractionEnabled = false
            entered = false
            UIView.animate(
                withDuration: 0.12,
                delay: 0, options: [.beginFromCurrentState, .curveEaseOut]
            ) {
                self.backdrop.alpha = 0
                self.reactions.alpha = 0
                self.actionsPanel.alpha = 0
                self.placeholder.alpha = 0
                self.pickerSurface.alpha = 0
                self.pickerArrow.alpha = 0
                self.previewViewport.alpha = self.reduceMotion ? 0 : 1
                self.previewViewport.layer.shadowOpacity = 0
                let transform: CGAffineTransform =
                    self.reduceMotion ? .identity : CGAffineTransform(scaleX: 0.92, y: 0.92)
                self.previewViewport.transform = transform
                self.reactions.transform = transform
                self.actionsPanel.transform = transform
                self.view.setNeedsLayout()
                self.view.layoutIfNeeded()
            } completion: { _ in
                completion()
            }
        }
        func cleanup() {
            exiting = true
            deferredAction = nil
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
        init(radius: CGFloat) {
            super.init(frame: .zero)
            layer.cornerRadius = radius
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.12
            layer.shadowRadius = 20
            layer.shadowOffset = CGSize(width: 0, height: 4)
            content.layer.cornerRadius = radius
            content.clipsToBounds = true
            content.backgroundColor = UIColor { traits in
                traits.userInterfaceStyle == .dark ? UIColor(white: 0.12, alpha: 1) : .white
            }
            addSubview(content)
        }
        required init?(coder: NSCoder) { nil }
        func setRoundedCorners(_ corners: CACornerMask) {
            layer.maskedCorners = corners
            content.layer.maskedCorners = corners
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            content.frame = bounds
        }
    }

    /// Native buttons retain UIKit keyboard/VoiceOver activation; a hover recognizer
    /// supplies the same matte highlight for an iPad pointer without a lifted effect.
    @MainActor final class MessageInteractionButton: UIButton {
        var showsSelection = false { didSet { updateHighlight() } }
        var isGridAction = false
        var keyboardFocused = false { didSet { updateHighlight() } }
        private var hovering = false
        private static let highlightColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.22, alpha: 1)
                : UIColor(red: 244 / 255, green: 245 / 255, blue: 248 / 255, alpha: 1)
        }
        override var isHighlighted: Bool { didSet { updateHighlight() } }
        override init(frame: CGRect) {
            super.init(frame: frame)
            addGestureRecognizer(
                UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        }
        required init?(coder: NSCoder) { nil }
        private func gridIconBox(in contentRect: CGRect) -> CGRect {
            let height =
                currentTitle == nil
                ? MessageMenuLayout.actionIcon
                : MessageMenuLayout.actionIcon + MessageMenuLayout.labelGap
                    + MessageMenuLayout.labelLineHeight
            return CGRect(
                x: contentRect.midX - MessageMenuLayout.actionIcon / 2,
                y: contentRect.midY - height / 2,
                width: MessageMenuLayout.actionIcon, height: MessageMenuLayout.actionIcon)
        }
        override func imageRect(forContentRect contentRect: CGRect) -> CGRect {
            guard isGridAction else { return super.imageRect(forContentRect: contentRect) }
            return MessageMenuLayout.symbolRect(
                for: currentImage?.size ?? .zero, in: gridIconBox(in: contentRect))
        }
        override func titleRect(forContentRect contentRect: CGRect) -> CGRect {
            guard isGridAction else { return super.titleRect(forContentRect: contentRect) }
            return CGRect(
                x: contentRect.minX + 1,
                y: gridIconBox(in: contentRect).maxY + MessageMenuLayout.labelGap,
                width: max(0, contentRect.width - 2), height: MessageMenuLayout.labelLineHeight)
        }
        override func didUpdateFocus(
            in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator
        ) {
            super.didUpdateFocus(in: context, with: coordinator)
            updateHighlight()
        }
        @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
            hovering = recognizer.state == .began || recognizer.state == .changed
            updateHighlight()
        }
        private func updateHighlight() {
            backgroundColor =
                showsSelection || keyboardFocused || isFocused
                    || (isEnabled && (hovering || isHighlighted))
                ? Self.highlightColor : .clear
        }
    }
#endif
