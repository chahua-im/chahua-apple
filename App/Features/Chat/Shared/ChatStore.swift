import Combine
import Foundation
import ChahuaAPI

@MainActor
enum ChatListLoadPhase: Equatable {
    case idle, loading, loaded, failed
}

struct ChatState: Equatable {
    var chats: [ChatListItem] = []
    var chatListLoadPhase: ChatListLoadPhase = .idle
    var chatListRefreshFailed = false
    var isRefreshingChats = false
}

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var state = ChatState()
    let conversationMessages = ConversationMessageStore()

    private let apiClient: any ChahuaAPIClient
    private let onInvalidToken: @MainActor @Sendable () async -> Void
    private var generation = 0
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var invalidationTask: Task<Void, Never>?
    private var refreshDirty = false
    private var recoveryTasks: [String: Task<Void, Never>] = [:]
    private var recoveryDirty = Set<String>()
    private var recoveryGeneration = 0
    private var timelines: [ObjectIdentifier: WeakTimeline] = [:]

    private struct WeakTimeline {
        weak var value: ConversationTimelineModel?
    }

    init(apiClient: any ChahuaAPIClient, onInvalidToken: @escaping @MainActor @Sendable () async -> Void) {
        self.apiClient = apiClient
        self.onInvalidToken = onInvalidToken
    }

    func loadActiveChats() async {
        guard state.chatListLoadPhase == .idle || state.chatListLoadPhase == .failed else { return }
        await refreshActiveChats()
    }

    func refreshActiveChats() async {
        invalidationTask?.cancel()
        invalidationTask = nil
        if let refreshTask {
            await refreshTask.value
            return
        }
        let requestGeneration = generation
        let currentRefresh = refreshGeneration
        let task = Task { [weak self] in
            guard let self, self.refreshGeneration == currentRefresh, !Task.isCancelled else { return }
            defer {
                if self.generation == requestGeneration && self.refreshGeneration == currentRefresh {
                    self.refreshTask = nil
                    self.state.isRefreshingChats = false
                }
            }
            self.state.isRefreshingChats = true
            repeat {
                self.refreshDirty = false
                await self.refreshSnapshot(generation: requestGeneration, refreshGeneration: currentRefresh)
            } while self.generation == requestGeneration && self.refreshDirty && !Task.isCancelled
        }
        refreshTask = task
        await task.value
    }

    private func refreshSnapshot(generation requestGeneration: Int, refreshGeneration currentRefresh: Int) async {
        let initiallyLoaded = state.chatListLoadPhase == .loaded
        if !initiallyLoaded { state.chatListLoadPhase = .loading }
        do {
            var chats: [ChatListItem] = []
            var seenIDs = Set<String>()
            var cursors = Set<String>()
            var cursor: String?
            repeat {
                let response = try await apiClient.listChats(query: ListChatsQuery(after: cursor, archived: false))
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                for chat in response.chats where seenIDs.insert(chat.id).inserted { chats.append(chat) }
                cursor = response.nextCursor
                if let cursor, !cursors.insert(cursor).inserted { throw APIError.unavailable }
            } while cursor != nil
            state.chats = chats
            state.chatListLoadPhase = .loaded
            state.chatListRefreshFailed = false
        } catch {
            guard generation == requestGeneration, refreshGeneration == currentRefresh else { return }
            if error is CancellationError {
                if !initiallyLoaded { state.chatListLoadPhase = .idle }
                return
            }
            state.chatListRefreshFailed = initiallyLoaded
            if !initiallyLoaded { state.chatListLoadPhase = .failed }
            if case APIError.invalidToken = error { await onInvalidToken() }
        }
    }

    private func invalidateChatList() {
        if refreshTask != nil {
            refreshDirty = true
            return
        }
        guard invalidationTask == nil else { return }
        let requestGeneration = generation
        invalidationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, self.generation == requestGeneration else { return }
            self.invalidationTask = nil
            await self.refreshActiveChats()
        }
    }

    func applyRealtimeEvent(_ event: RealtimeServerEvent, currentUserID: Int32) {
        switch event {
        case .message(let message):
            conversationMessages.apply(.message(message.normalizedForRealtime(currentUserID: currentUserID)))
            invalidateChatList()
        case .messageUpdated(let message):
            conversationMessages.apply(.messageUpdated(message.normalizedForRealtime(currentUserID: currentUserID)))
            invalidateChatList()
        case .messageDeleted(let message):
            conversationMessages.apply(.messageDeleted(message.normalizedForRealtime(currentUserID: currentUserID).redactedForDeletion()))
            invalidateChatList()
        case .reactionUpdated(let payload):
            conversationMessages.apply(.reactionUpdated(ReactionUpdatePayload(
                messageId: payload.messageId, chatId: payload.chatId,
                reactions: payload.reactions.map { $0.normalizedForRealtime(currentUserID: currentUserID) }
            )))
        case .messagesBulkDeleted(let payload):
            conversationMessages.apply(event)
            invalidateChatList()
            scheduleRecovery(chatID: payload.chatId)
        case .threadUpdate:
            conversationMessages.apply(event)
        case .chatArchiveStateChanged:
            invalidateChatList()
        case .pong, .presenceUpdate, .threadMembershipChanged, .pinAdded, .threadPinAdded,
             .pinRemoved, .threadPinRemoved, .stickerPackOrderUpdated, .friendRequestReceived,
             .friendRequestResolved, .friendshipRemoved:
            break
        case .unknown:
            break
        }
    }

    func registerTimeline(_ model: ConversationTimelineModel) {
        timelines[ObjectIdentifier(model)] = WeakTimeline(value: model)
    }

    func unregisterTimeline(_ model: ConversationTimelineModel) {
        timelines.removeValue(forKey: ObjectIdentifier(model))
    }

    func reconcileVisibleTimelines() async {
        let models = visibleTimelines()
        await withTaskGroup(of: Void.self) { group in
            for model in models { group.addTask { await model.reconcileAfterReconnect() } }
        }
    }

    private func visibleTimelines() -> [ConversationTimelineModel] {
        timelines = timelines.filter { $0.value.value != nil }
        return timelines.values.compactMap(\.value)
    }

    private func scheduleRecovery(chatID: String) {
        recoveryDirty.insert(chatID)
        guard recoveryTasks[chatID] == nil else { return }
        let requestGeneration = generation
        let currentRecovery = recoveryGeneration
        recoveryTasks[chatID] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == requestGeneration && self.recoveryGeneration == currentRecovery {
                    self.recoveryTasks[chatID] = nil
                }
            }
            repeat {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard self.generation == requestGeneration, self.recoveryGeneration == currentRecovery else { return }
                self.recoveryDirty.remove(chatID)
                let models = self.visibleTimelines().filter { $0.chatID == chatID }
                await withTaskGroup(of: Void.self) { group in
                    for model in models { group.addTask { await model.reconcileAfterReconnect() } }
                }
            } while !Task.isCancelled && self.recoveryDirty.contains(chatID)
        }
    }

    func fetchMessages(chatID: String, query: ListMessagesQuery = .init()) async throws -> ListMessagesResponse {
        let requestGeneration = generation
        do {
            let response = try await apiClient.listMessages(chatID: chatID, query: query)
            guard generation == requestGeneration else { throw CancellationError() }
            return response
        } catch {
            guard generation == requestGeneration else { throw CancellationError() }
            if case APIError.invalidToken = error { await onInvalidToken() }
            throw error
        }
    }

    func cancelRealtimeRecovery() {
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        invalidationTask?.cancel()
        invalidationTask = nil
        refreshDirty = false
        state.isRefreshingChats = false
        if state.chatListLoadPhase == .loading { state.chatListLoadPhase = .idle }
        recoveryGeneration += 1
        recoveryDirty.removeAll()
        for task in recoveryTasks.values { task.cancel() }
        recoveryTasks.removeAll()
    }

    func reset() {
        generation += 1
        cancelRealtimeRecovery()
        conversationMessages.reset()
        state = ChatState()
    }
}
