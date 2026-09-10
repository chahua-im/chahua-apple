import ChahuaAPI
import Combine
import Foundation

/// Serializes each message's reaction intent without speculative message snapshots.
@MainActor
final class MessageReactionController: ObservableObject {
    @Published private(set) var pendingMessageIDs = Set<String>()
    @Published var error: String?

    private let apiClient: any ChahuaAPIClient
    private let messageStore: ConversationMessageStore
    private let onInvalidToken: @MainActor @Sendable () async -> Void
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generation = 0

    init(
        apiClient: any ChahuaAPIClient,
        messageStore: ConversationMessageStore,
        onInvalidToken: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.apiClient = apiClient
        self.messageStore = messageStore
        self.onInvalidToken = onInvalidToken
    }

    func toggle(message: MessageResponse, emoji: String, currentUserID: Int32) async {
        guard !message.isDeleted, !emoji.isEmpty, !pendingMessageIDs.contains(message.id) else { return }
        let requestGeneration = generation
        pendingMessageIDs.insert(message.id)
        error = nil
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performToggle(
                message: message, emoji: emoji, currentUserID: currentUserID, generation: requestGeneration)
        }
        tasks[message.id] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if generation == requestGeneration {
            pendingMessageIDs.remove(message.id)
            tasks.removeValue(forKey: message.id)
        }
    }

    func loadPermissions(chatID: String) async -> MessageInteractionContext? {
        let requestGeneration = generation
        do {
            let group = try await apiClient.groupInfo(chatID: chatID)
            try checkSession(requestGeneration)
            guard group.id == chatID else { throw APIError.unexpectedResponse }
            var context = MessageInteractionContext(
                isDM: group.kind == .dm,
                canWrite: group.myRole != nil,
                isAdmin: group.myRole == .admin
            )
            if context.isDM {
                context.canWrite = false
                if let peer = group.peer {
                    let relationship = try await apiClient.friendRelationship(peerUID: peer.uid)
                    try checkSession(requestGeneration)
                    guard relationship.peerUid == peer.uid else { throw APIError.unexpectedResponse }
                    context.canWrite = group.myRole != nil && relationship.canDm
                }
            }
            return context
        } catch {
            guard generation == requestGeneration, !(error is CancellationError), !Task.isCancelled else { return nil }
            self.error = String(localized: "Couldn’t load message permissions. Please try again.")
            if case APIError.invalidToken = error { await onInvalidToken() }
            return nil
        }
    }

    func reset() {
        generation += 1
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        pendingMessageIDs.removeAll()
        error = nil
    }

    private func performToggle(
        message: MessageResponse, emoji: String, currentUserID: Int32, generation requestGeneration: Int
    ) async {
        do {
            try checkSession(requestGeneration)
            // Even an open menu can hold stale personalized state. Read before choosing
            // PUT versus DELETE; a truncated broadcast reactor list cannot prove false.
            let authoritative = try await readBeforeMutation(message, generation: requestGeneration)
            let target = authoritative.reactions.first { $0.emoji == emoji }
            let removing = target.flatMap { ownership($0, currentUserID: currentUserID) }
            if target != nil, removing == nil { throw Failure.unknownOwnership }
            if removing != true {
                var ownCount = 0
                for reaction in authoritative.reactions {
                    guard let isMine = ownership(reaction, currentUserID: currentUserID) else {
                        throw Failure.unknownOwnership
                    }
                    if isMine { ownCount += 1 }
                }
                guard ownCount < 5 else { throw Failure.userLimit }
                guard target != nil || authoritative.reactions.count < 50 else { throw Failure.distinctLimit }
            }

            if removing == true {
                try await apiClient.deleteReaction(chatID: message.chatId, messageID: message.id, emoji: emoji)
            } else {
                try await apiClient.putReaction(chatID: message.chatId, messageID: message.id, emoji: emoji)
            }
            try checkSession(requestGeneration)
            // Broadcasts received before this GET are older than its authoritative
            // personalized snapshot. Only ingress during the read wins over HTTP.
            let token = messageStore.beginSnapshot(chatID: message.chatId)
            defer { messageStore.endSnapshot(token) }
            let updated = try await apiClient.getMessage(chatID: message.chatId, messageID: message.id)
            try checkSession(requestGeneration)
            guard updated.id == message.id, updated.chatId == message.chatId else { throw APIError.unexpectedResponse }
            if !hasNewerState(for: message, token: token) {
                publishReactions(updated)
            }
        } catch {
            guard generation == requestGeneration, !(error is CancellationError), !Task.isCancelled else { return }
            self.error =
                (error as? Failure)?.message ?? String(localized: "Couldn’t update reaction. Please try again.")
            if case APIError.invalidToken = error { await onInvalidToken() }
        }
    }

    private func readBeforeMutation(_ message: MessageResponse, generation requestGeneration: Int) async throws
        -> MessageResponse
    {
        let token = messageStore.beginSnapshot(chatID: message.chatId)
        defer { messageStore.endSnapshot(token) }
        let authoritative = try await apiClient.getMessage(chatID: message.chatId, messageID: message.id)
        try checkSession(requestGeneration)
        guard authoritative.id == message.id, authoritative.chatId == message.chatId else {
            throw APIError.unexpectedResponse
        }
        guard !authoritative.isDeleted else { throw Failure.deleted }
        // With no server revision, concurrent broadcast state cannot safely be
        // personalized using an older HTTP response. Leave it intact and ask again.
        guard !hasNewerState(for: message, token: token) else { throw Failure.changed }
        publishReactions(authoritative)
        return authoritative
    }

    private func ownership(_ reaction: ReactionSummary, currentUserID: Int32) -> Bool? {
        if let personalized = reaction.reactedByMe { return personalized }
        return reaction.reactors?.contains { $0.uid == currentUserID } == true ? true : nil
    }

    private func hasNewerState(for message: MessageResponse, token: UUID) -> Bool {
        messageStore.eventsDuringSnapshot(token).contains { event in
            switch event {
            case .message(let updated), .messageUpdated(let updated), .messageDeleted(let updated):
                return updated.id == message.id
            case .reactionUpdated(let payload):
                return payload.messageId == message.id
            case .messagesBulkDeleted(let payload):
                return payload.messageIds.contains(message.id)
            default:
                return false
            }
        }
    }

    private func publishReactions(_ message: MessageResponse) {
        if message.isDeleted {
            messageStore.apply(.messageDeleted(message.redactedForDeletion()))
        } else {
            messageStore.apply(
                .reactionUpdated(.init(messageId: message.id, chatId: message.chatId, reactions: message.reactions)))
        }
    }

    private func checkSession(_ requestGeneration: Int) throws {
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
    }

    private enum Failure: Error {
        case unknownOwnership, changed, deleted, userLimit, distinctLimit

        var message: String {
            switch self {
            case .unknownOwnership: String(localized: "Couldn’t determine your reactions. Please try again.")
            case .changed: String(localized: "This message’s reactions changed. Please try again.")
            case .deleted: String(localized: "This message has been deleted.")
            case .userLimit: String(localized: "You can add up to 5 reactions to a message.")
            case .distinctLimit: String(localized: "A message can have up to 50 different reactions.")
            }
        }
    }
}
