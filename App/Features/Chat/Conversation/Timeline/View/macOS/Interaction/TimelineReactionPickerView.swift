#if os(macOS)
    import AppKit

    /// The timeline's frame-view interaction owns a real AppKit popover. Keeping
    /// its Unicode keyboard native avoids a second SwiftUI presentation/lifecycle
    /// owner, while reusing the same catalog, eligibility and account preferences.
    @MainActor
    final class TimelineReactionPickerView: NSView, NSSearchFieldDelegate {
        var onSelect: ((String) -> Void)?
        var onClose: (() -> Void)?
        private var eligibility: MessageReactionEligibility
        private let catalog: ReactionEmojiCatalog?
        private let search = TimelineEmojiSearchField()
        private let scroll = TimelineEmojiScrollView()
        private let document = TimelineEmojiDocumentView()
        private let categoryScroll = NSScrollView()
        private let categoryDocument = TimelineEmojiDocumentView()
        private let divider = NSBox()
        private let status = NSTextField(wrappingLabelWithString: "")
        private let errorIcon = NSImageView()
        private var categories: [NSButton] = []
        private var buttons: [TimelineEmojiButton] = []
        private var entries: [ReactionEmojiCatalog.Entry] = []
        private var selectedCategory = -1
        private var columns = 1
        private var rows = 1
        private var pageSize = 1
        private var pageCount = 1
        private var bufferedPage = -1
        private var pageWidth: CGFloat = 0
        private var pageHeight: CGFloat = 0
        private var boundsObserver: NSObjectProtocol?
        private var defaultsObserver: NSObjectProtocol?
        private var recentStorage = MessageReactionPreferences.defaultRecentStorage
        override var isFlipped: Bool { true }

        init(eligibility: MessageReactionEligibility) {
            self.eligibility = eligibility
            if case .success(let catalog) = ReactionEmojiCatalog.bundled {
                self.catalog = catalog
            } else {
                catalog = nil
            }
            super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 360))
            let material = NSVisualEffectView(frame: bounds)
            material.material = .popover
            material.state = .active
            material.blendingMode = .withinWindow
            material.autoresizingMask = [.width, .height]
            addSubview(material)
            setAccessibilityElement(false)
            setAccessibilityRole(.group)
            setAccessibilityIdentifier("reaction-emoji-keyboard")
            search.placeholderString = AppLanguage.localized("Search emoji")
            search.sendsSearchStringImmediately = true
            search.sendsWholeSearchString = false
            search.delegate = self
            search.setAccessibilityIdentifier("reaction-emoji-search")
            search.setAccessibilityLabel(AppLanguage.localized("Search emoji"))
            search.onClose = { [weak self] in self?.onClose?() }
            addSubview(search)
            for scroller in [scroll, categoryScroll] {
                scroller.drawsBackground = false
                scroller.borderType = .noBorder
                scroller.hasHorizontalScroller = false
                scroller.hasVerticalScroller = false
                scroller.contentView.drawsBackground = false
                addSubview(scroller)
            }
            scroll.documentView = document
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.onFinishScroll = { [weak self] in self?.snapToPage() }
            categoryScroll.documentView = categoryDocument
            divider.boxType = .separator
            addSubview(divider)
            status.alignment = .center
            status.textColor = .secondaryLabelColor
            status.font = .preferredFont(forTextStyle: .body)
            addSubview(status)
            errorIcon.image = NSImage(
                systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            errorIcon.contentTintColor = .secondaryLabelColor
            errorIcon.setAccessibilityElement(false)
            addSubview(errorIcon)
            if let catalog {
                for category in [-1] + catalog.groups.map(\.id) {
                    let button = NSButton(
                        image: NSImage(
                            systemSymbolName: Self.symbol(category), accessibilityDescription: nil)
                            ?? NSImage(), target: self, action: #selector(selectCategory(_:)))
                    button.isBordered = false
                    button.imagePosition = .imageOnly
                    button.imageScaling = .scaleProportionallyDown
                    button.symbolConfiguration = .init(pointSize: 18, weight: .regular)
                    button.tag = category
                    button.toolTip = Self.title(category)
                    button.setAccessibilityLabel(Self.title(category))
                    button.setAccessibilityIdentifier("reaction-emoji-category-\(category)")
                    button.wantsLayer = true
                    button.layer?.cornerRadius = 16
                    categoryDocument.addSubview(button)
                    categories.append(button)
                }
            }
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateVisiblePages() }
            }
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let storage = self.readRecents()
                    guard storage != self.recentStorage else { return }
                    self.recentStorage = storage
                    if self.selectedCategory == -1 && !self.isSearching { self.reloadEntries() }
                }
            }
            recentStorage = readRecents()
            reloadEntries()
        }
        required init?(coder: NSCoder) { nil }
        deinit {
            MainActor.assumeIsolated {
                if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
                if let defaultsObserver {
                    NotificationCenter.default.removeObserver(defaultsObserver)
                }
            }
        }

        func ownsInteractionWindow(_ candidate: NSWindow) -> Bool {
            candidate === window || buttons.contains { $0.ownsInteractionWindow(candidate) }
        }

        func deactivate() {
            onSelect = nil
            onClose = nil
            for button in buttons { button.dismissVariants() }
        }

        func update(eligibility: MessageReactionEligibility) {
            self.eligibility = eligibility
            bufferedPage = -1
            updateVisiblePages()
        }

        func focusSearch() { window?.makeFirstResponder(search) }
        override func cancelOperation(_ sender: Any?) { onClose?() }

        func controlTextDidChange(_ obj: Notification) { reloadEntries() }
        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onClose?()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.moveDown(_:))
            {
                focusEntry(0, direction: 1)
                return true
            }
            return false
        }

        private var isSearching: Bool {
            !search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        private func readRecents() -> String {
            UserDefaults.standard.string(forKey: MessageReactionPreferences.recentStorageKey)
                ?? MessageReactionPreferences.defaultRecentStorage
        }
        private func reloadEntries() {
            if let catalog {
                if isSearching {
                    entries = catalog.search(search.stringValue)
                } else if selectedCategory == -1 {
                    entries = MessageReactionPreferences.recent(from: recentStorage).compactMap {
                        catalog.entry(for: $0)
                    }
                } else {
                    entries = catalog.groups.first { $0.id == selectedCategory }?.entries ?? []
                }
            }
            status.stringValue =
                catalog == nil
                ? AppLanguage.localized("Emoji unavailable") + "\n"
                    + AppLanguage.localized("The bundled emoji catalog could not be loaded.")
                : AppLanguage.localized(isSearching ? "No matching emoji" : "No recent emoji")
            status.isHidden = catalog != nil && !entries.isEmpty
            errorIcon.isHidden = catalog != nil
            search.isHidden = catalog == nil
            categoryScroll.isHidden = catalog == nil
            divider.isHidden = catalog == nil
            scroll.isHidden = entries.isEmpty
            bufferedPage = -1
            scroll.contentView.scroll(to: .zero)
            for button in categories {
                let selected = button.tag == selectedCategory
                button.state = selected ? .on : .off
                button.setAccessibilitySelected(selected)
                button.layer?.backgroundColor =
                    selected ? NSColor.labelColor.withAlphaComponent(0.1).cgColor : nil
            }
            needsLayout = true
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            for button in categories {
                button.layer?.backgroundColor =
                    button.tag == selectedCategory
                    ? NSColor.labelColor.withAlphaComponent(0.1).cgColor : nil
            }
        }

        override func layout() {
            super.layout()
            search.frame = NSRect(x: 16, y: 8, width: max(0, bounds.width - 32), height: 36)
            let toolbarHeight = min(44, max(0, bounds.height - 52))
            categoryScroll.frame = NSRect(
                x: 8, y: max(0, bounds.height - toolbarHeight - 8),
                width: max(0, bounds.width - 16), height: toolbarHeight)
            divider.frame = NSRect(
                x: 0, y: categoryScroll.frame.minY - 1, width: bounds.width, height: 1)
            scroll.frame = NSRect(
                x: 0, y: 48, width: bounds.width, height: max(0, divider.frame.minY - 48))
            status.frame = NSRect(
                x: 16, y: max(0, (bounds.height - 56) / 2), width: max(0, bounds.width - 32),
                height: 56)
            errorIcon.frame = NSRect(
                x: max(0, (bounds.width - 32) / 2), y: max(0, status.frame.minY - 40), width: 32,
                height: 32)
            let categoryWidth = max(
                32, categoryScroll.bounds.width / CGFloat(max(1, categories.count)))
            categoryDocument.frame = NSRect(
                x: 0, y: 0, width: categoryWidth * CGFloat(categories.count), height: toolbarHeight)
            for (index, button) in categories.enumerated() {
                button.frame = NSRect(
                    x: CGFloat(index) * categoryWidth, y: max(0, (toolbarHeight - 32) / 2),
                    width: categoryWidth, height: min(32, toolbarHeight))
            }
            let width = max(1, scroll.contentSize.width)
            let height = max(0, scroll.contentSize.height)
            let nextColumns = max(1, Int(max(0, width - 32) / 44))
            let nextRows = max(1, Int(max(0, height - 16) / 48))
            let oldPage =
                pageWidth > 0 ? Int((scroll.contentView.bounds.minX / pageWidth).rounded()) : 0
            let changed =
                width != pageWidth || height != pageHeight || columns != nextColumns
                || rows != nextRows
            pageWidth = width
            pageHeight = height
            columns = nextColumns
            rows = nextRows
            pageSize = columns * rows
            pageCount = max(1, (entries.count + pageSize - 1) / pageSize)
            document.frame = NSRect(x: 0, y: 0, width: width * CGFloat(pageCount), height: height)
            // Three page-sized buffers are retained. Scroll notifications only
            // reposition/rebind at a page boundary, never allocate an emoji grid.
            while buttons.count < pageSize * 3 {
                let button = TimelineEmojiButton()
                button.onSelect = { [weak self] emoji in self?.select(emoji) }
                button.onNavigate = { [weak self] index, code, backward in
                    self?.navigate(from: index, code: code, backward: backward)
                }
                button.onClose = { [weak self] in self?.onClose?() }
                document.addSubview(button)
                buttons.append(button)
            }
            if changed {
                bufferedPage = -1
                scroll.contentView.scroll(
                    to: NSPoint(x: CGFloat(min(oldPage, pageCount - 1)) * width, y: 0))
            }
            updateVisiblePages()
        }

        private func updateVisiblePages() {
            guard pageWidth > 0 else { return }
            let page = min(
                pageCount - 1, max(0, Int((scroll.contentView.bounds.minX / pageWidth).rounded())))
            guard bufferedPage != page else { return }
            bufferedPage = page
            let cellWidth = max(0, pageWidth - 32) / CGFloat(columns)
            let cellHeight = min(52, max(0, pageHeight - 16) / CGFloat(rows))
            for (slot, button) in buttons.enumerated() {
                let targetPage = page - 1 + slot / pageSize
                let offset = slot % pageSize
                let index = targetPage * pageSize + offset
                guard slot < pageSize * 3, targetPage >= 0, targetPage < pageCount,
                    entries.indices.contains(index), let catalog
                else {
                    button.isHidden = true
                    button.clear()
                    continue
                }
                button.isHidden = false
                button.configure(
                    entry: entries[index], variants: catalog.variants(for: entries[index]),
                    eligibility: eligibility, index: index)
                button.frame = NSRect(
                    x: CGFloat(targetPage) * pageWidth + 16 + CGFloat(offset % columns) * cellWidth,
                    y: 8 + CGFloat(offset / columns) * cellHeight, width: cellWidth,
                    height: cellHeight)
            }
            document.setAccessibilityLabel(
                isSearching ? AppLanguage.localized("Search results") : Self.title(selectedCategory)
            )
            document.setAccessibilityValue(
                AppLanguage.localized("Page \(page + 1) of \(pageCount)"))
            // Recalculating the entire window's key loop here can synchronously
            // re-enter AppKit layout. Wire only the visible native controls.
            var previous: NSView = search
            for button in buttons
            where !button.isHidden && button.isEnabled
                && button.frame.intersects(scroll.contentView.bounds)
            {
                previous.nextKeyView = button
                previous = button
            }
            for category in categories {
                previous.nextKeyView = category
                previous = category
            }
            previous.nextKeyView = search
        }

        private func snapToPage() {
            guard pageWidth > 0 else { return }
            let page = min(
                pageCount - 1, max(0, Int((scroll.contentView.bounds.minX / pageWidth).rounded())))
            scroll.contentView.scroll(to: NSPoint(x: CGFloat(page) * pageWidth, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            updateVisiblePages()
        }

        @objc private func selectCategory(_ sender: NSButton) {
            selectedCategory = sender.tag
            search.stringValue = ""
            reloadEntries()
            categoryDocument.scrollToVisible(sender.frame)
            window?.makeFirstResponder(sender)
        }

        private func select(_ emoji: String) {
            guard eligibility.canToggle(emoji) else { return }
            if !eligibility.isSelected(emoji) {
                let storage = MessageReactionPreferences.recording(emoji, in: readRecents())
                UserDefaults.standard.set(
                    storage, forKey: MessageReactionPreferences.recentStorageKey)
            }
            onSelect?(emoji)
        }

        private func navigate(from index: Int, code: UInt16, backward: Bool) {
            switch code {
            case 53: onClose?()
            case 123: focusEntry(index - 1, direction: -1)
            case 124: focusEntry(index + 1, direction: 1)
            case 125: focusEntry(index + columns, direction: 1)
            case 126: focusEntry(index - columns, direction: -1)
            case 116: focusEntry(max(0, index - pageSize), direction: -1)
            case 121: focusEntry(min(entries.count - 1, index + pageSize), direction: 1)
            case 115: focusEntry(0, direction: 1)
            case 119: focusEntry(entries.count - 1, direction: -1)
            case 48:
                let next = index + (backward ? -1 : 1)
                if next < 0 {
                    focusSearch()
                } else if next >= entries.count {
                    window?.makeFirstResponder(categories.first)
                } else {
                    focusEntry(next, direction: backward ? -1 : 1)
                }
            default: break
            }
        }

        private func focusEntry(_ index: Int, direction: Int) {
            guard !entries.isEmpty, let catalog else { return }
            var index = min(entries.count - 1, max(0, index))
            while entries.indices.contains(index) {
                let entry = entries[index]
                if eligibility.canToggle(entry.emoji)
                    || catalog.variants(for: entry).contains(where: {
                        eligibility.canToggle($0.emoji)
                    })
                {
                    let page = index / pageSize
                    scroll.contentView.scroll(to: NSPoint(x: CGFloat(page) * pageWidth, y: 0))
                    updateVisiblePages()
                    if let button = buttons.first(where: { !$0.isHidden && $0.entryIndex == index })
                    {
                        window?.makeFirstResponder(button)
                    }
                    return
                }
                index += direction
            }
        }

        private static func title(_ category: Int) -> String {
            let titles: [String.LocalizationValue] = [
                "Smileys & Emotion", "People & Body", "Animals & Nature", "Food & Drink",
                "Travel & Places", "Activities", "Objects", "Symbols", "Flags",
            ]
            return AppLanguage.localized(
                category == -1 ? "Recent" : titles[min(8, max(0, category))])
        }
        private static func symbol(_ category: Int) -> String {
            let symbols = [
                "face.smiling", "hand.wave", "leaf", "fork.knife", "car", "sportscourt",
                "lightbulb", "number", "flag",
            ]
            return category == -1 ? "clock" : symbols[min(8, max(0, category))]
        }
    }

    private final class TimelineEmojiDocumentView: NSView {
        override var isFlipped: Bool { true }
    }
    private final class TimelineEmojiSearchField: NSSearchField {
        var onClose: (() -> Void)?
        override func cancelOperation(_ sender: Any?) { onClose?() }
    }
    private final class TimelineEmojiScrollView: NSScrollView {
        var onFinishScroll: (() -> Void)?
        override func scrollWheel(with event: NSEvent) {
            super.scrollWheel(with: event)
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled
                || ((event.phase == .ended || event.phase == .cancelled)
                    && event.momentumPhase == [])
            {
                onFinishScroll?()
            }
        }
    }

    @MainActor
    private final class TimelineEmojiButton: NSButton {
        var onSelect: ((String) -> Void)?
        var onNavigate: ((Int, UInt16, Bool) -> Void)?
        var onClose: (() -> Void)?
        private var entry: ReactionEmojiCatalog.Entry?
        private var variants: [ReactionEmojiCatalog.Entry] = []
        private var eligibility: MessageReactionEligibility?
        private let variantMark = NSImageView()
        private var variantPopover: NSPopover?
        private var toneButtons: [TimelineEmojiButton] = []
        private(set) var entryIndex = -1
        override var acceptsFirstResponder: Bool { isEnabled && !isHidden }
        override var isFlipped: Bool { true }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            isBordered = false
            setButtonType(.momentaryPushIn)
            font = .systemFont(ofSize: 30)
            target = self
            action = #selector(activate)
            wantsLayer = true
            layer?.cornerRadius = 8
            variantMark.image = NSImage(
                systemSymbolName: "arrowtriangle.down.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 5, weight: .regular))
            variantMark.contentTintColor = .secondaryLabelColor
            variantMark.setAccessibilityElement(false)
            addSubview(variantMark)
        }
        required init?(coder: NSCoder) { nil }

        func configure(
            entry: ReactionEmojiCatalog.Entry, variants: [ReactionEmojiCatalog.Entry],
            eligibility: MessageReactionEligibility, index: Int
        ) {
            if self.entry?.id != entry.id { dismissVariants() }
            self.entry = entry
            self.variants = variants
            self.eligibility = eligibility
            entryIndex = index
            title = entry.emoji
            isEnabled =
                eligibility.canToggle(entry.emoji)
                || variants.contains { eligibility.canToggle($0.emoji) }
            alphaValue = isEnabled ? 1 : 0.4
            let selected = eligibility.isSelected(entry.emoji)
            layer?.backgroundColor =
                selected ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : nil
            setAccessibilityLabel(entry.name)
            setAccessibilitySelected(selected)
            setAccessibilityIdentifier("reaction-emoji-\(entry.id)")
            toolTip = entry.name
            variantMark.isHidden = variants.isEmpty
            setAccessibilityCustomActions(
                variants.isEmpty
                    ? []
                    : [
                        NSAccessibilityCustomAction(name: AppLanguage.localized("Skin tones")) {
                            [weak self] in
                            guard let self, self.isEnabled else { return false }
                            self.showVariants()
                            return true
                        }
                    ])
            if !toneButtons.isEmpty {
                let tones = [entry] + variants
                for (index, button) in toneButtons.enumerated() where tones.indices.contains(index)
                {
                    button.configure(
                        entry: tones[index], variants: [], eligibility: eligibility, index: index)
                }
            }
        }
        func clear() {
            dismissVariants()
            entry = nil
            variants.removeAll(keepingCapacity: true)
            eligibility = nil
            entryIndex = -1
            setAccessibilityCustomActions([])
        }
        override func layout() {
            super.layout()
            variantMark.frame = NSRect(
                x: max(0, bounds.width - 8), y: max(0, bounds.height - 8), width: 5, height: 5)
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            let selected = entry.map { eligibility?.isSelected($0.emoji) == true } ?? false
            layer?.backgroundColor =
                selected ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : nil
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !isHidden else { return nil }
            return bounds.contains(convert(point, from: superview)) ? self : nil
        }
        override func keyDown(with event: NSEvent) {
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                [UInt16(48), 53, 123, 124, 125, 126, 115, 116, 119, 121].contains(event.keyCode)
            {
                onNavigate?(entryIndex, event.keyCode, event.modifierFlags.contains(.shift))
            } else if event.keyCode == 125 && event.modifierFlags.contains(.option) {
                showVariants()
            } else {
                super.keyDown(with: event)
            }
        }
        override func cancelOperation(_ sender: Any?) { onClose?() }
        @objc private func activate() {
            guard let entry, let eligibility else { return }
            if eligibility.canToggle(entry.emoji) {
                onSelect?(entry.emoji)
            } else if isEnabled {
                showVariants()
            }
        }
        override func menu(for event: NSEvent) -> NSMenu? { makeVariantMenu() }
        private func makeVariantMenu() -> NSMenu? {
            guard let entry, !variants.isEmpty, let eligibility else { return nil }
            let menu = NSMenu(title: AppLanguage.localized("Skin tones"))
            menu.autoenablesItems = false
            for variant in [entry] + variants {
                let item = NSMenuItem(
                    title: variant.emoji + " " + variant.name, action: #selector(selectVariant(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = variant.emoji
                item.isEnabled = eligibility.canToggle(variant.emoji)
                item.state = eligibility.isSelected(variant.emoji) ? .on : .off
                menu.addItem(item)
            }
            return menu
        }
        private func showVariants() {
            guard variantPopover?.isShown != true, let entry, !variants.isEmpty,
                let eligibility, window != nil
            else { return }
            dismissVariants()
            let tones = [entry] + variants
            let height = CGFloat((tones.count + 4) / 5) * 48 + 16
            let scroll = NSScrollView(
                frame: NSRect(x: 0, y: 0, width: 260, height: min(280, height)))
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = height > 280
            let document = TimelineEmojiDocumentView(
                frame: NSRect(x: 0, y: 0, width: 260, height: height))
            scroll.documentView = document
            for (index, tone) in tones.enumerated() {
                let button = TimelineEmojiButton(
                    frame: NSRect(
                        x: 8 + CGFloat(index % 5) * 48, y: 8 + CGFloat(index / 5) * 48,
                        width: 44, height: 44))
                button.configure(entry: tone, variants: [], eligibility: eligibility, index: index)
                button.setAccessibilityIdentifier("reaction-emoji-variant-\(tone.id)")
                button.onSelect = { [weak self] emoji in
                    guard let self, self.eligibility?.canToggle(emoji) == true else { return }
                    self.dismissVariants()
                    self.onSelect?(emoji)
                }
                button.onClose = { [weak self] in self?.dismissVariants() }
                button.onNavigate = { [weak self] index, code, backward in
                    self?.navigateTones(from: index, code: code, backward: backward)
                }
                document.addSubview(button)
                toneButtons.append(button)
            }
            let controller = NSViewController()
            controller.view = scroll
            let popover = NSPopover()
            popover.behavior = .semitransient
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.contentViewController = controller
            popover.contentSize = scroll.frame.size
            variantPopover = popover
            popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
            popover.contentViewController?.view.window?.recalculateKeyViewLoop()
            if let first = toneButtons.first(where: \.isEnabled) {
                first.window?.makeFirstResponder(first)
            }
        }
        func ownsInteractionWindow(_ candidate: NSWindow) -> Bool {
            candidate === variantPopover?.contentViewController?.view.window
        }
        func dismissVariants() {
            variantPopover?.close()
            variantPopover?.contentViewController = nil
            variantPopover = nil
            toneButtons.removeAll()
        }
        private func navigateTones(from index: Int, code: UInt16, backward: Bool) {
            if code == 53 {
                dismissVariants()
                window?.makeFirstResponder(self)
                return
            }
            let step: Int
            switch code {
            case 123: step = -1
            case 124: step = 1
            case 125: step = 5
            case 126: step = -5
            case 48: step = backward ? -1 : 1
            default: return
            }
            var next = index + step
            while toneButtons.indices.contains(next) {
                let button = toneButtons[next]
                if button.isEnabled {
                    button.scrollToVisible(button.bounds)
                    button.window?.makeFirstResponder(button)
                    return
                }
                next += step < 0 ? -1 : 1
            }
        }
        @objc private func selectVariant(_ sender: NSMenuItem) {
            guard let emoji = sender.representedObject as? String,
                eligibility?.canToggle(emoji) == true
            else { return }
            onSelect?(emoji)
        }
    }

    /// A native thought-bubble anchor preserves the source message and the
    /// original picker-close target without rendering a hosted SwiftUI snapshot.
    /// Only these floating shapes use glass; the keyboard keeps its content material.
    @MainActor
    final class TimelineReactionPickerPlaceholder: NSView {
        var onClose: (() -> Void)?
        private let close = NSButton()
        override var isFlipped: Bool { true }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(false)
            setAccessibilityLabel(AppLanguage.localized("Choose a reaction"))
            setAccessibilityIdentifier("reaction-emoji-placeholder")
            for rect in [
                NSRect(x: 0, y: 0, width: 64, height: 64),
                NSRect(x: 49, y: 56, width: 14, height: 14),
                NSRect(x: 64, y: 70, width: 6, height: 6),
            ] {
                let material: NSView
                if #available(macOS 26, *) {
                    let glass = NSGlassEffectView(frame: rect)
                    glass.cornerRadius = rect.width / 2
                    glass.style = .regular
                    if #available(macOS 27, *) { glass.effectIsInteractive = true }
                    material = glass
                } else {
                    let effect = NSVisualEffectView(frame: rect)
                    effect.material = .popover
                    effect.state = .active
                    effect.blendingMode = .withinWindow
                    effect.wantsLayer = true
                    effect.layer?.cornerRadius = rect.width / 2
                    effect.layer?.masksToBounds = true
                    material = effect
                }
                material.setAccessibilityElement(false)
                addSubview(material)
            }
            let face = NSImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
            face.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 34, weight: .light))
            face.contentTintColor = .secondaryLabelColor
            face.setAccessibilityElement(false)
            addSubview(face)
            close.frame = NSRect(x: 48, y: 0, width: 28, height: 28)
            close.title = ""
            close.bezelStyle = .circular
            close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
            close.imagePosition = .imageOnly
            close.target = self
            close.action = #selector(activateClose)
            close.setAccessibilityLabel(AppLanguage.localized("Close emoji picker"))
            close.setAccessibilityIdentifier("reaction-emoji-close")
            addSubview(close)
        }
        required init?(coder: NSCoder) { nil }
        @objc private func activateClose() { onClose?() }
    }
#endif
