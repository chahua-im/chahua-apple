import ChahuaAPI
import Combine
import Foundation

@MainActor
final class ChatDraftStore: ObservableObject {
    @Published private(set) var drafts: [ConversationKey: String] = [:]
    @Published private var draftReplies: [ConversationKey: MessagePreview] = [:]
    @Published private var storedDraftLinkPreviews: [ConversationKey: [LinkPreviewInput]] = [:]
    @Published private(set) var draftUpdatedAt: [ConversationKey: Date] = [:]
    @Published private(set) var committingDrafts = Set<ConversationKey>()
    @Published private(set) var draftSaveFailed = false
    @Published private(set) var submissionError: String?
    private var draftRevisions: [ConversationKey: Int64] = [:]
    private var unsavedDrafts = Set<ConversationKey>()
    private var composingDrafts = Set<ConversationKey>()
    private var deferredDraftFlushes = Set<ConversationKey>()
    private var pendingDraftSaves: [ConversationKey: Task<Void, Never>] = [:]
    private var deletedReplyIDs: [String: Set<MessageID>] = [:]

    private let outgoingQueue: OutgoingMessageQueue
    private var generation = 0
    private var signOutFenced = false

    init(outgoingQueue: OutgoingMessageQueue) {
        self.outgoingQueue = outgoingQueue
    }

    var hasUnsavedWork: Bool {
        !composingDrafts.isEmpty || drafts.values.contains { !$0.isEmpty } || !draftReplies.isEmpty
            || storedDraftLinkPreviews.values.contains { !$0.isEmpty }
            || outgoingQueue.snapshots.values.contains { !$0.draft.attachments.isEmpty }
    }

    /// Receives snapshots after ChatStore rejects stale outgoing revisions.
    func install(_ snapshot: LocalConversationSnapshot) {
        let key = snapshot.conversationKey
        let reply = normalizedReply(snapshot.draft.replyToMessage, chatID: snapshot.chatID)
        if unsavedDrafts.contains(key),
            drafts[key] != snapshot.draft.text || draftReplies[key] != reply
                || storedDraftLinkPreviews[key, default: []] != snapshot.draft.linkPreviews
        {
            draftRevisions[key] = max(
                draftRevisions[key, default: 0], snapshot.draft.editRevision + 1)
        } else if snapshot.draft.editRevision >= draftRevisions[key, default: 0] {
            if drafts[key] != snapshot.draft.text { drafts[key] = snapshot.draft.text }
            if draftReplies[key] != reply { draftReplies[key] = reply }
            if storedDraftLinkPreviews[key, default: []] != snapshot.draft.linkPreviews {
                storedDraftLinkPreviews[key] = snapshot.draft.linkPreviews
            }
            draftRevisions[key] = snapshot.draft.editRevision
            let updatedAt =
                snapshot.draft.text.isEmpty && snapshot.draft.attachments.isEmpty
                ? nil : snapshot.draft.updatedAt
            if draftUpdatedAt[key] != updatedAt { draftUpdatedAt[key] = updatedAt }
            unsavedDrafts.remove(key)
        }
    }

    func draftText(chatID: String, threadID: String? = nil) -> String {
        drafts[ConversationKey(chatID: chatID, threadID: threadID), default: ""]
    }

    func draftReply(chatID: String, threadID: String? = nil) -> MessagePreview? {
        draftReplies[ConversationKey(chatID: chatID, threadID: threadID)]
    }

    func draftLinkPreviews(chatID: String, threadID: String? = nil) -> [LinkPreviewInput] {
        storedDraftLinkPreviews[ConversationKey(chatID: chatID, threadID: threadID), default: []]
    }

    func setDraftLinkPreviews(
        _ previews: [LinkPreviewInput], chatID: String, threadID: String? = nil
    ) {
        guard !signOutFenced else { return }
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        guard storedDraftLinkPreviews[key, default: []] != previews else { return }
        storedDraftLinkPreviews[key] = previews
        if drafts[key] == nil { drafts[key] = "" }
        unsavedDrafts.insert(key)
        draftRevisions[key, default: 0] += 1
        scheduleDraftSave(key: key)
    }

    func setDraftReply(_ reply: MessagePreview?, chatID: String, threadID: String? = nil) {
        guard !signOutFenced else { return }
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        let reply = normalizedReply(reply, chatID: chatID)
        guard draftReplies[key] != reply else { return }
        draftReplies[key] = reply
        if drafts[key] == nil { drafts[key] = "" }
        unsavedDrafts.insert(key)
        draftRevisions[key, default: 0] += 1
        scheduleDraftSave(key: key)
    }

    func redactReplyTargets(_ messageIDs: Set<MessageID>, chatID: String) {
        deletedReplyIDs[chatID, default: []].formUnion(messageIDs)
        for key in draftReplies.keys where key.chatID == chatID {
            guard let reply = draftReplies[key], !reply.isDeleted, messageIDs.contains(reply.id)
            else { continue }
            draftReplies[key] = reply.redactedForDeletion()
            unsavedDrafts.insert(key)
            draftRevisions[key, default: 0] += 1
            scheduleDraftSave(key: key)
        }
    }

    private func normalizedReply(_ reply: MessagePreview?, chatID: String) -> MessagePreview? {
        guard let reply, reply.isDeleted || deletedReplyIDs[chatID]?.contains(reply.id) == true
        else { return reply }
        return reply.redactedForDeletion()
    }

    func setDraftText(_ text: String, chatID: String, threadID: String? = nil) {
        guard !signOutFenced else { return }
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        guard drafts[key] != text else { return }
        drafts[key] = text
        draftUpdatedAt[key] =
            text.isEmpty
                && outgoingQueue.draftAttachments(chatID: chatID, threadID: threadID).isEmpty
            ? nil : Date()
        unsavedDrafts.insert(key)
        draftRevisions[key, default: 0] += 1
        scheduleDraftSave(key: key)
    }

    func setDraftComposing(_ isComposing: Bool, chatID: String, threadID: String? = nil) {
        guard !signOutFenced else { return }
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        if isComposing {
            composingDrafts.insert(key)
            pendingDraftSaves.removeValue(forKey: key)?.cancel()
        } else if composingDrafts.remove(key) != nil {
            scheduleDraftSave(key: key)
        }
    }

    private func scheduleDraftSave(key: ConversationKey, immediately: Bool = false) {
        guard !signOutFenced else { return }
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
        guard !signOutFenced, !Task.isCancelled else { return }
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        pendingDraftSaves.removeValue(forKey: key)?.cancel()
        guard !composingDrafts.contains(key) else {
            deferredDraftFlushes.insert(key)
            return
        }
        deferredDraftFlushes.remove(key)
        guard let text = drafts[key], unsavedDrafts.contains(key), !committingDrafts.contains(key)
        else { return }
        let revision = draftRevisions[key, default: 0]
        let requestGeneration = generation
        do {
            try await outgoingQueue.saveDraft(
                chatID: chatID, threadID: threadID, text: text, editRevision: revision,
                updatedAt: Date(), replyToMessage: draftReplies[key],
                linkPreviews: storedDraftLinkPreviews[key, default: []])
            guard generation == requestGeneration else { return }
            draftSaveFailed = false
        } catch {
            guard generation == requestGeneration, !(error is CancellationError) else { return }
            draftSaveFailed = true
        }
    }

    /// Keep attachment changes from running ahead of committed text or across account switches.
    func flushForAttachmentChange(chatID: String, threadID: String? = nil) async throws {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        let requestGeneration = generation
        guard !composingDrafts.contains(key), !committingDrafts.contains(key) else {
            throw AttachmentDraftError.busy
        }
        await flushDraft(chatID: chatID, threadID: threadID)
        guard generation == requestGeneration else { throw CancellationError() }
        try Task.checkCancellation()
        guard !draftSaveFailed, !unsavedDrafts.contains(key) else {
            throw AttachmentDraftError.notSaved
        }
    }

    private enum AttachmentDraftError: LocalizedError {
        case busy, notSaved
        var errorDescription: String? {
            switch self {
            case .busy: "Finish editing this message before changing its attachments."
            case .notSaved:
                "Your draft couldn’t be saved. Retry local storage before changing its attachments."
            }
        }
    }

    func submitDraft(
        chatID: String, threadID: String? = nil, text submittedText: String? = nil,
        metadata: MessageMetadataInput? = nil
    )
        async -> Bool
    {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        // A media caption stays modal-local until this atomic enqueue.
        let text = (submittedText ?? draftText(chatID: chatID, threadID: threadID))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let previews = draftLinkPreviews(chatID: chatID, threadID: threadID)
        let metadata =
            metadata ?? (previews.isEmpty ? nil : MessageMetadataInput(linkPreviews: previews))
        guard
            !text.isEmpty
                || !outgoingQueue.draftAttachments(chatID: chatID, threadID: threadID).isEmpty,
            !composingDrafts.contains(key),
            !committingDrafts.contains(key), outgoingQueue.storageState == .ready
        else { return false }
        submissionError = nil
        pendingDraftSaves.removeValue(forKey: key)?.cancel()
        committingDrafts.insert(key)
        let requestGeneration = generation
        let revision = draftRevisions[key, default: 0] + 1
        // Reserve the clear revision before suspending. Subsequent edits belong
        // to a newer draft and must survive the enqueue's cleared snapshot.
        draftRevisions[key] = revision
        unsavedDrafts.remove(key)
        defer { if generation == requestGeneration { committingDrafts.remove(key) } }
        do {
            try await outgoingQueue.enqueueText(
                chatID: chatID, threadID: threadID, text: text, clearedDraftRevision: revision,
                replyToMessage: draftReplies[key], metadata: metadata)
            guard generation == requestGeneration else { return false }
            if draftRevisions[key] == revision {
                drafts[key] = ""
                draftReplies[key] = nil
                storedDraftLinkPreviews[key] = nil
                unsavedDrafts.remove(key)
                draftUpdatedAt[key] = nil
                deferredDraftFlushes.remove(key)
            } else {
                scheduleDraftSave(key: key)
            }
            draftSaveFailed = false
            return true
        } catch {
            guard generation == requestGeneration else { return false }
            unsavedDrafts.insert(key)
            draftSaveFailed = true
            submissionError =
                (error as? APIError)?.speakingRestriction?.restrictionExplanation
                ?? error.localizedDescription
            return false
        }
    }

    func discardAttachments(chatID: String, threadID: String? = nil) async throws {
        let requestGeneration = generation
        try await flushForAttachmentChange(chatID: chatID, threadID: threadID)
        guard generation == requestGeneration else { throw CancellationError() }
        try await outgoingQueue.discardDraftAttachments(chatID: chatID, threadID: threadID)
    }

    func submitSticker(_ sticker: MessageStickerResponse, chatID: String, threadID: String? = nil)
        async throws -> Bool
    {
        try await submitIndependent(chatID: chatID, threadID: threadID) { reply in
            try await outgoingQueue.enqueueSticker(
                chatID: chatID, threadID: threadID, sticker: sticker, replyToMessage: reply)
        }
    }

    func submitVoice(fileURL: URL, chatID: String, threadID: String? = nil) async throws -> Bool {
        try await submitIndependent(chatID: chatID, threadID: threadID) { reply in
            try await outgoingQueue.enqueueVoice(
                chatID: chatID, threadID: threadID, fileURL: fileURL, replyToMessage: reply)
        }
    }

    private func submitIndependent(
        chatID: String, threadID: String?,
        enqueue: @MainActor (MessagePreview?) async throws -> Void
    ) async throws -> Bool {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        let requestGeneration = generation
        guard !committingDrafts.contains(key), !composingDrafts.contains(key),
            outgoingQueue.storageState == .ready, !Task.isCancelled
        else { return false }
        committingDrafts.insert(key)
        defer {
            if generation == requestGeneration {
                committingDrafts.remove(key)
                if unsavedDrafts.contains(key) { scheduleDraftSave(key: key) }
            }
        }
        // Use the current reply without consuming any part of the separate draft.
        try await enqueue(draftReplies[key])
        return generation == requestGeneration
    }

    func flushAll() async {
        let requestGeneration = generation
        for key in Array(unsavedDrafts) {
            guard generation == requestGeneration, !Task.isCancelled else { return }
            await flushDraft(chatID: key.chatID, threadID: key.threadID)
        }
    }

    func scheduleBackgroundFlush() {
        for key in unsavedDrafts {
            scheduleDraftSave(key: key, immediately: true)
        }
    }

    func fenceForSignOut() {
        signOutFenced = true
        for task in pendingDraftSaves.values { task.cancel() }
        pendingDraftSaves.removeAll()
    }

    func resumeAfterUnregisterFailure() {
        signOutFenced = false
        for key in unsavedDrafts { scheduleDraftSave(key: key) }
    }

    func discardAfterSignOutPurge() {
        reset()
        signOutFenced = true
    }

    func reset() {
        generation += 1
        signOutFenced = false
        for task in pendingDraftSaves.values { task.cancel() }
        pendingDraftSaves.removeAll()
        drafts.removeAll()
        submissionError = nil
        draftReplies.removeAll()
        storedDraftLinkPreviews.removeAll()
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
