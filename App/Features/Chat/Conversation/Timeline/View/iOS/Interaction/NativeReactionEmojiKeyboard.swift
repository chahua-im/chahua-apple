#if os(iOS)
    import ChahuaAPI
    import UIKit

    /// The interaction window cannot embed the shared SwiftUI keyboard without
    /// reintroducing a hosting tree. UIKit reuses the same catalog, eligibility and
    /// preferences, including every supported Unicode sequence and tone variant.
    @MainActor
    final class NativeReactionEmojiKeyboard: UIView,
        UICollectionViewDataSource, UICollectionViewDelegate, UITextFieldDelegate
    {
        var eligibility: MessageReactionEligibility {
            didSet {
                let changed =
                    oldValue.canReact != eligibility.canReact
                    || oldValue.isReacting != eligibility.isReacting
                    || oldValue.reactions.count != eligibility.reactions.count
                    || !zip(oldValue.reactions, eligibility.reactions).allSatisfy { pair in
                        pair.0.emoji == pair.1.emoji && pair.0.count == pair.1.count
                            && pair.0.reactedByMe == pair.1.reactedByMe
                    }
                guard changed else { return }
                collection.reloadData()
                if let activeVariantEntry { showVariants(activeVariantEntry) }
            }
        }
        var onSelect: ((String) -> Void)?
        private let search = UISearchTextField()
        private let clearSearch = UIButton(type: .system)
        private let collection: UICollectionView
        private let layout = NativeReactionEmojiLayout()
        private let categories = UIScrollView()
        private let categoryStack = UIStackView()
        private let separator = UIView()
        private let empty = UILabel()
        private var catalog: ReactionEmojiCatalog?
        private var entries: [ReactionEmojiCatalog.Entry] = []
        private var category = -1
        private var categoryButtons: [Int: UIButton] = [:]
        private var variantsOverlay: UIControl?
        private var activeVariantEntry: ReactionEmojiCatalog.Entry?
        private var lastSize = CGSize.zero

        init(eligibility: MessageReactionEligibility) {
            self.eligibility = eligibility
            collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
            super.init(frame: .zero)
            accessibilityIdentifier = "reaction-emoji-keyboard"
            backgroundColor = .clear
            addSubview(search)
            search.placeholder = AppLanguage.localized("Search emoji")
            search.accessibilityIdentifier = "reaction-emoji-search"
            search.returnKeyType = .done
            search.autocorrectionType = .no
            search.autocapitalizationType = .none
            search.delegate = self
            search.addTarget(self, action: #selector(queryChanged), for: .editingChanged)
            search.clearButtonMode = .never
            clearSearch.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
            clearSearch.tintColor = .secondaryLabel
            clearSearch.accessibilityLabel = AppLanguage.localized("Clear search")
            clearSearch.accessibilityIdentifier = "reaction-emoji-search-clear"
            clearSearch.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
            clearSearch.addAction(
                UIAction { [weak self] _ in
                    self?.search.text = ""
                    self?.reloadEntries()
                }, for: .touchUpInside)
            search.rightView = clearSearch
            search.rightViewMode = .never
            addSubview(collection)
            collection.backgroundColor = .clear
            collection.isPagingEnabled = true
            collection.showsHorizontalScrollIndicator = false
            collection.showsVerticalScrollIndicator = false
            collection.alwaysBounceHorizontal = true
            collection.dataSource = self
            collection.delegate = self
            collection.register(NativeReactionEmojiCell.self, forCellWithReuseIdentifier: "emoji")
            addSubview(empty)
            empty.font = .preferredFont(forTextStyle: .callout)
            empty.textColor = .secondaryLabel
            empty.textAlignment = .center
            empty.numberOfLines = 0
            addSubview(separator)
            separator.backgroundColor = .separator
            addSubview(categories)
            categories.showsHorizontalScrollIndicator = false
            categories.addSubview(categoryStack)
            categoryStack.axis = .horizontal
            categoryStack.spacing = 0
            switch ReactionEmojiCatalog.bundled {
            case .success(let catalog):
                self.catalog = catalog
                for id in [-1] + catalog.groups.map(\.id) {
                    let button = UIButton(type: .system)
                    button.setImage(UIImage(systemName: Self.categorySymbol(id)), for: .normal)
                    button.setPreferredSymbolConfiguration(
                        .init(pointSize: 18), forImageIn: .normal)
                    button.accessibilityLabel = Self.categoryTitle(id)
                    button.accessibilityIdentifier = "reaction-emoji-category-\(id)"
                    button.layer.cornerRadius = 16
                    button.addAction(
                        UIAction { [weak self] _ in self?.selectCategory(id) }, for: .touchUpInside)
                    categoryStack.addArrangedSubview(button)
                    button.widthAnchor.constraint(equalToConstant: 40).isActive = true
                    categoryButtons[id] = button
                }
                reloadEntries()
            case .failure:
                search.isHidden = true
                categories.isHidden = true
                empty.text =
                    AppLanguage.localized("Emoji unavailable") + "\n"
                    + AppLanguage.localized("The bundled emoji catalog could not be loaded.")
            }
        }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() {
            super.layoutSubviews()
            search.frame = CGRect(x: 16, y: 8, width: max(1, bounds.width - 32), height: 36)
            let gridHeight = max(0, bounds.height - 96)
            collection.frame = CGRect(x: 0, y: 48, width: bounds.width, height: gridHeight)
            empty.frame = collection.frame.insetBy(dx: 16, dy: 0)
            separator.frame = CGRect(
                x: 0, y: bounds.height - 48, width: bounds.width,
                height: 1 / max(1, traitCollection.displayScale))
            categories.frame = CGRect(
                x: 8, y: bounds.height - 44,
                width: max(1, bounds.width - 16), height: 36)
            categoryStack.frame = CGRect(
                x: 0, y: 0,
                width: max(categories.bounds.width, CGFloat(categoryButtons.count) * 40), height: 36
            )
            categories.contentSize = categoryStack.bounds.size
            if bounds.size != lastSize {
                lastSize = bounds.size
                layout.invalidateLayout()
                collection.setContentOffset(.zero, animated: false)
                variantsOverlay?.removeFromSuperview()
                activeVariantEntry = nil
                variantsOverlay = nil
            }
        }
        private var isSearching: Bool {
            !(search.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        @objc private func queryChanged() { reloadEntries() }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
        private func selectCategory(_ id: Int) {
            category = id
            search.text = ""
            search.resignFirstResponder()
            reloadEntries()
            if let button = categoryButtons[id] {
                categories.scrollRectToVisible(
                    button.frame.insetBy(dx: -8, dy: 0),
                    animated: !UIAccessibility.isReduceMotionEnabled)
            }
        }
        private func reloadEntries() {
            guard let catalog else { return }
            search.rightViewMode = (search.text ?? "").isEmpty ? .never : .always
            if isSearching {
                entries = catalog.search(search.text ?? "")
            } else if category == -1 {
                let recent =
                    UserDefaults.standard.string(
                        forKey: MessageReactionPreferences.recentStorageKey)
                    ?? MessageReactionPreferences.defaultRecentStorage
                entries = MessageReactionPreferences.recent(from: recent).compactMap {
                    catalog.entry(for: $0)
                }
            } else {
                entries = catalog.groups.first { $0.id == category }?.entries ?? []
            }
            for (id, button) in categoryButtons {
                button.backgroundColor = id == category ? .label.withAlphaComponent(0.1) : .clear
                button.accessibilityTraits = id == category ? [.button, .selected] : .button
            }
            collection.accessibilityLabel =
                isSearching ? AppLanguage.localized("Search results") : Self.categoryTitle(category)
            empty.text = AppLanguage.localized(
                isSearching ? "No matching emoji" : "No recent emoji")
            empty.isHidden = !entries.isEmpty
            collection.reloadData()
            collection.layoutIfNeeded()
            layout.invalidateLayout()
            collection.setContentOffset(.zero, animated: false)
            updatePageAccessibility()
        }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int)
            -> Int
        { entries.count }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath)
            -> UICollectionViewCell
        {
            let cell =
                collectionView.dequeueReusableCell(withReuseIdentifier: "emoji", for: indexPath)
                as! NativeReactionEmojiCell
            let entry = entries[indexPath.item]
            let variants = catalog?.variants(for: entry) ?? []
            let enabled =
                eligibility.canToggle(entry.emoji)
                || variants.contains { eligibility.canToggle($0.emoji) }
            cell.configure(
                entry: entry, hasVariants: !variants.isEmpty,
                selected: eligibility.isSelected(entry.emoji), enabled: enabled, tint: tintColor)
            if !variants.isEmpty {
                cell.accessibilityCustomActions = [
                    UIAccessibilityCustomAction(name: AppLanguage.localized("Skin tones")) {
                        [weak self] _ in
                        self?.showVariants(entry)
                        return self != nil
                    }
                ]
            } else {
                cell.accessibilityCustomActions = nil
            }
            return cell
        }
        func collectionView(
            _ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath
        ) {
            let entry = entries[indexPath.item]
            if eligibility.canToggle(entry.emoji) {
                select(entry.emoji)
            } else if catalog?.variants(for: entry).contains(where: {
                eligibility.canToggle($0.emoji)
            }) == true {
                showVariants(entry)
            }
        }
        func collectionView(
            _ collectionView: UICollectionView,
            contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint
        ) -> UIContextMenuConfiguration? {
            let entry = entries[indexPath.item]
            guard let variants = catalog?.variants(for: entry), !variants.isEmpty else {
                return nil
            }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
                [weak self] _ in
                guard let self else { return nil }
                return UIMenu(
                    children: ([entry] + variants).map { variant in
                        UIAction(
                            title: "\(variant.emoji) \(variant.name)",
                            attributes: self.eligibility.canToggle(variant.emoji) ? [] : .disabled,
                            state: self.eligibility.isSelected(variant.emoji) ? .on : .off
                        ) { [weak self] _ in self?.select(variant.emoji) }
                    })
            }
        }
        private func select(_ emoji: String) {
            guard eligibility.canToggle(emoji) else { return }
            onSelect?(emoji)
        }
        private func showVariants(_ entry: ReactionEmojiCatalog.Entry) {
            guard let variants = catalog?.variants(for: entry), !variants.isEmpty else { return }
            activeVariantEntry = entry
            variantsOverlay?.removeFromSuperview()
            let overlay = UIControl(frame: bounds)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.backgroundColor = .black.withAlphaComponent(0.12)
            overlay.addAction(
                UIAction { [weak self] _ in self?.dismissVariants() }, for: .touchUpInside)
            overlay.accessibilityViewIsModal = true
            let options = [entry] + variants
            let width = min(260, max(1, bounds.width - 16))
            let height = min(
                max(48, bounds.height - 16), min(280, CGFloat((options.count + 4) / 5) * 48 + 16))
            let surface = MessageInteractionSurface(radius: 14)
            surface.frame = CGRect(
                x: (bounds.width - width) / 2, y: (bounds.height - height) / 2,
                width: width, height: height)
            overlay.addSubview(surface)
            let scroll = UIScrollView(frame: surface.bounds)
            scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            surface.content.addSubview(scroll)
            for (index, variant) in options.enumerated() {
                let button = UIButton(type: .system)
                button.setTitle(variant.emoji, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 30)
                button.frame = CGRect(
                    x: 8 + CGFloat(index % 5) * (width - 16) / 5,
                    y: 8 + CGFloat(index / 5) * 48, width: (width - 16) / 5, height: 48)
                button.accessibilityLabel = variant.name
                button.accessibilityIdentifier = "reaction-emoji-variant-\(variant.id)"
                button.isEnabled = eligibility.canToggle(variant.emoji)
                button.alpha = button.isEnabled ? 1 : 0.4
                if eligibility.isSelected(variant.emoji) {
                    button.accessibilityTraits.insert(.selected)
                }
                button.addAction(
                    UIAction { [weak self] _ in self?.select(variant.emoji) }, for: .touchUpInside)
                scroll.addSubview(button)
            }
            scroll.contentSize = CGSize(
                width: width, height: CGFloat((options.count + 4) / 5) * 48 + 16)
            addSubview(overlay)
            variantsOverlay = overlay
            UIAccessibility.post(notification: .layoutChanged, argument: surface)
        }
        @objc private func dismissVariants() {
            variantsOverlay?.removeFromSuperview()
            variantsOverlay = nil
            activeVariantEntry = nil
            UIAccessibility.post(notification: .layoutChanged, argument: collection)
        }
        override func accessibilityPerformEscape() -> Bool {
            guard variantsOverlay != nil else { return false }
            dismissVariants()
            return true
        }
        override var keyCommands: [UIKeyCommand]? {
            guard variantsOverlay != nil else { return nil }
            return [
                UIKeyCommand(
                    input: UIKeyCommand.inputEscape, modifierFlags: [],
                    action: #selector(dismissVariants))
            ]
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { updatePageAccessibility() }
        private func updatePageAccessibility() {
            let page = Int(collection.contentOffset.x / max(1, collection.bounds.width)) + 1
            let pages = max(1, layout.pageCount)
            collection.accessibilityValue = AppLanguage.localized(
                "Page \(min(page, pages)) of \(pages)")
        }
        func cleanup() {
            endEditing(true)
            onSelect = nil
            variantsOverlay?.removeFromSuperview()
            variantsOverlay = nil
            activeVariantEntry = nil
            collection.delegate = nil
            collection.dataSource = nil
        }
        private static func categoryTitle(_ id: Int) -> String {
            let names: [String.LocalizationValue] = [
                "Recent", "Smileys & Emotion", "People & Body", "Animals & Nature", "Food & Drink",
                "Travel & Places", "Activities", "Objects", "Symbols", "Flags",
            ]
            return AppLanguage.localized(names[min(max(id + 1, 0), names.count - 1)])
        }
        private static func categorySymbol(_ id: Int) -> String {
            let symbols = [
                "clock", "face.smiling", "hand.wave", "leaf", "fork.knife", "car",
                "sportscourt", "lightbulb", "number", "flag",
            ]
            return symbols[min(max(id + 1, 0), symbols.count - 1)]
        }
    }

    @MainActor private final class NativeReactionEmojiCell: UICollectionViewCell {
        private let emoji = UILabel()
        private let variantMarker = UIImageView(image: UIImage(systemName: "triangle.fill"))
        override init(frame: CGRect) {
            super.init(frame: frame)
            isAccessibilityElement = true
            emoji.font = .systemFont(ofSize: 30)
            emoji.textAlignment = .center
            contentView.addSubview(emoji)
            variantMarker.transform = CGAffineTransform(rotationAngle: .pi)
            variantMarker.tintColor = .secondaryLabel
            contentView.addSubview(variantMarker)
            contentView.layer.cornerRadius = 8
        }
        required init?(coder: NSCoder) { nil }
        func configure(
            entry: ReactionEmojiCatalog.Entry, hasVariants: Bool,
            selected: Bool, enabled: Bool, tint: UIColor
        ) {
            emoji.text = entry.emoji
            variantMarker.isHidden = !hasVariants
            contentView.backgroundColor = selected ? tint.withAlphaComponent(0.18) : .clear
            contentView.alpha = enabled ? 1 : 0.4
            isUserInteractionEnabled = enabled
            accessibilityLabel = entry.name
            accessibilityIdentifier = "reaction-emoji-\(entry.id)"
            accessibilityTraits = [.button]
            if selected { accessibilityTraits.insert(.selected) }
            if !enabled { accessibilityTraits.insert(.notEnabled) }
        }
        override var isHighlighted: Bool {
            didSet { emoji.alpha = isHighlighted ? 0.5 : 1 }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            emoji.frame = contentView.bounds
            variantMarker.frame = CGRect(
                x: bounds.width - 8, y: bounds.height - 8, width: 5, height: 5)
        }
        override func prepareForReuse() {
            super.prepareForReuse()
            accessibilityCustomActions = nil
        }
    }

    /// Row-major, horizontally paged emoji geometry. Cache both page windows and
    /// attributes during size/data changes, never allocate/filter on a scroll tick.
    @MainActor private final class NativeReactionEmojiLayout: UICollectionViewLayout {
        override var flipsHorizontallyInOppositeLayoutDirection: Bool { true }
        private var attributes: [UICollectionViewLayoutAttributes] = []
        private var pageWindows: [[UICollectionViewLayoutAttributes]] = []
        private var preparedSize = CGSize.zero
        private var preparedCount = -1
        private(set) var pageCount = 1
        override func prepare() {
            super.prepare()
            guard let collectionView else { return }
            let size = collectionView.bounds.size
            let count = collectionView.numberOfItems(inSection: 0)
            guard preparedSize != size || preparedCount != count else { return }
            preparedSize = size
            preparedCount = count
            let columns = max(1, Int(max(0, size.width - 32) / 44))
            let rows = max(1, Int(max(0, size.height - 16) / 48))
            let pageSize = columns * rows
            pageCount = max(1, (count + pageSize - 1) / pageSize)
            let cellWidth = max(0, size.width - 32) / CGFloat(columns)
            let cellHeight = min(52, max(0, size.height - 16) / CGFloat(rows))
            var pages = Array(repeating: [UICollectionViewLayoutAttributes](), count: pageCount)
            attributes.removeAll(keepingCapacity: true)
            for index in 0..<count {
                let page = index / pageSize
                let local = index % pageSize
                let attribute = UICollectionViewLayoutAttributes(
                    forCellWith: IndexPath(item: index, section: 0))
                attribute.frame = CGRect(
                    x: CGFloat(page) * size.width + 16 + CGFloat(local % columns) * cellWidth,
                    y: 8 + CGFloat(local / columns) * cellHeight, width: cellWidth,
                    height: cellHeight)
                attributes.append(attribute)
                pages[page].append(attribute)
            }
            pageWindows = (0..<pageCount).map { page in
                pages[page] + (page + 1 < pageCount ? pages[page + 1] : [])
            }
        }
        override var collectionViewContentSize: CGSize {
            CGSize(width: preparedSize.width * CGFloat(pageCount), height: preparedSize.height)
        }
        override func layoutAttributesForElements(in rect: CGRect)
            -> [UICollectionViewLayoutAttributes]?
        {
            guard !pageWindows.isEmpty else { return nil }
            let page = min(
                pageWindows.count - 1, max(0, Int(rect.minX / max(1, preparedSize.width))))
            return pageWindows[page]
        }
        override func layoutAttributesForItem(at indexPath: IndexPath)
            -> UICollectionViewLayoutAttributes?
        {
            attributes.indices.contains(indexPath.item) ? attributes[indexPath.item] : nil
        }
        override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
            newBounds.size != preparedSize
        }
    }
#endif
