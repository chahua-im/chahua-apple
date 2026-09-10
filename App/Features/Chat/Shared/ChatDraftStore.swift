import Combine
import Foundation
import ChahuaAPI

@MainActor
final class ChatDraftStore: ObservableObject {
    @Published private(set) var drafts: [String: String] = [:]
    @Published private(set) var committingDrafts = Set<String>()
    @Published private(set) var draftSaveFailed = false
    private var draftRevisions: [String: Int64] = [:]
    private var unsavedDrafts = Set<String>()
    private var composingDrafts = Set<String>()
    private var deferredDraftFlushes = Set<String>()
    private var pendingDraftSaves: [String: Task<Void, Never>] = [:]

    private let outgoingQueue: OutgoingMessageQueue
    private var generation = 0

    init(outgoingQueue: OutgoingMessageQueue) {
        self.outgoingQueue = outgoingQueue
    }

    /// Receives snapshots after ChatStore rejects stale outgoing revisions.
    func install(_ snapshot: LocalConversationSnapshot) {
        if unsavedDrafts.contains(snapshot.chatID), !committingDrafts.contains(snapshot.chatID),
           drafts[snapshot.chatID] != snapshot.draft.text {
            draftRevisions[snapshot.chatID] = max(draftRevisions[snapshot.chatID, default: 0], snapshot.draft.editRevision + 1)
        } else if snapshot.draft.editRevision >= draftRevisions[snapshot.chatID, default: 0] {
            drafts[snapshot.chatID] = snapshot.draft.text
            draftRevisions[snapshot.chatID] = snapshot.draft.editRevision
            unsavedDrafts.remove(snapshot.chatID)
        }
    }

    func draftText(chatID: String) -> String { drafts[chatID, default: ""] }

    func setDraftText(_ text: String, chatID: String) {
        guard !committingDrafts.contains(chatID), drafts[chatID] != text else { return }
        drafts[chatID] = text
        unsavedDrafts.insert(chatID)
        draftRevisions[chatID, default: 0] += 1
        scheduleDraftSave(chatID: chatID)
    }

    func setDraftComposing(_ isComposing: Bool, chatID: String) {
        if isComposing {
            composingDrafts.insert(chatID)
            pendingDraftSaves.removeValue(forKey: chatID)?.cancel()
        } else if composingDrafts.remove(chatID) != nil {
            scheduleDraftSave(chatID: chatID)
        }
    }

    private func scheduleDraftSave(chatID: String, immediately: Bool = false) {
        pendingDraftSaves.removeValue(forKey: chatID)?.cancel()
        if immediately { deferredDraftFlushes.insert(chatID) }
        guard !composingDrafts.contains(chatID) else { return }
        guard unsavedDrafts.contains(chatID) else {
            deferredDraftFlushes.remove(chatID)
            return
        }
        let shouldFlushImmediately = deferredDraftFlushes.contains(chatID)
        let requestGeneration = generation
        pendingDraftSaves[chatID] = Task { [weak self] in
            if !shouldFlushImmediately {
                do { try await Task.sleep(for: .seconds(0.5)) } catch { return }
            }
            guard let self, self.generation == requestGeneration, !Task.isCancelled else { return }
            self.pendingDraftSaves[chatID] = nil
            await self.flushDraft(chatID: chatID)
        }
    }

    func flushDraft(chatID: String) async {
        pendingDraftSaves.removeValue(forKey: chatID)?.cancel()
        guard !composingDrafts.contains(chatID) else {
            deferredDraftFlushes.insert(chatID)
            return
        }
        deferredDraftFlushes.remove(chatID)
        guard let text = drafts[chatID], unsavedDrafts.contains(chatID), !committingDrafts.contains(chatID) else { return }
        let revision = draftRevisions[chatID, default: 0]
        let requestGeneration = generation
        do {
            try await outgoingQueue.saveDraft(chatID: chatID, text: text, editRevision: revision, updatedAt: Date())
            guard generation == requestGeneration else { return }
            draftSaveFailed = false
        } catch {
            guard generation == requestGeneration else { return }
            draftSaveFailed = true
        }
    }

    func submitDraft(chatID: String) async -> Bool {
        let text = draftText(chatID: chatID).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !composingDrafts.contains(chatID),
              !committingDrafts.contains(chatID), outgoingQueue.storageState == .ready else { return false }
        pendingDraftSaves.removeValue(forKey: chatID)?.cancel()
        committingDrafts.insert(chatID)
        let requestGeneration = generation
        let revision = draftRevisions[chatID, default: 0] + 1
        defer { if generation == requestGeneration { committingDrafts.remove(chatID) } }
        do {
            try await outgoingQueue.enqueueText(chatID: chatID, text: text, clearedDraftRevision: revision)
            guard generation == requestGeneration else { return false }
            draftRevisions[chatID] = revision
            drafts[chatID] = ""
            unsavedDrafts.remove(chatID)
            deferredDraftFlushes.remove(chatID)
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
        for chatID in Array(drafts.keys) {
            await flushDraft(chatID: chatID)
            guard generation == requestGeneration else { return }
        }
    }

    func scheduleBackgroundFlush() {
        for chatID in drafts.keys {
            scheduleDraftSave(chatID: chatID, immediately: true)
        }
    }

    func reset() {
        generation += 1
        for task in pendingDraftSaves.values { task.cancel() }
        pendingDraftSaves.removeAll()
        drafts.removeAll()
        draftRevisions.removeAll()
        unsavedDrafts.removeAll()
        composingDrafts.removeAll()
        deferredDraftFlushes.removeAll()
        committingDrafts.removeAll()
        draftSaveFailed = false
    }
}
