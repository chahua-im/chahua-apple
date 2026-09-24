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
    @Published private(set) var pinnedReactions = StickerPreferences.defaultPinnedReactions
    @Published private(set) var autoSortPacks = false
    @Published private(set) var autoSortFavorites = false
    @Published var error: String?

    private let apiClient: any ChahuaAPIClient
    private let onInvalidToken: @MainActor @Sendable () async -> Void
    private var generation = 0
    private var hasLoadedLibrary = false
    private var accountID: Int32?
    private var preferences = StickerPreferences()
    private var ownedPackIDs = Set<String>()
    // Keep server order independently of the displayed preference order, including ties.
    private var serverPacks: [StickerPackSummary] = []
    private var packOrder: [String: Int64] = [:]
    private var favoriteOverrides: [String: Bool] = [:]
    private var serverFavoriteIDs: [String] = []
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
        case packCreated(StickerPackSummary)
        case packUpdated(StickerPackSummary)
        case packDeleted(String)
        case stickerAdded(packID: String, sticker: MessageStickerResponse)
        case stickerRemoved(packID: String, stickerID: String)
    }

    init(
        apiClient: any ChahuaAPIClient,
        onInvalidToken: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.apiClient = apiClient
        self.onInvalidToken = onInvalidToken
    }

    func setAccount(_ accountID: Int32?) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        MessageReactionPreferences.setActiveAccount(accountID)
        guard let accountID else {
            preferences = StickerPreferences()
            pinnedReactions = StickerPreferences.defaultPinnedReactions
            autoSortPacks = false
            autoSortFavorites = false
            return
        }
        preferences = StickerPreferences.load(for: accountID)
        pinnedReactions = preferences.pinnedReactions
        autoSortPacks = preferences.autoSortPacks
        autoSortFavorites = preferences.autoSortFavorites
        sortFavorites()
    }

    func setPinnedReactions(_ reactions: [String]) {
        preferences.pinnedReactions = StickerPreferences.normalizedPinnedReactions(
            reactions.joined())
        pinnedReactions = preferences.pinnedReactions
        savePreferences()
        MessageReactionPreferences.pinnedReactionsDidChange()
    }

    func setAutoSortPacks(_ enabled: Bool) {
        guard autoSortPacks != enabled else { return }
        preferences.autoSortPacks = enabled
        autoSortPacks = enabled
        savePreferences()
    }

    func setAutoSortFavorites(_ enabled: Bool) {
        guard autoSortFavorites != enabled else { return }
        preferences.autoSortFavorites = enabled
        autoSortFavorites = enabled
        savePreferences()
        sortFavorites()
    }

    func recordFavoriteUse(_ sticker: MessageStickerResponse) {
        guard autoSortFavorites, favorites.contains(where: { $0.id == sticker.id }) else { return }
        preferences.favoriteOrder[sticker.id] = Self.currentTimestamp()
        savePreferences()
        sortFavorites()
    }

    func recordPackUse(_ packID: String) async {
        guard
            autoSortPacks,
            packs.prefix(StickerPreferences.automaticSortLimit).contains(where: { $0.id == packID })
        else { return }
        _ = await updatePackOrder([
            StickerPackOrderUpdate(
                stickerPackId: packID, lastUsedOn: Self.currentTimestamp(), isAutoSort: true)
        ])
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
                    await self.report(
                        error, generation: requestGeneration,
                        message: AppLanguage.localized(
                            "Couldn’t load sticker pack. Please try again."))
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
                    await self.report(
                        error, generation: requestGeneration,
                        message: AppLanguage.localized("Couldn’t load sticker. Please try again."))
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
        guard !sticker.id.isEmpty, !pendingMutationIDs.contains(sticker.id), !Task.isCancelled
        else { return }
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
            updateFavoriteServerOrder(sticker.id, favorite: favorite)
            if isLoading { refreshChanges.append(.favorite(sticker, favorite)) }
            sortFavorites()
            normalizeCaches()
        } catch {
            await report(
                error, generation: requestGeneration,
                message: AppLanguage.localized(
                    "Couldn’t update favorite sticker. Please try again."))
        }
    }

    func setSubscribed(_ subscribed: Bool, pack: StickerPackSummary) async -> Bool {
        guard !pack.id.isEmpty, !isOwnedPack(pack.id), !pendingMutationIDs.contains(pack.id),
            !Task.isCancelled
        else { return false }
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
            await report(
                error, generation: requestGeneration,
                message: AppLanguage.localized(
                    "Couldn’t update sticker pack subscription. Please try again."))
            return false
        }
    }

    func setPackOrder(_ order: [StickerPackOrderItem]) {
        packOrder.removeAll(keepingCapacity: true)
        for item in order { packOrder[item.stickerPackId] = item.lastUsedOn }
        sortPacks()
    }

    func createPack(name: String, description: String? = nil) async -> StickerPackSummary? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !pendingMutationIDs.contains("create-sticker-pack"), !Task.isCancelled
        else { return nil }
        let requestGeneration = generation
        pendingMutationIDs.insert("create-sticker-pack")
        error = nil
        defer {
            if generation == requestGeneration { pendingMutationIDs.remove("create-sticker-pack") }
        }
        do {
            var created = try await apiClient.createStickerPack(
                name: name, description: trimmedOptional(description))
            try checkSession(requestGeneration)
            created.isSubscribed = true
            ownedPackIDs.insert(created.id)
            subscriptionOverrides.removeValue(forKey: created.id)
            replacePack(created)
            if isLoading { refreshChanges.append(.packCreated(created)) }
            return normalized(created)
        } catch {
            await report(
                error, generation: requestGeneration,
                message: AppLanguage.localized("Couldn’t create sticker pack. Please try again."))
            return nil
        }
    }

    func updatePack(id: String, name: String?, description: String? = nil) async
        -> StickerPackSummary?
    {
        let name = name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard
            !id.isEmpty,
            name != "",
            !pendingMutationIDs.contains(id),
            !Task.isCancelled
        else { return nil }
        let requestGeneration = generation
        pendingMutationIDs.insert(id)
        error = nil
        defer {
            if generation == requestGeneration { pendingMutationIDs.remove(id) }
        }
        do {
            let updated = try await apiClient.updateStickerPack(
                id: id, name: name, description: trimmedOptional(description))
            try checkSession(requestGeneration)
            replacePack(updated)
            if isLoading { refreshChanges.append(.packUpdated(updated)) }
            return normalized(updated)
        } catch {
            await report(
                error, generation: requestGeneration,
                message: AppLanguage.localized("Couldn’t update sticker pack. Please try again."))
            return nil
        }
    }

    func deletePack(id: String) async -> Bool {
        guard !id.isEmpty, !pendingMutationIDs.contains(id), !Task.isCancelled else { return false }
        let requestGeneration = generation
        pendingMutationIDs.insert(id)
        error = nil
        defer {
            if generation == requestGeneration { pendingMutationIDs.remove(id) }
        }
        do {
            try await apiClient.deleteStickerPack(id: id)
            try checkSession(requestGeneration)
            removePack(id)
            if isLoading { refreshChanges.append(.packDeleted(id)) }
            return true
        } catch {
            await report(
                error, generation: requestGeneration,
                message: AppLanguage.localized("Couldn’t delete sticker pack. Please try again."))
            return false
        }
    }

    func addSticker(
        toPack id: String, upload: StickerUpload, emoji: String, name: String? = nil,
        description: String? = nil
    ) async -> MessageStickerResponse? {
        let emoji = StickerPreferences.normalizedEmojiSequences(
            emoji, maximum: StickerPreferences.maximumStickerEmojiCount
        ).joined()
        guard !id.isEmpty, !emoji.isEmpty, !pendingMutationIDs.contains(id), !Task.isCancelled
        else { return nil }
        let requestGeneration = generation
        pendingMutationIDs.insert(id)
        error = nil
        defer {
            if generation == requestGeneration { pendingMutationIDs.remove(id) }
        }
        do {
            let sticker = try await apiClient.uploadStickerToPack(
                id: id, upload: upload, emoji: emoji,
                name: trimmedOptional(name), description: trimmedOptional(description))
            try checkSession(requestGeneration)
            addSticker(sticker, toCachedPack: id)
            if isLoading { refreshChanges.append(.stickerAdded(packID: id, sticker: sticker)) }
            return withFavorite(sticker, isFavorite(sticker))
        } catch {
            await report(
                error, generation: requestGeneration,
                message: AppLanguage.localized("Couldn’t add sticker. Please try again."))
            return nil
        }
    }

    func removeSticker(fromPack id: String, stickerID: String) async -> Bool {
        guard
            !id.isEmpty,
            !stickerID.isEmpty,
            !pendingMutationIDs.contains(id),
            !Task.isCancelled
        else { return false }
        let requestGeneration = generation
        pendingMutationIDs.insert(id)
        error = nil
        defer {
            if generation == requestGeneration { pendingMutationIDs.remove(id) }
        }
        do {
            try await apiClient.removeStickerFromPack(id: id, stickerID: stickerID)
            try checkSession(requestGeneration)
            removeSticker(stickerID, fromCachedPack: id)
            if isLoading {
                refreshChanges.append(.stickerRemoved(packID: id, stickerID: stickerID))
            }
            return true
        } catch {
            await report(
                error, generation: requestGeneration,
                message: AppLanguage.localized("Couldn’t remove sticker. Please try again."))
            return false
        }
    }

    func updatePackOrder(_ order: [StickerPackOrderUpdate]) async -> Bool {
        let updates = order.filter { !$0.stickerPackId.isEmpty }
        let ids = Set(updates.map(\.stickerPackId))
        guard !updates.isEmpty, ids.isDisjoint(with: pendingMutationIDs), !Task.isCancelled else {
            return false
        }
        let requestGeneration = generation
        pendingMutationIDs.formUnion(ids)
        error = nil
        defer {
            if generation == requestGeneration { pendingMutationIDs.subtract(ids) }
        }
        do {
            try await apiClient.updateStickerPackOrder(updates)
            try checkSession(requestGeneration)
            for update in updates { packOrder[update.stickerPackId] = update.lastUsedOn }
            sortPacks()
            return true
        } catch {
            await report(
                error, generation: requestGeneration,
                message: AppLanguage.localized(
                    "Couldn’t update sticker pack order. Please try again."))
            return false
        }
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
        serverFavoriteIDs.removeAll()
        subscriptionOverrides.removeAll()
        stickerDetails.removeAll()
        refreshChanges.removeAll()
        packs.removeAll()
        favorites.removeAll()
        packDetails.removeAll()
        loadingPackIDs.removeAll()
        pendingMutationIDs.removeAll()
        accountID = nil
        MessageReactionPreferences.setActiveAccount(nil)
        preferences = StickerPreferences()
        pinnedReactions = StickerPreferences.defaultPinnedReactions
        autoSortPacks = false
        autoSortFavorites = false
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
            let (owned, subscribed, favoriteStickers) = try await (
                ownedRequest, subscribedRequest, favoritesRequest
            )
            try checkSession(requestGeneration)
            ownedPackIDs = Set(owned.map(\.id))
            var seen = Set<String>()
            let freshPacks = (owned + subscribed).filter { seen.insert($0.id).inserted }
            seen.removeAll(keepingCapacity: true)
            let freshFavorites = favoriteStickers.filter { seen.insert($0.id).inserted }.map {
                withFavorite($0, true)
            }
            serverPacks = freshPacks
            favorites = freshFavorites
            serverFavoriteIDs = freshFavorites.map(\.id)
            favoriteOverrides = Dictionary(
                uniqueKeysWithValues: freshFavorites.map { ($0.id, true) })
            subscriptionOverrides.removeAll()
            hasLoadedLibrary = true
            for change in refreshChanges { apply(change) }
            sortPacks()
            sortFavorites()
            normalizeCaches()
        } catch {
            await report(
                error, generation: requestGeneration,
                message: AppLanguage.localized("Couldn’t load stickers. Please try again."))
        }
    }

    private func updateFavorite(
        _ sticker: MessageStickerResponse, favorite: Bool, in values: inout [MessageStickerResponse]
    ) {
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

    private func updateSubscription(
        _ pack: StickerPackSummary, subscribed: Bool, in values: inout [StickerPackSummary]
    ) {
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

    private func apply(_ change: Change) {
        switch change {
        case .favorite(let sticker, let favorite):
            favoriteOverrides[sticker.id] = favorite
            updateFavorite(sticker, favorite: favorite, in: &favorites)
            updateFavoriteServerOrder(sticker.id, favorite: favorite)
        case .subscription(let pack, let subscribed):
            guard !ownedPackIDs.contains(pack.id) else { return }
            subscriptionOverrides[pack.id] = subscribed
            updateSubscription(pack, subscribed: subscribed, in: &serverPacks)
        case .packCreated(let pack):
            ownedPackIDs.insert(pack.id)
            subscriptionOverrides.removeValue(forKey: pack.id)
            replacePack(pack)
        case .packUpdated(let pack):
            replacePack(pack)
        case .packDeleted(let id):
            removePack(id)
        case .stickerAdded(let packID, let sticker):
            addSticker(sticker, toCachedPack: packID)
        case .stickerRemoved(let packID, let stickerID):
            removeSticker(stickerID, fromCachedPack: packID)
        }
    }

    private func replacePack(_ pack: StickerPackSummary) {
        var replacement = pack
        if ownedPackIDs.contains(replacement.id) { replacement.isSubscribed = true }
        if let index = serverPacks.firstIndex(where: { $0.id == replacement.id }) {
            serverPacks[index] = replacement
        } else {
            serverPacks.append(replacement)
        }
        if let detail = packDetails[replacement.id] {
            packDetails[replacement.id] = StickerPackDetailResponse(
                pack: normalized(replacement), stickers: detail.stickers)
        }
        sortPacks()
    }

    private func removePack(_ id: String) {
        serverPacks.removeAll { $0.id == id }
        ownedPackIDs.remove(id)
        subscriptionOverrides.removeValue(forKey: id)
        packOrder.removeValue(forKey: id)
        packTasks[id]?.cancel()
        packTasks.removeValue(forKey: id)
        packLoadIDs.removeValue(forKey: id)
        loadingPackIDs.remove(id)
        packDetails.removeValue(forKey: id)
        sortPacks()
    }

    private func addSticker(_ sticker: MessageStickerResponse, toCachedPack id: String) {
        let sticker = withFavorite(sticker, isFavorite(sticker))
        if let detail = packDetails[id] {
            var stickers = detail.stickers
            if let index = stickers.firstIndex(where: { $0.id == sticker.id }) {
                stickers[index] = sticker
            } else {
                stickers.append(sticker)
            }
            packDetails[id] = StickerPackDetailResponse(pack: detail.pack, stickers: stickers)
        }
        updateStickerCount(forPack: id, by: 1)
    }

    private func removeSticker(_ stickerID: String, fromCachedPack id: String) {
        guard let detail = packDetails[id] else {
            updateStickerCount(forPack: id, by: -1)
            return
        }
        let stickers = detail.stickers.filter { $0.id != stickerID }
        guard stickers.count != detail.stickers.count else { return }
        packDetails[id] = StickerPackDetailResponse(pack: detail.pack, stickers: stickers)
        updateStickerCount(forPack: id, by: -1)
    }

    private func updateStickerCount(forPack id: String, by difference: Int) {
        guard let index = serverPacks.firstIndex(where: { $0.id == id }) else { return }
        let current = serverPacks[index]
        let updated = StickerPackSummary(
            id: current.id, ownerUid: current.ownerUid, ownerName: current.ownerName,
            name: current.name, description: current.description, createdAt: current.createdAt,
            updatedAt: current.updatedAt, stickerCount: max(0, current.stickerCount + difference),
            isSubscribed: current.isSubscribed, previewSticker: current.previewSticker)
        serverPacks[index] = updated
        if let detail = packDetails[id] {
            packDetails[id] = StickerPackDetailResponse(
                pack: normalized(updated), stickers: detail.stickers)
        }
        sortPacks()
    }

    private func updateFavoriteServerOrder(_ id: String, favorite: Bool) {
        serverFavoriteIDs.removeAll { $0 == id }
        if favorite { serverFavoriteIDs.insert(id, at: 0) }
    }

    private func sortFavorites() {
        if !autoSortFavorites {
            let positions = Dictionary(
                uniqueKeysWithValues: serverFavoriteIDs.enumerated().map {
                    ($0.element, $0.offset)
                })
            favorites.sort {
                (positions[$0.id] ?? Int.max) < (positions[$1.id] ?? Int.max)
            }
            return
        }
        favorites = favorites.enumerated().sorted { lhs, rhs in
            let left = preferences.favoriteOrder[lhs.element.id]
            let right = preferences.favoriteOrder[rhs.element.id]
            if let left, let right, left != right { return left > right }
            if left != nil { return right == nil }
            if right != nil { return false }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private func savePreferences() {
        guard let accountID else { return }
        preferences.save(for: accountID)
    }

    private func trimmedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func currentTimestamp() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    private func sortPacks() {
        packs = serverPacks.enumerated().sorted { lhs, rhs in
            switch (packOrder[lhs.element.id], packOrder[rhs.element.id]) {
            case (let left?, let right?) where left != right: left > right
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
        StickerPackDetailResponse(
            pack: normalized(detail.pack),
            stickers: detail.stickers.map { withFavorite($0, isFavorite($0)) })
    }

    private func normalized(_ detail: StickerDetailResponse) -> StickerDetailResponse {
        StickerDetailResponse(
            sticker: withFavorite(detail.sticker, isFavorite(detail.sticker)),
            packs: detail.packs.map(normalized))
    }

    private func withFavorite(_ sticker: MessageStickerResponse, _ favorite: Bool)
        -> MessageStickerResponse
    {
        guard sticker.isFavorited != favorite else { return sticker }
        return MessageStickerResponse(
            id: sticker.id, emoji: sticker.emoji, createdAt: sticker.createdAt,
            isFavorited: favorite,
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

    private func report(_ failure: Error, generation requestGeneration: Int, message: String) async
    {
        guard generation == requestGeneration, !(failure is CancellationError), !Task.isCancelled
        else { return }
        error = message
        if case APIError.invalidToken = failure { await onInvalidToken() }
    }
}
