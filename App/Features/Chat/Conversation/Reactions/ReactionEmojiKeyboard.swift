import SwiftUI

/// A local Unicode keyboard. Its caller supplies the height and owns dismissal.
struct ReactionEmojiKeyboard: View {
    let eligibility: MessageReactionEligibility
    let onSelect: (String) -> Void

    @AppStorage(MessageReactionPreferences.recentStorageKey)
    private var recentStorage = MessageReactionPreferences.defaultRecentStorage
    @State private var selectedCategory = -1
    @State private var visiblePage: Int?

    init(eligibility: MessageReactionEligibility, onSelect: @escaping (String) -> Void) {
        self.eligibility = eligibility
        self.onSelect = onSelect
    }

    var body: some View {
        Group {
            switch ReactionEmojiCatalog.bundled {
            case .success(let catalog):
                keyboard(catalog)
            case .failure:
                ContentUnavailableView(
                    "Emoji unavailable", systemImage: "exclamationmark.triangle",
                    description: Text("The bundled emoji catalog could not be loaded."))
            }
        }
        .background(.regularMaterial)
        .accessibilityIdentifier("reaction-emoji-keyboard")
    }

    private func keyboard(_ catalog: ReactionEmojiCatalog) -> some View {
        let entries = entries(in: catalog)
        return VStack(spacing: 0) {
            GeometryReader { geometry in
                let columns = max(1, Int(max(0, geometry.size.width - 32) / 44))
                let rows = max(1, Int(max(0, geometry.size.height - 16) / 48))
                let pageSize = columns * rows
                let pageCount = max(1, (entries.count + pageSize - 1) / pageSize)
                if entries.isEmpty {
                    Text("No recent emoji")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(0..<pageCount, id: \.self) { page in
                                emojiPage(
                                    entries, catalog: catalog, page: page,
                                    pageSize: pageSize, columns: columns, rows: rows,
                                    width: geometry.size.width,
                                    height: max(0, geometry.size.height)
                                )
                                .id(page)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $visiblePage)
                    .scrollIndicators(.hidden)
                    .accessibilityLabel(categoryTitle(selectedCategory))
                    .accessibilityValue(
                        Text("Page \(min((visiblePage ?? 0) + 1, pageCount)) of \(pageCount)")
                    )
                    .id("\(selectedCategory)-\(columns)-\(rows)")
                }
            }
            Divider()
            categoryToolbar(catalog)
                .padding(.horizontal, 8)
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
        .onChange(of: selectedCategory) { _, _ in visiblePage = 0 }
    }

    private func emojiPage(
        _ entries: [ReactionEmojiCatalog.Entry], catalog: ReactionEmojiCatalog,
        page: Int, pageSize: Int, columns: Int, rows: Int, width: CGFloat, height: CGFloat
    ) -> some View {
        let start = page * pageSize
        let end = min(entries.count, start + pageSize)
        let cellHeight = min(52, max(0, height - 16) / CGFloat(rows))
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: columns),
            alignment: .leading, spacing: 0
        ) {
            ForEach(entries[start..<end]) { entry in
                ReactionEmojiKey(
                    entry: entry, variants: catalog.variants(for: entry),
                    eligibility: eligibility, onSelect: select
                )
                .frame(height: cellHeight)
            }
        }
        .frame(width: max(0, width - 32), height: max(0, height - 16), alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(width: max(0, width), height: height, alignment: .topLeading)
        .clipped()
    }

    private func categoryToolbar(_ catalog: ReactionEmojiCatalog) -> some View {
        ScrollViewReader { reader in
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        categoryButton(-1, symbol: "clock")
                        ForEach(catalog.groups) { group in
                            categoryButton(group.id, symbol: categorySymbol(group.id))
                        }
                    }
                    .frame(minWidth: geometry.size.width)
                }
                .scrollIndicators(.hidden)
                .onChange(of: selectedCategory) { _, value in
                    withAnimation { reader.scrollTo(value, anchor: .center) }
                }
            }
            .frame(height: 44)
        }
    }

    private func categoryButton(_ category: Int, symbol: String) -> some View {
        Button {
            selectedCategory = category
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .frame(minWidth: 32, maxWidth: .infinity, minHeight: 40)
                .background {
                    if selectedCategory == category {
                        Circle()
                            .fill(.primary.opacity(0.1))
                            .frame(width: 32, height: 32)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(categoryTitle(category))
        .accessibilityAddTraits(selectedCategory == category ? .isSelected : [])
        .accessibilityIdentifier("reaction-emoji-category-\(category)")
        .id(category)
    }

    private func entries(in catalog: ReactionEmojiCatalog) -> [ReactionEmojiCatalog.Entry] {
        if selectedCategory == -1 {
            return MessageReactionPreferences.recent(from: recentStorage).compactMap {
                catalog.entry(for: $0)
            }
        }
        return catalog.groups.first { $0.id == selectedCategory }?.entries ?? []
    }

    private func select(_ emoji: String) {
        guard eligibility.canToggle(emoji) else { return }
        if !eligibility.isSelected(emoji) {
            recentStorage = MessageReactionPreferences.recording(emoji, in: recentStorage)
        }
        onSelect(emoji)
    }

    private func categoryTitle(_ category: Int) -> String {
        switch category {
        case -1: AppLanguage.localized("Recent")
        case 0: AppLanguage.localized("Smileys & Emotion")
        case 1: AppLanguage.localized("People & Body")
        case 2: AppLanguage.localized("Animals & Nature")
        case 3: AppLanguage.localized("Food & Drink")
        case 4: AppLanguage.localized("Travel & Places")
        case 5: AppLanguage.localized("Activities")
        case 6: AppLanguage.localized("Objects")
        case 7: AppLanguage.localized("Symbols")
        default: AppLanguage.localized("Flags")
        }
    }

    private func categorySymbol(_ category: Int) -> String {
        switch category {
        case 0: "face.smiling"
        case 1: "hand.wave"
        case 2: "leaf"
        case 3: "fork.knife"
        case 4: "car"
        case 5: "sportscourt"
        case 6: "lightbulb"
        case 7: "number"
        default: "flag"
        }
    }
}

private struct ReactionEmojiKey: View {
    let entry: ReactionEmojiCatalog.Entry
    let variants: [ReactionEmojiCatalog.Entry]
    let eligibility: MessageReactionEligibility
    let onSelect: (String) -> Void

    @State private var showsVariants = false

    private var canSelectBase: Bool { eligibility.canToggle(entry.emoji) }
    private var canSelectVariant: Bool { variants.contains { eligibility.canToggle($0.emoji) } }

    var body: some View {
        Button {
            if canSelectBase {
                onSelect(entry.emoji)
            } else if canSelectVariant {
                // A selected variant can still be removed at the reaction limit.
                showsVariants = true
            }
        } label: {
            Text(verbatim: entry.emoji)
                .font(.system(size: 30))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomTrailing) {
                    if !variants.isEmpty {
                        Image(systemName: "triangle.fill")
                            .font(.system(size: 5))
                            .rotationEffect(.degrees(180))
                            .foregroundStyle(.secondary)
                            .padding(3)
                            .accessibilityHidden(true)
                    }
                }
                .background {
                    if eligibility.isSelected(entry.emoji) {
                        RoundedRectangle(cornerRadius: 8).fill(.tint.opacity(0.18)).padding(2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSelectBase && !canSelectVariant)
        .accessibilityLabel(entry.name)
        .accessibilityAddTraits(eligibility.isSelected(entry.emoji) ? .isSelected : [])
        .accessibilityIdentifier("reaction-emoji-\(entry.id)")
        .contextMenu {
            if !variants.isEmpty {
                variantMenuButton(entry)
                ForEach(variants) { variant in variantMenuButton(variant) }
            }
        }
        .accessibilityActions {
            if !variants.isEmpty {
                Button("Skin tones") { showsVariants = true }
            }
        }
        .popover(isPresented: $showsVariants) {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 4) {
                    ForEach([entry] + variants) { variant in
                        Button {
                            guard eligibility.canToggle(variant.emoji) else { return }
                            showsVariants = false
                            onSelect(variant.emoji)
                        } label: {
                            Text(verbatim: variant.emoji)
                                .font(.system(size: 30))
                                .frame(width: 40, height: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(!eligibility.canToggle(variant.emoji))
                        .accessibilityLabel(variant.name)
                        .accessibilityAddTraits(
                            eligibility.isSelected(variant.emoji) ? .isSelected : []
                        )
                        .accessibilityIdentifier("reaction-emoji-variant-\(variant.id)")
                    }
                }
                .padding(8)
            }
            .frame(width: 260, height: min(280, CGFloat((variants.count + 5) / 5) * 48 + 16))
            .presentationCompactAdaptation(.popover)
        }
    }

    private func variantMenuButton(_ variant: ReactionEmojiCatalog.Entry) -> some View {
        Button {
            guard eligibility.canToggle(variant.emoji) else { return }
            onSelect(variant.emoji)
        } label: {
            Text(verbatim: "\(variant.emoji) \(variant.name)")
        }
        .disabled(!eligibility.canToggle(variant.emoji))
        .accessibilityLabel(variant.name)
        .accessibilityIdentifier("reaction-emoji-variant-\(variant.id)")
    }
}
