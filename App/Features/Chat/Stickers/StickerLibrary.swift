import ChahuaAPI
import Combine
import Foundation

/// Account-scoped sticker snapshots shared by the composer and timeline preview.
@MainActor
final class StickerLibrary: ObservableObject {
    @Published private(set) var packs: [StickerPackSummary] = []
    @Published private(set) var favorites: [MessageStickerResponse] = []
    @Published private(set) var packDetails: [String: StickerPackDetailResponse] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var loadingPackIDs = Set<String>()
    @Published private(set) var pendingMutationIDs = Set<String>()
    @Published var error: String?

    private let apiClient: any ChahuaAPIClient
    private let onInvalidToken: @MainActor @Sendable () async -> Void
    private var generation = 0
    private var hasLoadedLibrary = false
    private var ownedPackIDs = Set<String>()
    // Keep server order independently of the displayed preference order, including ties.
    private var serverPacks: [StickerPackSummary] = []
    private var packOrder: [String: Int64] = [:]
    private var favoriteOverrides: [String: Bool] = [:]
    private var subscriptionOverrides: [String: Bool] = [:]
    private var stickerDetails: [String: StickerDetailResponse] = [:]
    private var refreshTask: Task<Void, Never>?
    private var packTasks: [String: Task<StickerPackDetailResponse?, Never>] = [:]
    private var packLoadIDs: [String: UUID] = [:]
    private var stickerTasks: [String: Task<StickerDetailResponse?, Never>] = [:]
    private var stickerLoadIDs: [String: UUID] = [:]
    // Successful mutations are replayed over an HTTP snapshot that began before them.
    private var refreshChanges: [Change] = []

    private enum Change {
        case favorite(MessageStickerResponse, Bool)
        case subscription(StickerPackSummary, Bool)
    }

    init(
        apiClient: any ChahuaAPIClient,
        onInvalidToken: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.apiClient = apiClient
        self.onInvalidToken = onInvalidToken
    }

    func refresh() async {
        guard !Task.isCancelled else { return }
        if let refreshTask {
            await refreshTask.value
            return
        }
        let requestGeneration = generation
        isLoading = true
        error = nil
        refreshChanges.removeAll()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == requestGeneration {
                    self.refreshTask = nil
                    self.isLoading = false
                    self.refreshChanges.removeAll()
                }
            }
            await self.loadLibrary(generation: requestGeneration)
        }
        refreshTask = task
        await task.value
    }

    func loadPack(_ id: String, force: Bool = false) async -> StickerPackDetailResponse? {
        guard !id.isEmpty, !Task.isCancelled else { return nil }
        let requestGeneration = generation
        if let task = packTasks[id] {
            let result = await task.value
            guard generation == requestGeneration, !Task.isCancelled else { return nil }
            return result.map(normalized)
        }
        if !force, let cached = packDetails[id] { return normalized(cached) }
        let requestID = UUID()
        packLoadIDs[id] = requestID
        loadingPackIDs.insert(id)
        error = nil
        let task = Task<StickerPackDetailResponse?, Never> { [weak self] in
            guard let self else { return nil }
            defer {
                if self.packLoadIDs[id] == requestID {
                    self.packLoadIDs.removeValue(forKey: id)
                    self.packTasks.removeValue(forKey: id)
                    self.loadingPackIDs.remove(id)
                }
            }
            do {
                try self.checkSession(requestGeneration)
                let response = try await self.apiClient.getStickerPack(id: id)
                try self.checkSession(requestGeneration)
                guard self.packLoadIDs[id] == requestID else { return nil }
                guard response.pack.id == id else { throw APIError.unexpectedResponse }
                let detail = self.normalized(response)
                self.packDetails[id] = detail
                return detail
            } catch {
                if self.packLoadIDs[id] == requestID {
                    await self.report(error, generation: requestGeneration, message: String(localized: "Couldn’t load sticker pack. Please try again."))
                }
                return nil
            }
        }
        packTasks[id] = task
        let result = await task.value
        guard generation == requestGeneration, !Task.isCancelled else { return nil }
        return result.map(normalized)
    }

    func loadSticker(_ id: String) async -> StickerDetailResponse? {
        guard !id.isEmpty, !Task.isCancelled else { return nil }
        let requestGeneration = generation
        if let task = stickerTasks[id] {
            let result = await task.value
            guard generation == requestGeneration, !Task.isCancelled else { return nil }
            return result.map(normalized)
        }
        if let cached = stickerDetails[id] { return normalized(cached) }
        let requestID = UUID()
        stickerLoadIDs[id] = requestID
        error = nil
        let task = Task<StickerDetailResponse?, Never> { [weak self] in
            guard let self else { return nil }
            defer {
                if self.stickerLoadIDs[id] == requestID {
                    self.stickerLoadIDs.removeValue(forKey: id)
                    self.stickerTasks.removeValue(forKey: id)
                }
            }
            do {
                try self.checkSession(requestGeneration)
                let response = try await self.apiClient.getSticker(id: id)
                try self.checkSession(requestGeneration)
                guard self.stickerLoadIDs[id] == requestID else { return nil }
                guard response.sticker.id == id else { throw APIError.unexpectedResponse }
                let detail = self.normalized(response)
                self.stickerDetails[id] = detail
                return detail
            } catch {
                if self.stickerLoadIDs[id] == requestID {
                    await self.report(error, generation: requestGeneration, message: String(localized: "Couldn’t load sticker. Please try again."))
                }
                return nil
            }
        }
        stickerTasks[id] = task
        let result = await task.value
        guard generation == requestGeneration, !Task.isCancelled else { return nil }
        return result.map(normalized)
    }

    func isFavorite(_ sticker: MessageStickerResponse) -> Bool {
        if let override = favoriteOverrides[sticker.id] { return override }
        if hasLoadedLibrary { return false }
        return sticker.isFavorited ?? false
    }

    func isOwnedPack(_ id: String) -> Bool {
        ownedPackIDs.contains(id)
    }

    func toggleFavorite(_ sticker: MessageStickerResponse) async {
        guard !sticker.id.isEmpty, !pendingMutationIDs.contains(sticker.id), !Task.isCancelled else { return }
        let requestGeneration = generation
        let favorite = !isFavorite(sticker)
        pendingMutationIDs.insert(sticker.id)
        error = nil
        defer {
            if generation == requestGeneration { pendingMutationIDs.remove(sticker.id) }
        }
        do {
            try await apiClient.setStickerFavorite(id: sticker.id, favorite: favorite)
            try checkSession(requestGeneration)
            favoriteOverrides[sticker.id] = favorite
            updateFavorite(sticker, favorite: favorite, in: &favorites)
            if isLoading { refreshChanges.append(.favorite(sticker, favorite)) }
            normalizeCaches()
        } catch {
            await report(error, generation: requestGeneration, message: String(localized: "Couldn’t update favorite sticker. Please try again."))
        }
    }

    func setSubscribed(_ subscribed: Bool, pack: StickerPackSummary) async -> Bool {
        guard !pack.id.isEmpty, !isOwnedPack(pack.id), !pendingMutationIDs.contains(pack.id), !Task.isCancelled else { return false }
        let requestGeneration = generation
        pendingMutationIDs.insert(pack.id)
        error = nil
        defer {
            if generation == requestGeneration { pendingMutationIDs.remove(pack.id) }
        }
        do {
            try await apiClient.setStickerPackSubscription(id: pack.id, subscribed: subscribed)
            try checkSession(requestGeneration)
            subscriptionOverrides[pack.id] = subscribed
            updateSubscription(pack, subscribed: subscribed, in: &serverPacks)
            if isLoading { refreshChanges.append(.subscription(pack, subscribed)) }
            sortPacks()
            normalizeCaches()
            return true
        } catch {
            await report(error, generation: requestGeneration, message: String(localized: "Couldn’t update sticker pack subscription. Please try again."))
            return false
        }
    }

    func setPackOrder(_ order: [StickerPackOrderItem]) {
        packOrder.removeAll(keepingCapacity: true)
        for item in order { packOrder[item.stickerPackId] = item.lastUsedOn }
        sortPacks()
    }

    func reset() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        for task in packTasks.values { task.cancel() }
        for task in stickerTasks.values { task.cancel() }
        packTasks.removeAll()
        packLoadIDs.removeAll()
        stickerTasks.removeAll()
        stickerLoadIDs.removeAll()
        ownedPackIDs.removeAll()
        serverPacks.removeAll()
        packOrder.removeAll()
        favoriteOverrides.removeAll()
        subscriptionOverrides.removeAll()
        stickerDetails.removeAll()
        refreshChanges.removeAll()
        packs.removeAll()
        favorites.removeAll()
        packDetails.removeAll()
        loadingPackIDs.removeAll()
        pendingMutationIDs.removeAll()
        hasLoadedLibrary = false
        isLoading = false
        error = nil
    }

    private func loadLibrary(generation requestGeneration: Int) async {
        do {
            try checkSession(requestGeneration)
            async let ownedRequest = apiClient.listOwnedStickerPacks()
            async let subscribedRequest = apiClient.listSubscribedStickerPacks()
            async let favoritesRequest = apiClient.listFavoriteStickers()
            let (owned, subscribed, favoriteStickers) = try await (ownedRequest, subscribedRequest, favoritesRequest)
            try checkSession(requestGeneration)
            ownedPackIDs = Set(owned.map(\.id))
            var seen = Set<String>()
            var freshPacks = (owned + subscribed).filter { seen.insert($0.id).inserted }
            seen.removeAll(keepingCapacity: true)
            var freshFavorites = favoriteStickers.filter { seen.insert($0.id).inserted }.map { withFavorite($0, true) }
            for change in refreshChanges {
                switch change {
                case .favorite(let sticker, let favorite):
                    updateFavorite(sticker, favorite: favorite, in: &freshFavorites)
                case .subscription(let pack, let subscribed):
                    if !ownedPackIDs.contains(pack.id) {
                        updateSubscription(pack, subscribed: subscribed, in: &freshPacks)
                    }
                }
            }
            serverPacks = freshPacks
            favorites = freshFavorites
            favoriteOverrides = Dictionary(uniqueKeysWithValues: freshFavorites.map { ($0.id, true) })
            subscriptionOverrides.removeAll()
            hasLoadedLibrary = true
            sortPacks()
            normalizeCaches()
        } catch {
            await report(error, generation: requestGeneration, message: String(localized: "Couldn’t load stickers. Please try again."))
        }
    }

    private func updateFavorite(_ sticker: MessageStickerResponse, favorite: Bool, in values: inout [MessageStickerResponse]) {
        if favorite {
            let updated = withFavorite(sticker, true)
            if let index = values.firstIndex(where: { $0.id == sticker.id }) {
                values[index] = updated
            } else {
                values.insert(updated, at: 0)
            }
        } else {
            values.removeAll { $0.id == sticker.id }
        }
    }

    private func updateSubscription(_ pack: StickerPackSummary, subscribed: Bool, in values: inout [StickerPackSummary]) {
        if subscribed {
            var updated = pack
            updated.isSubscribed = true
            if let index = values.firstIndex(where: { $0.id == pack.id }) {
                values[index] = updated
            } else {
                values.append(updated)
            }
        } else {
            values.removeAll { $0.id == pack.id }
        }
    }

    private func sortPacks() {
        packs = serverPacks.enumerated().sorted { lhs, rhs in
            switch (packOrder[lhs.element.id], packOrder[rhs.element.id]) {
            case let (left?, right?) where left != right: left > right
            case (_?, nil): true
            case (nil, _?): false
            default: lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private func normalized(_ pack: StickerPackSummary) -> StickerPackSummary {
        var result = pack
        if let override = subscriptionOverrides[pack.id] {
            result.isSubscribed = override
        } else if let known = serverPacks.first(where: { $0.id == pack.id }) {
            result.isSubscribed = known.isSubscribed
        } else if hasLoadedLibrary {
            result.isSubscribed = false
        }
        return result
    }

    private func normalized(_ detail: StickerPackDetailResponse) -> StickerPackDetailResponse {
        StickerPackDetailResponse(pack: normalized(detail.pack), stickers: detail.stickers.map { withFavorite($0, isFavorite($0)) })
    }

    private func normalized(_ detail: StickerDetailResponse) -> StickerDetailResponse {
        StickerDetailResponse(sticker: withFavorite(detail.sticker, isFavorite(detail.sticker)), packs: detail.packs.map(normalized))
    }

    private func withFavorite(_ sticker: MessageStickerResponse, _ favorite: Bool) -> MessageStickerResponse {
        guard sticker.isFavorited != favorite else { return sticker }
        return MessageStickerResponse(
            id: sticker.id, emoji: sticker.emoji, createdAt: sticker.createdAt, isFavorited: favorite,
            media: sticker.media, name: sticker.name, description: sticker.description
        )
    }

    private func normalizeCaches() {
        packDetails = packDetails.mapValues(normalized)
        stickerDetails = stickerDetails.mapValues(normalized)
    }

    private func checkSession(_ requestGeneration: Int) throws {
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
    }

    private func report(_ failure: Error, generation requestGeneration: Int, message: String) async {
        guard generation == requestGeneration, !(failure is CancellationError), !Task.isCancelled else { return }
        error = message
        if case APIError.invalidToken = failure { await onInvalidToken() }
    }
}
