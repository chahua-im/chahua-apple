import ChahuaAPI
import SwiftUI

struct StickerShopPackDetailView: View {
    @ObservedObject var library: StickerLibrary
    let packID: String
    var discoveryItem: StickerPackDiscoveryItem? = nil
    var isWide = false

    @State private var preview: PreviewSelection?
    @State private var showsEditor = false
    @State private var loadFailure: String?
    @ScaledMetric(relativeTo: .title) private var phoneTitleSize: CGFloat = 28
    @ScaledMetric(relativeTo: .title) private var wideTitleSize: CGFloat = 30

    private struct Request: Hashable {
        let accountID: Int32?
        let packID: String
    }

    private struct PreviewSelection {
        let request: Request
        let stickerID: String
    }

    private var request: Request { Request(accountID: library.accountID, packID: packID) }
    private var detail: StickerPackDetailResponse? { library.packDetails[packID] }

    // The detail endpoint has no ranking fields. Keep the discovery snapshot's real
    // statistics rather than manufacturing counts from the subscription button state.
    private var ranking: StickerPackDiscoveryItem? {
        library.discoveryPacks.first { $0.id == packID }
            ?? discoveryItem.flatMap { $0.id == packID ? $0 : nil }
    }

    private var selectedSticker: MessageStickerResponse? {
        guard let preview, preview.request == request else { return nil }
        return detail?.stickers.first { $0.id == preview.stickerID }
    }

    private static let wideColumns = [GridItem(.adaptive(minimum: 84, maximum: 132), spacing: 12)]
    private static let phoneColumns = Array(
        repeating: GridItem(.flexible(), spacing: 10), count: 4)

    private var columns: [GridItem] { isWide ? Self.wideColumns : Self.phoneColumns }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: isWide ? 20 : 24) {
                    if let detail {
                        if isWide {
                            wideHeader(detail, width: geometry.size.width)
                        } else {
                            phoneHeader(detail, width: geometry.size.width)
                        }
                        stickerGrid(detail)
                        if library.loadingPackIDs.contains(packID) {
                            ProgressView().controlSize(.small)
                        }
                        if let loadFailure {
                            retryContent(loadFailure)
                        }
                        if loadFailure == nil, let error = library.error {
                            Text(error).font(.callout).foregroundStyle(.secondary)
                        }
                    } else if let loadFailure {
                        ContentUnavailableView {
                            Label(
                                "Couldn’t Load Sticker Pack",
                                systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(loadFailure)
                        } actions: {
                            retryButton
                        }
                    } else {
                        ProgressView("Loading sticker pack…")
                            .frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
                .padding(.horizontal, isWide ? 24 : 16)
                .padding(.top, isWide ? 6 : 16)
                .padding(.bottom, isWide ? 24 : 16)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await load(force: true) }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !isWide, let pack = detail?.pack {
                    bottomBar(pack)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if isWide {
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        packActions
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .frame(minHeight: 64)
                }
            }
            .blur(radius: selectedSticker == nil ? 0 : 12)
            .allowsHitTesting(selectedSticker == nil)
            .accessibilityHidden(selectedSticker != nil)
            .overlay {
                if let sticker = selectedSticker, let pack = detail?.pack {
                    StickerShopStickerPreview(
                        library: library, sticker: sticker, pack: pack,
                        isWide: isWide, onDismiss: { preview = nil }
                    )
                    .id(sticker.id)
                }
            }
        }
        .background(StickerShopStyle.canvas)
        .navigationTitle("")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !isWide {
                ToolbarItemGroup(placement: .primaryAction) { packActions }
            }
        }
        .navigationDestination(isPresented: $showsEditor) {
            if let uid = library.accountID, let pack = detail?.pack, isOwner(pack) {
                StickerPackDetailSettingsView(library: library, currentUserID: uid, packID: packID)
                    #if os(iOS)
                        .toolbar(.visible, for: .navigationBar)
                    #else
                        .toolbar(.visible, for: .windowToolbar)
                    #endif
            }
        }
        .task(id: request) { await load() }
        .onChange(of: request) { _, _ in
            preview = nil
            showsEditor = false
            loadFailure = nil
        }
        .onDisappear { preview = nil }
    }

    @ViewBuilder
    private var packActions: some View {
        if let pack = detail?.pack {
            if let shareURL {
                ShareLink(item: shareURL) {
                    Label("Share Pack", systemImage: "square.and.arrow.up")
                }
                .labelStyle(.iconOnly)
                .disabled(selectedSticker != nil)
            }
            if pack.isSubscribed && !isOwner(pack) {
                Menu {
                    Button(
                        "Remove from My Packs", systemImage: "minus.circle", role: .destructive
                    ) {
                        Task { _ = await library.setSubscribed(false, pack: pack) }
                    }
                    .disabled(library.pendingMutationIDs.contains(pack.id))
                } label: {
                    Label("Pack Options", systemImage: "ellipsis")
                }
                .labelStyle(.iconOnly)
                .menuIndicator(.hidden)
                .disabled(selectedSticker != nil)
            }
            if isWide {
                addButton(pack).disabled(selectedSticker != nil)
            }
        }
    }

    private var shareURL: URL? {
        // A public web route exists at /stickers/:packId. Do not expose a share
        // action for packs whose public visibility is not known from discovery.
        guard ranking?.visibility == .public else { return nil }
        return AppConfiguration.applicationURL.appendingPathComponent("stickers")
            .appendingPathComponent(packID)
    }

    private func isOwner(_ pack: StickerPackSummary) -> Bool {
        pack.ownerUid == library.accountID || library.isOwnedPack(pack.id)
    }

    private func addButton(_ pack: StickerPackSummary) -> some View {
        StickerShopAddButton(
            library: library, pack: pack, prominent: true, onEdit: { showsEditor = true }
        )
        .controlSize(isWide ? .regular : .large)
    }

    private func phoneHeader(_ detail: StickerPackDetailResponse, width: CGFloat) -> some View {
        VStack(spacing: 12) {
            let side = min(108, max(0, (width - 56) / 3))
            HStack(spacing: 12) {
                ForEach(detail.stickers.prefix(3), id: \.id) { sticker in
                    heroSticker(sticker)
                        .frame(width: side, height: side)
                        .background(
                            StickerShopStyle.card, in: RoundedRectangle(cornerRadius: 24))
                }
            }
            packText(detail.pack, centered: true)
            statistics(detail.pack)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 62)
                .background(StickerShopStyle.card, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func wideHeader(_ detail: StickerPackDetailResponse, width: CGFloat) -> some View {
        Group {
            if width >= 620 {
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        packText(detail.pack, centered: false)
                        statistics(detail.pack)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    wideHeroes(detail, side: min(150, max(112, (width - 104) * 0.24)))
                }
                .padding(28)
            } else {
                // Keep real stats legible when the split's detail pane is narrow;
                // only the compact header moves them beneath the text/hero row.
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 16) {
                        packText(detail.pack, centered: false)
                        wideHeroes(detail, side: min(112, max(60, (width - 88) * 0.2)))
                    }
                    statistics(detail.pack)
                }
                .padding(20)
            }
        }
        .background(StickerShopStyle.card, in: RoundedRectangle(cornerRadius: 28))
    }

    private func wideHeroes(_ detail: StickerPackDetailResponse, side: CGFloat) -> some View {
        HStack(spacing: 12) {
            ForEach(detail.stickers.prefix(2), id: \.id) { sticker in
                heroSticker(sticker)
                    .frame(width: side, height: side)
                    .background(
                        StickerShopStyle.tile, in: RoundedRectangle(cornerRadius: 28))
            }
        }
    }

    private func packText(_ pack: StickerPackSummary, centered: Bool) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 6) {
            Text(pack.name)
                .font(.system(size: isWide ? wideTitleSize : phoneTitleSize, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("By \(pack.ownerName ?? String(pack.ownerUid))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let description = pack.description,
                !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    private func statistics(_ pack: StickerPackSummary) -> some View {
        HStack(spacing: isWide ? 20 : 0) {
            statistic(pack.stickerCount, label: Text("Stickers"))
            if let ranking {
                if !isWide { Divider().frame(height: 30) }
                statistic(ranking.subscriberCount, label: Text("Subscribers"))
                if !isWide { Divider().frame(height: 30) }
                VStack(alignment: isWide ? .leading : .center, spacing: 2) {
                    Text(verbatim: "+" + ranking.recentSubscriberCount.formatted(.number))
                        .font(.headline)
                        .foregroundStyle(.green)
                    Text("Last \(library.discoveryRecentWindowDays) days")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: isWide ? nil : .infinity, alignment: isWide ? .leading : .center)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    Text(
                        "\(ranking.recentSubscriberCount) new subscribers in \(library.discoveryRecentWindowDays) days"
                    )
                )
            }
        }
    }

    private func statistic(_ value: Int, label: Text) -> some View {
        VStack(alignment: isWide ? .leading : .center, spacing: 2) {
            Text(value, format: .number.notation(.compactName).precision(.significantDigits(1...3)))
                .font(.headline)
            label.font(.caption).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .frame(maxWidth: isWide ? nil : .infinity, alignment: isWide ? .leading : .center)
        .accessibilityElement(children: .combine)
    }

    private func heroSticker(_ sticker: MessageStickerResponse) -> some View {
        Button {
            present(sticker)
        } label: {
            StickerShopStickerSlot(media: sticker.media, emoji: sticker.emoji)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sticker.name ?? sticker.emoji)
    }

    @ViewBuilder
    private func stickerGrid(_ detail: StickerPackDetailResponse) -> some View {
        if detail.stickers.isEmpty {
            ContentUnavailableView("No stickers in this pack", systemImage: "square.stack")
                .frame(maxWidth: .infinity, minHeight: 180)
        } else {
            LazyVGrid(columns: columns, spacing: isWide ? 12 : 10) {
                ForEach(detail.stickers, id: \.id) { sticker in
                    heroSticker(sticker)
                        .background(
                            StickerShopStyle.card,
                            in: RoundedRectangle(cornerRadius: isWide ? 20 : 18)
                        )
                        .contextMenu {
                            Button {
                                Task { await library.toggleFavorite(sticker) }
                            } label: {
                                Label(
                                    library.isFavorite(sticker)
                                        ? LocalizedStringKey("Remove from Favorites")
                                        : LocalizedStringKey("Add to Favorites"),
                                    systemImage: library.isFavorite(sticker)
                                        ? "heart.slash" : "heart"
                                )
                            }
                            .disabled(library.pendingMutationIDs.contains(sticker.id))
                        }
                }
            }
        }
    }

    private func bottomBar(_ pack: StickerPackSummary) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(pack.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(pack.stickerCount) stickers")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            addButton(pack)
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(minHeight: 64)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func present(_ sticker: MessageStickerResponse) {
        preview = PreviewSelection(request: request, stickerID: sticker.id)
    }

    private var retryButton: some View {
        Button("Retry") { Task { await load(force: true) } }
            .disabled(library.loadingPackIDs.contains(packID))
    }

    private func retryContent(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            retryButton
        }
        .multilineTextAlignment(.center)
    }

    private func load(force: Bool = false) async {
        let loadingRequest = request
        guard loadingRequest.accountID != nil else { return }
        loadFailure = nil
        let result = await library.loadPack(loadingRequest.packID, force: force)
        guard request == loadingRequest, !Task.isCancelled else { return }
        if result == nil {
            loadFailure =
                library.error
                ?? AppLanguage.localized("Couldn’t load sticker pack. Please try again.")
        }
    }
}

private struct StickerShopStickerPreview: View {
    @ObservedObject var library: StickerLibrary
    let sticker: MessageStickerResponse
    let pack: StickerPackSummary
    let isWide: Bool
    let onDismiss: () -> Void

    private var isFavorite: Bool { library.isFavorite(sticker) }
    private var canAddPack: Bool {
        !pack.isSubscribed && pack.ownerUid != library.accountID && !library.isOwnedPack(pack.id)
    }

    var body: some View {
        GeometryReader { geometry in
            let side = max(
                0, min(isWide ? 260 : 240, geometry.size.width - 48, geometry.size.height - 200))
            ZStack {
                Color.black.opacity(0.2)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
                    .accessibilityHidden(true)
                VStack(spacing: 12) {
                    StickerShopStickerSlot(media: sticker.media, emoji: sticker.emoji)
                        .frame(width: side, height: side)
                        .accessibilityLabel(sticker.name ?? sticker.emoji)
                        .allowsHitTesting(false)
                    if !sticker.emoji.isEmpty {
                        Text(sticker.emoji)
                            .font(.subheadline)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                    }
                    VStack(spacing: 0) {
                        Button {
                            Task { await library.toggleFavorite(sticker) }
                        } label: {
                            HStack {
                                Text(
                                    isFavorite
                                        ? LocalizedStringKey("Remove from Favorites")
                                        : LocalizedStringKey("Add to Favorites")
                                )
                                Spacer(minLength: 12)
                                if library.pendingMutationIDs.contains(sticker.id) {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                                        .foregroundStyle(.pink)
                                }
                            }
                            .padding(12)
                            .contentShape(Rectangle())
                        }
                        .disabled(library.pendingMutationIDs.contains(sticker.id))
                        if canAddPack {
                            Divider()
                            Button {
                                Task { _ = await library.setSubscribed(true, pack: pack) }
                            } label: {
                                HStack {
                                    Text("Add Whole Pack")
                                    Spacer(minLength: 12)
                                    if library.pendingMutationIDs.contains(pack.id) {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "plus").foregroundStyle(Color.accentColor)
                                    }
                                }
                                .padding(12)
                                .contentShape(Rectangle())
                            }
                            .disabled(library.pendingMutationIDs.contains(pack.id))
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .frame(width: max(0, min(260, geometry.size.width - 48)))
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .transaction {
                        $0.animation = nil
                        $0.disablesAnimations = true
                    }
                    if let error = library.error {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 260)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack {
                    HStack {
                        Spacer()
                        Button("Close Preview", systemImage: "xmark", action: onDismiss)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.circle)
                            .keyboardShortcut(.cancelAction)
                    }
                    Spacer()
                }
                .padding(16)
            }
            .accessibilityAddTraits(.isModal)
        }
    }
}
