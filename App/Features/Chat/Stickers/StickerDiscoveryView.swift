import ChahuaAPI
import SwiftUI

/// Shared discovery destination for the composer and sticker management.
struct StickerDiscoveryView: View {
    @ObservedObject var library: StickerLibrary
    @State private var query = ""
    @State private var sort = StickerPackSort.trending
    @State private var showsCreatePack = false
    @State private var createdPackID: String?

    private var request: Request {
        Request(query: query, sort: sort, accountID: library.accountID)
    }

    private struct Request: Hashable {
        let query: String
        let sort: StickerPackSort
        let accountID: Int32?
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sort sticker packs", selection: $sort) {
                Text("Trending").tag(StickerPackSort.trending)
                Text("Popular").tag(StickerPackSort.subscribers)
            }
            .pickerStyle(.segmented)
            .padding()
            if library.isDiscovering && library.hasLoadedDiscovery && !library.discoveryPageRequest
            {
                ProgressView().controlSize(.small).padding(.bottom, 8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        Color.clear.frame(height: 0).id("discovery-top")
                        if library.isDiscovering && !library.hasLoadedDiscovery {
                            ProgressView("Loading sticker packs…")
                                .frame(maxWidth: .infinity).padding()
                        }
                        ForEach(library.discoveryPacks) { item in
                            discoveryRow(item)
                            Divider()
                        }
                        if let error = library.discoveryError {
                            VStack(spacing: 8) {
                                Text(error).foregroundStyle(.secondary)
                                Button("Retry") { Task { await library.retryDiscovery() } }
                            }
                            .frame(maxWidth: .infinity)
                        } else if library.hasLoadedDiscovery && !library.isDiscovering
                            && library.discoveryPacks.isEmpty
                        {
                            ContentUnavailableView {
                                Label("No Sticker Packs", systemImage: "square.stack")
                            } description: {
                                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("No sticker packs are available yet.")
                                } else {
                                    Text("No packs match your search.")
                                }
                            } actions: {
                                if !query.isEmpty { Button("Clear search") { query = "" } }
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
                            .frame(maxWidth: .infinity)
                            .task(id: cursor) { await loadMore() }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
                .onChange(of: library.discoveryRevision) { _, _ in
                    proxy.scrollTo("discovery-top", anchor: .top)
                }
                .refreshable { await library.discover(query: query, sort: sort) }
            }
        }
        .navigationTitle("Discover Stickers")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $query, prompt: "Search sticker packs")
        .onChange(of: query) { _, value in
            if value.count > 255 { query = String(value.prefix(255)) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Create Pack", systemImage: "plus") { showsCreatePack = true }
                    .disabled(library.pendingMutationIDs.contains("create-sticker-pack"))
            }
        }
        .task(id: request) {
            // Search is server-side and debounced; cancellation never replaces newer rows.
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await library.discover(query: query, sort: sort)
        }
        .onChange(of: request) { _, _ in library.cancelDiscovery() }
        .onDisappear { library.cancelDiscovery() }
        .onChange(of: library.accountID) { _, _ in
            query = ""
            sort = .trending
            showsCreatePack = false
            createdPackID = nil
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
            }
        }
        .alert(
            "Stickers",
            isPresented: Binding(
                get: { library.error != nil && !showsCreatePack },
                set: { if !$0 { library.error = nil } })
        ) {
            Button("OK") { library.error = nil }
        } message: {
            Text(library.error ?? "")
        }
    }

    private func loadMore() async {
        await library.discover(query: query, sort: sort, more: true)
    }

    private func discoveryRow(_ item: StickerPackDiscoveryItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                NavigationLink {
                    StickerDiscoveryPackView(library: library, packID: item.id)
                } label: {
                    Text(item.pack.name).font(.headline).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 8)
                Button(item.pack.isSubscribed ? "Subscribed" : "Subscribe") {
                    Task { _ = await library.setSubscribed(true, pack: item.pack) }
                }
                .buttonStyle(.bordered)
                .disabled(
                    item.pack.isSubscribed || item.pack.ownerUid == library.accountID
                        || library.isOwnedPack(item.id)
                        || library.pendingMutationIDs.contains(item.id))
                if library.pendingMutationIDs.contains(item.id) {
                    ProgressView().controlSize(.small)
                }
            }
            Text("\(item.pack.stickerCount) stickers · \(subscriberDescription(item))")
                .font(.caption).foregroundStyle(.secondary)
            NavigationLink {
                StickerDiscoveryPackView(library: library, packID: item.id)
            } label: {
                HStack(spacing: 8) {
                    ForEach(item.previewStickers) { sticker in
                        StickerMediaView(media: sticker.media, emoji: sticker.emoji)
                            .frame(maxWidth: .infinity)
                            .frame(height: 72)
                    }
                    if item.previewStickers.isEmpty {
                        Image(systemName: "square.stack")
                            .frame(maxWidth: .infinity).frame(height: 72)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View \(item.pack.name) pack")
            NavigationLink("View Pack") {
                StickerDiscoveryPackView(library: library, packID: item.id)
            }
            .font(.subheadline)
        }
    }

    private func subscriberDescription(_ item: StickerPackDiscoveryItem) -> String {
        if sort == .trending {
            return AppLanguage.localized(
                "\(item.recentSubscriberCount) new subscribers in \(library.discoveryRecentWindowDays) days"
            )
        }
        return AppLanguage.localized("\(item.subscriberCount) subscribers")
    }
}

private struct StickerDiscoveryPackView: View {
    @ObservedObject var library: StickerLibrary
    let packID: String

    private var detail: StickerPackDetailResponse? { library.packDetails[packID] }
    @State private var selectedSticker: Preview?

    private struct Preview: Identifiable {
        let id: String
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let detail {
                    Text(detail.pack.name).font(.title2.bold())
                    Text("\(detail.pack.stickerCount) stickers").foregroundStyle(.secondary)
                    if let description = detail.pack.description, !description.isEmpty {
                        Text(description).foregroundStyle(.secondary)
                    }
                    if let uid = library.accountID, detail.pack.ownerUid == uid {
                        NavigationLink("Manage Pack") {
                            StickerPackDetailSettingsView(
                                library: library, currentUserID: uid, packID: packID)
                        }
                    } else {
                        Button(detail.pack.isSubscribed ? "Unsubscribe" : "Subscribe") {
                            Task {
                                _ = await library.setSubscribed(
                                    !detail.pack.isSubscribed, pack: detail.pack)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(library.pendingMutationIDs.contains(packID))
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], spacing: 8) {
                        ForEach(detail.stickers, id: \.id) { sticker in
                            Button {
                                selectedSticker = Preview(id: sticker.id)
                            } label: {
                                StickerMediaView(media: sticker.media, emoji: sticker.emoji)
                                    .frame(height: 80).frame(maxWidth: .infinity)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(sticker.name ?? sticker.emoji)
                        }
                    }
                    if detail.stickers.isEmpty {
                        Text("No stickers in this pack").foregroundStyle(.secondary)
                    }
                } else if library.loadingPackIDs.contains(packID) {
                    ProgressView("Loading sticker pack…")
                }
                if let error = library.error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") { Task { _ = await library.loadPack(packID, force: true) } }
                }
            }
            .padding().frame(maxWidth: .infinity)
        }
        .navigationTitle(detail?.pack.name ?? "Sticker Pack")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: library.accountID) {
            guard library.accountID != nil else { return }
            _ = await library.loadPack(packID)
        }
        .refreshable { _ = await library.loadPack(packID, force: true) }
        .sheet(item: $selectedSticker) { sticker in
            if let uid = library.accountID {
                StickerPackSheet(stickerID: sticker.id, library: library, currentUserID: uid)
            }
        }
        .onChange(of: library.accountID) { _, _ in selectedSticker = nil }
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
