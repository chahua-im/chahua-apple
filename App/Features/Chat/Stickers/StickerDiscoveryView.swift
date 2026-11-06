import ChahuaAPI
import SwiftUI

/// Shared shop destination; its layout follows the available presentation width.
struct StickerDiscoveryView: View {
    @ObservedObject var library: StickerLibrary
    var onClose: (() -> Void)?
    @State private var query = ""
    @State private var sort = StickerPackSort.trending
    @State private var showsCreatePack = false
    @State private var createdPackID: String?
    @State private var openedPackID: String?
    @State private var selectedPackID: String?
    @FocusState private var isSearching: Bool

    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var request: Request {
        Request(query: query, sort: sort, accountID: library.accountID)
    }

    private struct Request: Hashable {
        let query: String
        let sort: StickerPackSort
        let accountID: Int32?
    }

    var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width >= 680
            Group {
                if isWide {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            wideSidebarHeader
                            packList(isWide: true)
                        }
                        .frame(width: min(340, max(260, geometry.size.width * 0.32)))
                        Divider()
                        if let selectedPackID {
                            StickerShopPackDetailView(
                                library: library, packID: selectedPackID,
                                discoveryItem: discoveryItem(selectedPackID), isWide: true
                            )
                            .id(selectedPackID)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ContentUnavailableView(
                                "Select a sticker pack", systemImage: "square.stack"
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                } else {
                    packList(isWide: false)
                }
            }
            .navigationTitle(isWide ? LocalizedStringKey("") : "Sticker Shop")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(isWide ? .hidden : .visible, for: .navigationBar)
            #else
                .toolbar(isWide ? .hidden : .visible, for: .windowToolbar)
            #endif
            .toolbar {
                if !isWide { compactToolbar }
            }
        }
        .background(StickerShopStyle.canvas)
        .onChange(of: query) { _, value in
            if value.count > 255 { query = String(value.prefix(255)) }
        }
        .task(id: request) {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await library.discover(query: query, sort: sort)
        }
        .onChange(of: request) { _, _ in library.cancelDiscovery() }
        .onDisappear { library.cancelDiscovery() }
        .onAppear {
            if selectedPackID == nil { selectedPackID = library.discoveryPacks.first?.id }
        }
        .onChange(of: library.discoveryPacks) { _, items in
            if let selectedPackID, items.contains(where: { $0.id == selectedPackID }) { return }
            selectedPackID = items.first?.id
        }
        .onChange(of: library.accountID) { _, _ in
            query = ""
            sort = .trending
            showsCreatePack = false
            createdPackID = nil
            openedPackID = nil
            selectedPackID = nil
        }
        .sheet(isPresented: $showsCreatePack) {
            StickerDiscoveryCreateSheet(library: library) { pack in
                showsCreatePack = false
                createdPackID = pack.id
            }
        }
        .navigationDestination(item: $createdPackID) { packID in
            if let uid = library.accountID {
                StickerPackDetailSettingsView(library: library, currentUserID: uid, packID: packID)
                    #if os(iOS)
                        .toolbar(.visible, for: .navigationBar)
                    #else
                        .toolbar(.visible, for: .windowToolbar)
                    #endif
            }
        }
        .navigationDestination(item: $openedPackID) { packID in
            StickerShopPackDetailView(
                library: library, packID: packID, discoveryItem: discoveryItem(packID))
        }
    }

    @ToolbarContentBuilder
    private var compactToolbar: some ToolbarContent {
        if let onClose {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
            }
        }
        ToolbarItem(placement: .primaryAction) { createPackButton }
    }

    private var createPackButton: some View {
        Button("Create Pack", systemImage: "plus") { showsCreatePack = true }
            .labelStyle(.iconOnly)
            .disabled(library.pendingMutationIDs.contains("create-sticker-pack"))
    }

    private var wideSidebarHeader: some View {
        HStack(spacing: 12) {
            if let onClose {
                Button("Close", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
            }
            Text("Sticker Shop").font(.title3.bold())
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            createPackButton
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .tint(.primary)
        .padding(.horizontal, 16)
        .frame(height: 70)
    }

    private func discoveryItem(_ id: String) -> StickerPackDiscoveryItem? {
        library.discoveryPacks.first { $0.id == id }
    }

    private func packList(isWide: Bool) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search sticker packs", text: $query)
                            .textFieldStyle(.plain)
                            .focused($isSearching)
                            .accessibilityIdentifier("sticker-shop.search")
                            #if os(iOS)
                                .submitLabel(.search)
                            #endif
                        if !query.isEmpty {
                            Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 14).frame(height: isWide ? 38 : 44)
                    .background(StickerShopStyle.card, in: Capsule())
                    if isSearching && !isWide {
                        Button("Cancel") {
                            query = ""
                            isSearching = false
                        }
                        .font(.subheadline)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                }
                Picker("Sort sticker packs", selection: $sort) {
                    Label("Trending", systemImage: "chart.line.uptrend.xyaxis")
                        .tag(StickerPackSort.trending)
                    Label("Most subscribed", systemImage: "person.2")
                        .tag(StickerPackSort.subscribers)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(minHeight: isWide ? 32 : 36)
                .accessibilityIdentifier("sticker-shop.sort")
            }
            .padding(.horizontal, 16)
            .padding(.top, isWide ? 0 : 12).padding(.bottom, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(
                        alignment: .leading, spacing: isWide ? 2 : searchTerm.isEmpty ? 12 : 8
                    ) {
                        if !searchTerm.isEmpty {
                            Text("Names and descriptions containing “\(searchTerm)”")
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 4).padding(.bottom, 4)
                        }
                        if !library.hasLoadedDiscovery && library.discoveryError == nil {
                            loadingPacks(isCompact: isWide || !searchTerm.isEmpty)
                        }
                        let packs = library.discoveryPacks
                        ForEach(packs.indices, id: \.self) { index in
                            let item = packs[index]
                            Group {
                                if isWide || !searchTerm.isEmpty {
                                    compactRow(item, isWide: isWide)
                                } else {
                                    packCard(item, rank: index + 1)
                                }
                            }
                            .id(item.id)
                        }
                        if let error = library.discoveryError {
                            VStack(spacing: 8) {
                                Text(error).font(.callout).foregroundStyle(.secondary)
                                Button("Retry") { Task { await library.retryDiscovery() } }
                            }
                            .frame(maxWidth: .infinity).padding()
                        } else if library.hasLoadedDiscovery && !library.isDiscovering
                            && library.discoveryPacks.isEmpty
                        {
                            ContentUnavailableView {
                                Label(
                                    searchTerm.isEmpty
                                        ? LocalizedStringKey("No public packs yet")
                                        : "No sticker packs found",
                                    systemImage: searchTerm.isEmpty ? "bag" : "magnifyingglass")
                            } description: {
                                Text(
                                    searchTerm.isEmpty
                                        ? LocalizedStringKey("Make the first one.")
                                        : "Try another name or word.")
                            } actions: {
                                if searchTerm.isEmpty {
                                    Button("Create Sticker Pack") { showsCreatePack = true }
                                } else {
                                    Button("Clear search") { query = "" }
                                }
                            }
                        }
                        if let cursor = library.discoveryCursor, library.discoveryError == nil {
                            VStack {
                                if library.isDiscovering {
                                    ProgressView()
                                } else {
                                    Button("Load More") { Task { await loadMore() } }
                                }
                            }
                            .frame(maxWidth: .infinity).padding()
                            .task(id: cursor) { await loadMore() }
                        }
                    }
                    .id("discovery-top")
                    .padding(.horizontal, isWide ? 8 : 16)
                    .padding(.bottom, 12)
                }
                // Keep existing cards unobscured during sort/search refreshes; a
                // linear overlay flashes across the first card on fast responses.
                .onChange(of: library.discoveryRevision) { _, _ in
                    proxy.scrollTo("discovery-top", anchor: .top)
                }
                .refreshable { await library.discover(query: query, sort: sort) }
            }
        }
    }

    private func compactRow(_ item: StickerPackDiscoveryItem, isWide: Bool) -> some View {
        Button {
            if isWide { selectedPackID = item.id } else { openedPackID = item.id }
        } label: {
            HStack(spacing: 8) {
                if let preview = item.previewStickers.first ?? item.pack.previewSticker {
                    StickerShopStickerSlot(media: preview.media, emoji: preview.emoji)
                        .frame(width: isWide ? 56 : 52, height: isWide ? 56 : 52)
                        .background(StickerShopStyle.tile, in: RoundedRectangle(cornerRadius: 15))
                } else {
                    Image(systemName: "square.stack")
                        .frame(width: isWide ? 56 : 52, height: isWide ? 56 : 52)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    highlighted(item.pack.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    ownerAndCount(item.pack).font(.caption2).foregroundStyle(.secondary)
                    subscriberLabel(item).font(.caption2).foregroundStyle(.green)
                }
                Spacer(minLength: isWide ? 32 : 72)
            }
            .padding(.horizontal, 10).padding(.vertical, isWide ? 8 : 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sticker-shop.pack.\(item.id)")
        .accessibilityLabel("View \(item.pack.name) pack")
        .background(
            isWide && selectedPackID == item.id
                ? Color.accentColor.opacity(0.14) : Color.primary.opacity(isWide ? 0 : 0.035),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(alignment: .trailing) {
            StickerShopAddButton(library: library, pack: item.pack, compact: isWide) {
                createdPackID = item.id
            }
            .padding(.trailing, 10)
        }
    }

    private func packCard(_ item: StickerPackDiscoveryItem, rank: Int) -> some View {
        let featured = rank == 1 && sort == .trending
        return Button {
            openedPackID = item.id
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                if featured {
                    Label("#1 trending", systemImage: "chart.line.uptrend.xyaxis")
                        .font(.caption2.weight(.medium)).foregroundStyle(.green)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.green.opacity(0.08), in: Capsule())
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if !featured {
                        Text(rank, format: .number).font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.pack.name).font(featured ? .title2.bold() : .headline)
                        ownerAndCount(item.pack, showsAvatar: true)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.trailing, 88)
                HStack(spacing: 4) {
                    if item.previewStickers.isEmpty {
                        if let preview = item.pack.previewSticker {
                            StickerShopStickerSlot(
                                media: preview.media, emoji: preview.emoji, insetsArtwork: false)
                        } else {
                            Image(systemName: "square.stack").foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        ForEach(item.previewStickers.prefix(featured ? 4 : 5)) { preview in
                            StickerShopStickerSlot(
                                media: preview.media, emoji: preview.emoji, insetsArtwork: false)
                        }
                    }
                }
                .padding(.horizontal, 8)
                // The strip's square artwork slots already sit inside its padded band.
                .frame(height: featured ? 100 : 72)
                .background(StickerShopStyle.tile, in: RoundedRectangle(cornerRadius: 16))
                subscriberLabel(item).font(.caption2).foregroundStyle(.green)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(featured ? 16 : 14)
            .background(StickerShopStyle.card, in: RoundedRectangle(cornerRadius: 22))
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sticker-shop.pack.\(item.id)")
        .accessibilityLabel("View \(item.pack.name) pack")
        .overlay(alignment: .topTrailing) {
            StickerShopAddButton(library: library, pack: item.pack) { createdPackID = item.id }
                .controlSize(featured ? .large : .regular)
                .padding(.top, featured ? 38 : 10).padding(.trailing, 12)
        }
    }

    private func ownerAndCount(_ pack: StickerPackSummary, showsAvatar: Bool = false) -> some View {
        let owner = pack.ownerName ?? "#\(pack.ownerUid)"
        return HStack(spacing: 5) {
            if showsAvatar {
                Text(String(owner.prefix(1)).uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Color.accentColor, in: Circle())
            }
            Text(owner) + Text(" · ") + Text("\(pack.stickerCount) stickers")
        }
    }

    private func subscriberLabel(_ item: StickerPackDiscoveryItem) -> some View {
        HStack(spacing: 3) {
            Image(systemName: sort == .trending ? "chart.line.uptrend.xyaxis" : "person.2")
            if sort == .trending {
                Text(
                    "\(item.recentSubscriberCount) added in \(library.discoveryRecentWindowDays) days"
                )
            } else {
                Text("\(item.subscriberCount) subscribers")
            }
        }
    }

    private func highlighted(_ value: String) -> Text {
        var styled = AttributedString(value)
        var start = value.startIndex
        while !searchTerm.isEmpty,
            let match = value.range(
                of: searchTerm, options: [.caseInsensitive, .diacriticInsensitive],
                range: start..<value.endIndex),
            let lower = AttributedString.Index(match.lowerBound, within: styled),
            let upper = AttributedString.Index(match.upperBound, within: styled)
        {
            styled[lower..<upper].backgroundColor = Color.accentColor.opacity(0.18)
            start = match.upperBound
        }
        return Text(styled)
    }

    private func loadingPacks(isCompact: Bool) -> some View {
        VStack(spacing: 12) {
            ForEach(0..<3) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 4).frame(width: 110, height: 12)
                    RoundedRectangle(cornerRadius: 4).frame(width: 80, height: 8)
                    if !isCompact { RoundedRectangle(cornerRadius: 10).frame(height: 72) }
                }
                .foregroundStyle(.quaternary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .accessibilityLabel("Loading sticker packs…")
    }

    private func loadMore() async {
        await library.discover(query: query, sort: sort, more: true)
    }
}

private struct StickerDiscoveryCreateSheet: View {
    @ObservedObject var library: StickerLibrary
    let onCreated: (StickerPackSummary) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Pack name", text: $name)
                if isCreating { ProgressView("Creating Pack…") }
                if let error = library.error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("New Sticker Pack")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard !isCreating else { return }
                        isCreating = true
                        Task {
                            defer { isCreating = false }
                            if let pack = await library.createPack(name: name) { onCreated(pack) }
                        }
                    }
                    .disabled(
                        isCreating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(isCreating)
        #if os(macOS)
            .frame(width: 400, height: 240)
        #endif
    }
}
