import Combine
import Foundation
import ChahuaAPI

@MainActor
final class ChatDraftStore: ObservableObject {
    @Published private(set) var drafts: [ConversationKey: String] = [:]
    @Published private var draftReplies: [ConversationKey: MessagePreview] = [:]
    @Published private(set) var draftUpdatedAt: [ConversationKey: Date] = [:]
    @Published private(set) var committingDrafts = Set<ConversationKey>()
    @Published private(set) var draftSaveFailed = false
    private var draftRevisions: [ConversationKey: Int64] = [:]
    private var unsavedDrafts = Set<ConversationKey>()
    private var composingDrafts = Set<ConversationKey>()
    private var deferredDraftFlushes = Set<ConversationKey>()
    private var pendingDraftSaves: [ConversationKey: Task<Void, Never>] = [:]
    private var deletedReplyIDs: [String: Set<String>] = [:]

    private let outgoingQueue: OutgoingMessageQueue
    private var generation = 0

    init(outgoingQueue: OutgoingMessageQueue) {
        self.outgoingQueue = outgoingQueue
    }

    /// Receives snapshots after ChatStore rejects stale outgoing revisions.
    func install(_ snapshot: LocalConversationSnapshot) {
        let key = snapshot.conversationKey
        let reply = normalizedReply(snapshot.draft.replyToMessage, chatID: snapshot.chatID)
        if unsavedDrafts.contains(key), !committingDrafts.contains(key),
           (drafts[key] != snapshot.draft.text || draftReplies[key] != reply) {
            draftRevisions[key] = max(draftRevisions[key, default: 0], snapshot.draft.editRevision + 1)
        } else if snapshot.draft.editRevision >= draftRevisions[key, default: 0] {
            drafts[key] = snapshot.draft.text
            draftReplies[key] = reply
            draftRevisions[key] = snapshot.draft.editRevision
            draftUpdatedAt[key] = snapshot.draft.text.isEmpty ? nil : snapshot.draft.updatedAt
            unsavedDrafts.remove(key)
        }
    }

    func draftText(chatID: String, threadID: String? = nil) -> String {
        drafts[ConversationKey(chatID: chatID, threadID: threadID), default: ""]
    }

    func draftReply(chatID: String, threadID: String? = nil) -> MessagePreview? {
        draftReplies[ConversationKey(chatID: chatID, threadID: threadID)]
    }

    func setDraftReply(_ reply: MessagePreview?, chatID: String, threadID: String? = nil) {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        let reply = normalizedReply(reply, chatID: chatID)
        guard !committingDrafts.contains(key), draftReplies[key] != reply else { return }
        draftReplies[key] = reply
        if drafts[key] == nil { drafts[key] = "" }
        unsavedDrafts.insert(key)
        draftRevisions[key, default: 0] += 1
        scheduleDraftSave(key: key)
    }

    func redactReplyTargets(_ messageIDs: Set<String>, chatID: String) {
        deletedReplyIDs[chatID, default: []].formUnion(messageIDs)
        for key in draftReplies.keys where key.chatID == chatID {
            guard let reply = draftReplies[key], !reply.isDeleted, messageIDs.contains(reply.id) else { continue }
            draftReplies[key] = reply.redactedForDeletion()
            unsavedDrafts.insert(key)
            draftRevisions[key, default: 0] += 1
            scheduleDraftSave(key: key)
        }
    }

    private func normalizedReply(_ reply: MessagePreview?, chatID: String) -> MessagePreview? {
        guard let reply, deletedReplyIDs[chatID]?.contains(reply.id) == true else { return reply }
        return reply.redactedForDeletion()
    }

    func setDraftText(_ text: String, chatID: String, threadID: String? = nil) {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        guard !committingDrafts.contains(key), drafts[key] != text else { return }
        drafts[key] = text
        draftUpdatedAt[key] = text.isEmpty ? nil : Date()
        unsavedDrafts.insert(key)
        draftRevisions[key, default: 0] += 1
        scheduleDraftSave(key: key)
    }

    func setDraftComposing(_ isComposing: Bool, chatID: String, threadID: String? = nil) {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        if isComposing {
            composingDrafts.insert(key)
            pendingDraftSaves.removeValue(forKey: key)?.cancel()
        } else if composingDrafts.remove(key) != nil {
            scheduleDraftSave(key: key)
        }
    }

    private func scheduleDraftSave(key: ConversationKey, immediately: Bool = false) {
        pendingDraftSaves.removeValue(forKey: key)?.cancel()
        if immediately { deferredDraftFlushes.insert(key) }
        guard !composingDrafts.contains(key) else { return }
        guard unsavedDrafts.contains(key) else {
            deferredDraftFlushes.remove(key)
            return
        }
        let shouldFlushImmediately = deferredDraftFlushes.contains(key)
        let requestGeneration = generation
        pendingDraftSaves[key] = Task { [weak self] in
            if !shouldFlushImmediately {
                do { try await Task.sleep(for: .seconds(0.5)) } catch { return }
            }
            guard let self, self.generation == requestGeneration, !Task.isCancelled else { return }
            self.pendingDraftSaves[key] = nil
            await self.flushDraft(chatID: key.chatID, threadID: key.threadID)
        }
    }

    func flushDraft(chatID: String, threadID: String? = nil) async {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        pendingDraftSaves.removeValue(forKey: key)?.cancel()
        guard !composingDrafts.contains(key) else {
            deferredDraftFlushes.insert(key)
            return
        }
        deferredDraftFlushes.remove(key)
        guard let text = drafts[key], unsavedDrafts.contains(key), !committingDrafts.contains(key) else { return }
        let revision = draftRevisions[key, default: 0]
        let requestGeneration = generation
        do {
            try await outgoingQueue.saveDraft(chatID: chatID, threadID: threadID, text: text, editRevision: revision, updatedAt: Date(), replyToMessage: draftReplies[key])
            guard generation == requestGeneration else { return }
            draftSaveFailed = false
        } catch {
            guard generation == requestGeneration else { return }
            draftSaveFailed = true
        }
    }

    func submitDraft(chatID: String, threadID: String? = nil) async -> Bool {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        let text = draftText(chatID: chatID, threadID: threadID).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !composingDrafts.contains(key),
              !committingDrafts.contains(key), outgoingQueue.storageState == .ready else { return false }
        pendingDraftSaves.removeValue(forKey: key)?.cancel()
        committingDrafts.insert(key)
        let requestGeneration = generation
        let revision = draftRevisions[key, default: 0] + 1
        defer { if generation == requestGeneration { committingDrafts.remove(key) } }
        do {
            try await outgoingQueue.enqueueText(chatID: chatID, threadID: threadID, text: text, clearedDraftRevision: revision, replyToMessage: draftReplies[key])
            guard generation == requestGeneration else { return false }
            draftRevisions[key] = revision
            drafts[key] = ""
            draftReplies[key] = nil
            unsavedDrafts.remove(key)
            draftUpdatedAt[key] = nil
            deferredDraftFlushes.remove(key)
            draftSaveFailed = false
            return true
        } catch {
            guard generation == requestGeneration else { return false }
            draftSaveFailed = true
            return false
        }
    }

    func flushAll() async {
        let requestGeneration = generation
        for key in Array(drafts.keys) {
            await flushDraft(chatID: key.chatID, threadID: key.threadID)
            guard generation == requestGeneration else { return }
        }
    }

    func scheduleBackgroundFlush() {
        for key in drafts.keys {
            scheduleDraftSave(key: key, immediately: true)
        }
    }

    func reset() {
        generation += 1
        for task in pendingDraftSaves.values { task.cancel() }
        pendingDraftSaves.removeAll()
        drafts.removeAll()
        draftReplies.removeAll()
        deletedReplyIDs.removeAll()
        draftRevisions.removeAll()
        unsavedDrafts.removeAll()
        composingDrafts.removeAll()
        draftUpdatedAt.removeAll()
        deferredDraftFlushes.removeAll()
        committingDrafts.removeAll()
        draftSaveFailed = false
    }
}
