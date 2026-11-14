import Foundation
import GRDB

public final class ChahuaLocalStore: Sendable {
    public let directory: URL
    private let database: DatabaseQueue

    public init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        #if os(iOS)
            try manager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory.path)
        #endif
        let path = directory.appendingPathComponent("chat.sqlite").path
        database = try DatabaseQueue(path: path)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try migrateLocalStorage(database)
    }

    public func restore() async throws -> [LocalConversationSnapshot] {
        try await database.write { db in
            let keys = try Row.fetchAll(
                db,
                sql: "SELECT chat_id, thread_id FROM local_conversation ORDER BY chat_id, thread_id"
            )
            .map(Self.key)
            for key in keys {
                let froze = try Self.freezeLegacyClaims(db, key, directory: self.directory)
                try db.execute(
                    sql: """
                        UPDATE outgoing_message SET state = 'queued',
                            dispatch_claimed = CASE WHEN state = 'sending' THEN 1 ELSE dispatch_claimed END
                        WHERE chat_id = ? AND thread_id = ?
                        AND (state = 'sending' OR (state = 'failed' AND mutation_retryable = 1))
                        """,
                    arguments: [key.chatID, key.threadID ?? ""])
                if db.changesCount > 0 || froze { try Self.bump(db, key) }
            }
            return try keys.map { try Self.snapshot(db, $0, directory: self.directory) }
        }
    }

    public func beginComposition(chatID: String, threadID: String? = nil, senderID: Int32)
        async throws -> LocalConversationSnapshot
    {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            if let item = before.composingItem {
                if item.senderID != senderID {
                    try db.execute(
                        sql:
                            "UPDATE outgoing_message SET sender_id = ? WHERE client_generated_id = ?",
                        arguments: [senderID, item.clientGeneratedID])
                    try Self.bump(db, key)
                }
            } else {
                try Self.insert(
                    db, key, id: UUID().uuidString, senderID: senderID, text: "", replyData: nil,
                    date: Date(), revision: before.draft.editRevision, blocked: true)
                try Self.bump(db, key)
            }
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    public func saveDraft(
        chatID: String, threadID: String? = nil, text: String, editRevision: Int64, updatedAt: Date,
        replyToMessage: MessagePreview? = nil, linkPreviews: [LinkPreviewInput] = []
    ) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        let replyData = try replyToMessage.map { try JSONEncoder().encode($0) }
        let metadataData =
            try linkPreviews.isEmpty
            ? nil
            : JSONEncoder().encode(MessageMetadataInput(linkPreviews: linkPreviews))
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            guard editRevision > before.draft.editRevision else { return before }
            if let item = before.composingItem {
                try db.execute(
                    sql:
                        "UPDATE outgoing_message SET text = ?, reply_to_message = ?, metadata = ?, edit_revision = ?, updated_at = ? WHERE client_generated_id = ?",
                    arguments: [
                        text, replyData, metadataData, editRevision,
                        updatedAt.timeIntervalSince1970,
                        item.clientGeneratedID,
                    ])
            } else if !text.isEmpty || replyData != nil || metadataData != nil {
                try Self.insert(
                    db, key, id: UUID().uuidString, senderID: 0, text: text, replyData: replyData,
                    date: updatedAt, revision: editRevision, blocked: true,
                    metadataData: metadataData)
            }
            try Self.writeRevision(db, key, editRevision, updatedAt)
            try Self.bump(db, key)
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    /// Releases the existing composition in place, or creates an already-released text item.
    /// The supplied identity is used only when there is no blocked tail.
    public func enqueueText(
        chatID: String, threadID: String? = nil, senderID: Int32, clientGeneratedID: String,
        text: String, enqueuedAt: Date, clearedDraftRevision: Int64,
        replyToMessage: MessagePreview? = nil, metadata: MessageMetadataInput? = nil
    ) async throws -> LocalConversationSnapshot {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        let replyData = try replyToMessage.map { try JSONEncoder().encode($0) }
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            let metadataData = try (metadata ?? before.composingItem?.metadata).map {
                try JSONEncoder().encode($0)
            }
            guard clearedDraftRevision > before.draft.editRevision else {
                throw LocalStorageError.staleDraft
            }
            guard !trimmed.isEmpty || before.composingItem?.attachments.isEmpty == false else {
                throw LocalStorageError.blankMessage
            }
            if let item = before.composingItem {
                try Self.validateAttachments(item.attachments, directory: self.directory)
                // Draft creation time is not send time: optimistic timeline ordering
                // and sender grouping must agree with the eventual acknowledgement.
                try db.execute(
                    sql:
                        "UPDATE outgoing_message SET sender_id = ?, text = ?, reply_to_message = ?, metadata = ?, is_blocked = 0, edit_revision = ?, enqueued_at = ?, updated_at = ? WHERE client_generated_id = ?",
                    arguments: [
                        senderID, item.attachments.contains(where: \.isFile) ? "" : trimmed,
                        replyData, item.attachments.contains(where: \.isFile) ? nil : metadataData,
                        clearedDraftRevision,
                        enqueuedAt.timeIntervalSince1970, enqueuedAt.timeIntervalSince1970,
                        item.clientGeneratedID,
                    ])
                // File messages cannot carry text on the wire. Keep the entered caption as
                // an adjacent durable text message rather than silently dropping the draft.
                if item.attachments.contains(where: \.isFile), !trimmed.isEmpty {
                    try Self.insert(
                        db, key, id: UUID().uuidString, senderID: senderID, text: trimmed,
                        replyData: nil, date: enqueuedAt, revision: clearedDraftRevision,
                        blocked: false, metadataData: metadataData)
                }
            } else {
                try Self.insert(
                    db, key, id: clientGeneratedID, senderID: senderID, text: trimmed,
                    replyData: replyData, date: enqueuedAt, revision: clearedDraftRevision,
                    blocked: false, metadataData: metadataData)
            }
            try Self.writeRevision(db, key, clearedDraftRevision, enqueuedAt)
            try Self.bump(db, key)
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    /// Queues text without consuming an in-progress composition for the conversation.
    public func enqueueIndependentText(
        chatID: String, threadID: String? = nil, senderID: Int32, clientGeneratedID: String,
        text: String, enqueuedAt: Date
    ) async throws -> LocalConversationSnapshot {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalStorageError.blankMessage }
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            try Self.insert(
                db, key, id: clientGeneratedID, senderID: senderID, text: trimmed, replyData: nil,
                date: enqueuedAt, revision: 0, blocked: false)
            if let composition = before.composingItem {
                // Keep the unsent composition last, after the independently queued item.
                // Its identity, content, upload checkpoints and draft revision stay intact.
                let sequence = try Int64.fetchOne(
                    db,
                    sql:
                        "SELECT next_enqueue_sequence FROM local_conversation WHERE chat_id = ? AND thread_id = ?",
                    arguments: [chatID, threadID ?? ""])!
                try db.execute(
                    sql:
                        "UPDATE outgoing_message SET enqueue_sequence = ?, dispatch_order = ? WHERE client_generated_id = ?",
                    arguments: [sequence, sequence, composition.clientGeneratedID])
                try db.execute(
                    sql:
                        "UPDATE local_conversation SET next_enqueue_sequence = next_enqueue_sequence + 1 WHERE chat_id = ? AND thread_id = ?",
                    arguments: [chatID, threadID ?? ""])
            }
            try Self.bump(db, key)
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    /// Captures an independent immutable forwarding request without consuming the destination draft.
    public func enqueueForward(
        chatID: String, threadID: String? = nil, senderID: Int32, request: LocalForwardRequest
    ) async throws -> LocalConversationSnapshot {
        guard !request.sources.isEmpty, request.sources.count <= 100,
            Set(request.messageIDs).count == request.sources.count,
            request.sources.allSatisfy({
                $0.chatId == request.sourceChatID && !$0.isDeleted
                    && $0.messageType != .system && $0.messageType != .invite
            })
        else { throw LocalStorageError.unsupportedMessageType }
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        let id = UUID().uuidString
        let date = Date()
        let data = try JSONEncoder().encode(request)
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            try Self.insert(
                db, key, id: id, senderID: senderID, text: "", replyData: nil,
                date: date, revision: 0, blocked: false)
            try db.execute(
                sql:
                    "UPDATE outgoing_message SET forward_request = ? WHERE client_generated_id = ?",
                arguments: [data, id])
            if let composition = before.composingItem {
                // Forwarding is independent: preserve every draft field and keep it as the tail.
                let sequence = try Int64.fetchOne(
                    db,
                    sql:
                        "SELECT next_enqueue_sequence FROM local_conversation WHERE chat_id = ? AND thread_id = ?",
                    arguments: [chatID, threadID ?? ""])!
                try db.execute(
                    sql:
                        "UPDATE outgoing_message SET enqueue_sequence = ?, dispatch_order = ? WHERE client_generated_id = ?",
                    arguments: [sequence, sequence, composition.clientGeneratedID])
                try db.execute(
                    sql:
                        "UPDATE local_conversation SET next_enqueue_sequence = next_enqueue_sequence + 1 WHERE chat_id = ? AND thread_id = ?",
                    arguments: [chatID, threadID ?? ""])
            }
            try Self.bump(db, key)
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    /// Sends independently of the blocked composition without consuming its draft.
    public func enqueueSticker(
        chatID: String, threadID: String? = nil, senderID: Int32, clientGeneratedID: String,
        sticker: MessageStickerResponse, enqueuedAt: Date, replyToMessage: MessagePreview? = nil
    ) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        let replyData = try replyToMessage.map { try JSONEncoder().encode($0) }
        let stickerData = try JSONEncoder().encode(sticker)
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            try Self.insert(
                db, key, id: clientGeneratedID, senderID: senderID, text: "", replyData: replyData,
                date: enqueuedAt, revision: 0, blocked: false)
            try db.execute(
                sql: "UPDATE outgoing_message SET sticker = ? WHERE client_generated_id = ?",
                arguments: [stickerData, clientGeneratedID])
            if let composition = before.composingItem {
                // Keep the unsent composition last, after the new released item.
                // Its identity, content, upload checkpoints and draft revision stay intact.
                let sequence = try Int64.fetchOne(
                    db,
                    sql:
                        "SELECT next_enqueue_sequence FROM local_conversation WHERE chat_id = ? AND thread_id = ?",
                    arguments: [chatID, threadID ?? ""])!
                try db.execute(
                    sql:
                        "UPDATE outgoing_message SET enqueue_sequence = ?, dispatch_order = ? WHERE client_generated_id = ?",
                    arguments: [sequence, sequence, composition.clientGeneratedID])
                try db.execute(
                    sql:
                        "UPDATE local_conversation SET next_enqueue_sequence = next_enqueue_sequence + 1 WHERE chat_id = ? AND thread_id = ?",
                    arguments: [chatID, threadID ?? ""])
            }
            try Self.bump(db, key)
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    /// Voice is a released single attachment; it never takes ownership of a text/media draft.
    public func enqueueVoice(
        chatID: String, threadID: String? = nil, senderID: Int32, clientGeneratedID: String,
        attachment: LocalOutgoingAttachment, enqueuedAt: Date, replyToMessage: MessagePreview? = nil
    ) async throws -> LocalConversationSnapshot {
        guard attachment.isAudio, attachment.attachmentID == nil, attachment.error == nil else {
            throw LocalStorageError.invalidAttachments
        }
        try Self.validateAttachments([attachment], directory: directory)
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        let replyData = try replyToMessage.map { try JSONEncoder().encode($0) }
        let attachmentData = try Self.encodeAttachments([attachment], directory: directory)
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            try Self.insert(
                db, key, id: clientGeneratedID, senderID: senderID, text: "", replyData: replyData,
                date: enqueuedAt, revision: 0, blocked: false)
            try db.execute(
                sql:
                    "UPDATE outgoing_message SET attachments = ?, compression_enabled = 0 WHERE client_generated_id = ?",
                arguments: [attachmentData, clientGeneratedID])
            if let composition = before.composingItem {
                let sequence = try Int64.fetchOne(
                    db,
                    sql:
                        "SELECT next_enqueue_sequence FROM local_conversation WHERE chat_id = ? AND thread_id = ?",
                    arguments: [chatID, threadID ?? ""])!
                try db.execute(
                    sql:
                        "UPDATE outgoing_message SET enqueue_sequence = ?, dispatch_order = ? WHERE client_generated_id = ?",
                    arguments: [sequence, sequence, composition.clientGeneratedID])
                try db.execute(
                    sql:
                        "UPDATE local_conversation SET next_enqueue_sequence = next_enqueue_sequence + 1 WHERE chat_id = ? AND thread_id = ?",
                    arguments: [chatID, threadID ?? ""])
            }
            try Self.bump(db, key)
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    public func setCompositionAttachments(
        chatID: String, threadID: String? = nil, itemID: String, expectedRevision: Int64,
        attachments: [LocalOutgoingAttachment], compressionEnabled: Bool
    ) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            let item = try Self.editableTail(
                before, itemID: itemID, expectedRevision: expectedRevision)
            guard item.isBlocked else { throw LocalStorageError.notTail }
            guard item.forwardRequest == nil,
                item.messageType == .text || item.messageType == .file,
                !attachments.contains(where: \.isAudio)
            else {
                throw LocalStorageError.unsupportedMessageType
            }
            guard attachments.count <= 20, Set(attachments.map(\.id)).count == attachments.count
            else { throw LocalStorageError.invalidAttachments }
            let existing = Dictionary(uniqueKeysWithValues: item.attachments.map { ($0.id, $0) })
            let optionsChanged = item.compressionEnabled != compressionEnabled
            let updated = try attachments.enumerated().map { position, proposed in
                var slot = proposed
                let old = existing[proposed.id]
                let sourceChanged = old.map { $0.sourcePath != proposed.sourcePath } ?? false
                if let old {
                    guard proposed.generation == old.generation else {
                        throw LocalStorageError.staleDraft
                    }
                    // A caller's snapshot can predate a completed worker checkpoint.
                    if !sourceChanged { slot = old }
                }
                // Position is composition state, not part of the uploaded content generation.
                if sourceChanged || (optionsChanged && !slot.isFile) {
                    slot.generation = UUID().uuidString
                    slot.attachmentID = nil
                    slot.error = nil
                    slot.preparedPath = slot.isFile ? slot.sourcePath : nil
                }
                slot.position = position
                return slot
            }
            try Self.validateAttachments(updated, directory: self.directory)
            guard updated != item.attachments || compressionEnabled != item.compressionEnabled
            else { return before }
            let revision = item.editRevision + 1
            let date = Date()
            try db.execute(
                sql:
                    "UPDATE outgoing_message SET attachments = ?, compression_enabled = ?, edit_revision = ?, updated_at = ? WHERE client_generated_id = ?",
                arguments: [
                    try Self.encodeAttachments(updated, directory: self.directory),
                    compressionEnabled, revision, date.timeIntervalSince1970, itemID,
                ])
            try Self.writeRevision(db, key, revision, date)
            try Self.bump(db, key)
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    public func checkpointAttachment(
        chatID: String, threadID: String? = nil, itemID: String, attachment: LocalOutgoingAttachment
    ) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            guard
                let item = (before.outgoing + [before.composingItem].compactMap { $0 })
                    .first(where: { $0.clientGeneratedID == itemID }), !item.isCancelled
            else { return before }
            var originals = item.attachments
            var intent = item.intentAttachments
            var changed = false
            // Checkpoints belong to a slot generation, never to a captured position or revision.
            // The frozen create is intentionally not touched, even when its local slot is borrowed.
            let belongsToIntent =
                intent.map { selection in
                    selection.contains {
                        if case .local(let slot) = $0 {
                            return slot.id == attachment.id
                                && slot.generation == attachment.generation
                        }
                        return false
                    }
                } ?? true
            if belongsToIntent,
                let index = originals.firstIndex(where: {
                    $0.id == attachment.id && $0.generation == attachment.generation
                }), let merged = try Self.mergeCheckpoint(attachment, into: originals[index])
            {
                originals[index] = merged
                changed = true
            }
            if var selection = intent,
                let index = selection.firstIndex(where: {
                    if case .local(let slot) = $0 {
                        return slot.id == attachment.id && slot.generation == attachment.generation
                    }
                    return false
                }), case .local(let old) = selection[index],
                let merged = try Self.mergeCheckpoint(attachment, into: old)
            {
                selection[index] = .local(merged)
                intent = selection
                changed = true
            }
            guard changed else { return before }
            try Self.validateAttachments(originals, directory: self.directory, requireSource: false)
            if let intent {
                try Self.validateEditAttachments(
                    intent, directory: self.directory, requireSource: false)
            }
            let state =
                !item.isBlocked && (item.messageType == .audio || item.messageType == .file)
                    && attachment.error != nil && item.confirmedMessage == nil
                ? LocalOutgoingMessage.State.failed : item.state
            try db.execute(
                sql:
                    "UPDATE outgoing_message SET attachments = ?, intent_attachments = ?, state = ? WHERE client_generated_id = ?",
                arguments: [
                    try Self.encodeAttachments(originals, directory: self.directory),
                    try intent.map {
                        try Self.encodeEditAttachments($0, directory: self.directory)
                    },
                    state.rawValue, itemID,
                ])
            try Self.bump(db, key)
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    public func editOutgoing(
        chatID: String, threadID: String? = nil, itemID: String, expectedRevision: Int64,
        text: String, attachments: [LocalEditAttachment], metadata: MessageMetadataInput? = nil
    ) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await database.write { db in
            try Self.ensure(db, key)
            _ = try Self.freezeLegacyClaims(db, key, directory: self.directory)
            let before = try Self.snapshot(db, key, directory: self.directory)
            let item = try Self.releasedItem(
                before, itemID: itemID, expectedRevision: expectedRevision)
            guard item.forwardRequest == nil, item.messageType == .text else {
                throw LocalStorageError.unsupportedMessageType
            }
            guard !trimmed.isEmpty || !attachments.isEmpty else {
                throw LocalStorageError.blankMessage
            }
            let existing =
                (item.intentAttachments ?? item.attachments.map(LocalEditAttachment.local))
                .compactMap { selection -> LocalOutgoingAttachment? in
                    if case .local(let slot) = selection { return slot }
                    return nil
                }
            let knownServer = Set(
                (item.confirmedMessage?.attachments ?? [])
                    + (item.intentAttachments ?? []).compactMap {
                        if case .server(let attachment) = $0 { return attachment }
                        return nil
                    })
            let selection = try attachments.enumerated().map { position, proposed in
                switch proposed {
                case .local(var slot):
                    if let old = existing.first(where: { $0.id == slot.id }) {
                        guard old.generation == slot.generation,
                            old.sourcePath == slot.sourcePath, old.previewPath == slot.previewPath
                        else { throw LocalStorageError.staleDraft }
                        slot = old
                    }
                    slot.position = position
                    return LocalEditAttachment.local(slot)
                case .server(let attachment):
                    guard knownServer.contains(attachment) else {
                        throw LocalStorageError.invalidAttachments
                    }
                    return .server(attachment)
                }
            }
            try Self.validateEditAttachments(selection, directory: self.directory)
            // A failed, already-claimed PATCH must replay before the newly submitted intent.
            let state: LocalOutgoingMessage.State =
                item.confirmedMessage == nil && item.dispatchClaimed && item.state == .sending
                ? .sending : .queued
            try db.execute(
                sql: """
                    UPDATE outgoing_message SET text = ?, intent_attachments = ?, metadata = ?, edit_revision = ?,
                        state = ?, mutation_retryable = 0, speaking_restriction = NULL, updated_at = ?
                    WHERE client_generated_id = ?
                    """,
                arguments: [
                    trimmed, try Self.encodeEditAttachments(selection, directory: self.directory),
                    try (metadata ?? item.metadata).map { try JSONEncoder().encode($0) },
                    item.editRevision + 1, state.rawValue, Date().timeIntervalSince1970, itemID,
                ])
            try Self.bump(db, key)
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    public func cancelOutgoing(
        chatID: String, threadID: String? = nil, itemID: String, expectedRevision: Int64
    ) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            _ = try Self.freezeLegacyClaims(db, key, directory: self.directory)
            let before = try Self.snapshot(db, key, directory: self.directory)
            let item = try Self.releasedItem(
                before, itemID: itemID, expectedRevision: expectedRevision)
            if item.dispatchClaimed || item.confirmedMessage != nil {
                try db.execute(
                    sql: """
                        UPDATE outgoing_message SET is_cancelled = 1, edit_revision = edit_revision + 1,
                            state = 'queued', mutation_retryable = 0, speaking_restriction = NULL
                        WHERE client_generated_id = ?
                        """, arguments: [itemID])
            } else {
                try db.execute(
                    sql: "DELETE FROM outgoing_message WHERE client_generated_id = ?",
                    arguments: [itemID])
            }
            try Self.bump(db, key)
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    public func claimNext(chatID: String, threadID: String? = nil) async throws
        -> LocalOutgoingClaim
    {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            let froze = try Self.freezeLegacyClaims(db, key, directory: self.directory)
            let before = try Self.snapshot(db, key, directory: self.directory)
            guard
                let head = before.outgoing.first(where: {
                    $0.confirmedMessage == nil && !$0.isCancelled
                }), head.state == .queued, head.isReadyForDispatch
            else {
                if froze { try Self.bump(db, key) }
                return LocalOutgoingClaim(
                    snapshot: try Self.snapshot(db, key, directory: self.directory), message: nil)
            }
            try Self.freeze(db, head)
            try db.execute(
                sql:
                    "UPDATE outgoing_message SET state = 'sending', dispatch_claimed = 1 WHERE client_generated_id = ?",
                arguments: [head.clientGeneratedID])
            try Self.bump(db, key)
            let snapshot = try Self.snapshot(db, key, directory: self.directory)
            return LocalOutgoingClaim(
                snapshot: snapshot,
                message: snapshot.outgoing.first { $0.clientGeneratedID == head.clientGeneratedID })
        }
    }

    public func fail(
        chatID: String, threadID: String? = nil, clientGeneratedID: String,
        speakingRestriction: SpeakingMode? = nil
    ) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            try db.execute(
                sql:
                    "UPDATE outgoing_message SET state = 'failed', speaking_restriction = ? WHERE chat_id = ? AND thread_id = ? AND client_generated_id = ? AND is_blocked = 0 AND confirmed_message IS NULL AND is_cancelled = 0 AND (state != 'failed' OR speaking_restriction IS NOT ?)",
                arguments: [
                    speakingRestriction?.rawValue, chatID, threadID ?? "", clientGeneratedID,
                    speakingRestriction?.rawValue,
                ])
            if db.changesCount > 0 { try Self.bump(db, key) }
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    public func retry(
        chatID: String, threadID: String? = nil, clientGeneratedID: String,
        scope: OutgoingRetryScope
    ) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            let items = before.outgoing + [before.composingItem].compactMap { $0 }
            guard let index = items.firstIndex(where: { $0.clientGeneratedID == clientGeneratedID })
            else { return before }
            let selected = scope == .message ? [items[index]] : Array(items[index...])
            var changed = false
            for item in selected where item.state != .sending {
                var slots = item.attachments
                var selection = item.intentAttachments
                if !item.dispatchClaimed {
                    for index in slots.indices { slots[index].error = nil }
                }
                if var intent = selection {
                    for index in intent.indices {
                        if case .local(var slot) = intent[index] {
                            slot.error = nil
                            intent[index] = .local(slot)
                        }
                    }
                    selection = intent
                }
                guard
                    item.state == .failed || slots != item.attachments
                        || selection != item.intentAttachments
                else { continue }
                try db.execute(
                    sql: """
                        UPDATE outgoing_message SET state = 'queued', attachments = ?,
                            intent_attachments = ?, mutation_retryable = 0, speaking_restriction = NULL
                        WHERE client_generated_id = ?
                        """,
                    arguments: [
                        try Self.encodeAttachments(slots, directory: self.directory),
                        try selection.map {
                            try Self.encodeEditAttachments($0, directory: self.directory)
                        },
                        item.clientGeneratedID,
                    ])
                changed = true
            }
            if changed { try Self.bump(db, key) }
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    public func acceptCreate(_ message: MessageResponse, published: Bool) async throws
        -> LocalOutgoingTransition
    {
        let key = ConversationKey(chatID: message.chatId, threadID: message.replyRootId)
        return try await database.write { db in
            let before = try Self.snapshot(db, key, directory: self.directory)
            guard
                let item = before.outgoing.first(where: {
                    $0.clientGeneratedID == message.clientGeneratedId
                })
            else {
                let exists =
                    try Bool.fetchOne(
                        db,
                        sql:
                            "SELECT EXISTS(SELECT 1 FROM outgoing_message WHERE client_generated_id = ?)",
                        arguments: [message.clientGeneratedId]) ?? false
                guard !exists else { throw LocalStorageError.staleDraft }
                return LocalOutgoingTransition(
                    snapshot: before, clientGeneratedID: message.clientGeneratedId,
                    disposition: .completed)
            }
            try Self.validateIdentity(message, item: item)
            if item.dispatchClaimed && item.frozenCreate == nil && item.intentAttachments != nil {
                throw LocalStorageError.corruptRecord
            }
            try Self.freeze(db, item)
            let frozenRevision = item.frozenCreate?.revision ?? item.editRevision
            // Realtime can confirm a PATCH before the held create HTTP response returns.
            // Never let that older response replace the acknowledged mutation.
            let replace =
                item.confirmedMessage == nil
                || (item.acknowledgedRevision <= frozenRevision && !item.isPublished)
            try db.execute(
                sql: """
                    UPDATE outgoing_message SET confirmed_message = ?, is_published = ?,
                        acknowledged_revision = ?, dispatch_claimed = 1,
                        state = ?, mutation_retryable = ?
                    WHERE client_generated_id = ?
                    """,
                arguments: [
                    try JSONEncoder().encode(replace ? message : item.confirmedMessage!),
                    item.isPublished || published, max(item.acknowledgedRevision, frozenRevision),
                    item.state == .failed && (item.isCancelled || item.claimedPatch != nil)
                        ? "failed" : "queued",
                    item.mutationRetryable, item.clientGeneratedID,
                ])
            try Self.bump(db, key)
            return try Self.transition(
                db, key, itemID: item.clientGeneratedID, directory: self.directory)
        }
    }

    public func claimPatch(chatID: String, threadID: String? = nil, itemID: String) async throws
        -> LocalOutgoingPatchClaim
    {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            guard let item = before.outgoing.first(where: { $0.clientGeneratedID == itemID }),
                item.confirmedMessage != nil, item.isPublished, !item.isCancelled,
                item.state != .failed, item.editRevision > item.acknowledgedRevision
            else { return LocalOutgoingPatchClaim(snapshot: before, patch: nil) }
            let patch: LocalClaimedPatch
            if let claimed = item.claimedPatch {
                patch = claimed
            } else {
                let selection =
                    item.intentAttachments ?? item.attachments.map(LocalEditAttachment.local)
                guard
                    selection.allSatisfy({
                        if case .local(let slot) = $0 {
                            return slot.attachmentID != nil && slot.error == nil
                        }
                        return true
                    })
                else { return LocalOutgoingPatchClaim(snapshot: before, patch: nil) }
                guard item.forwardRequest == nil, item.messageType == .text else {
                    throw LocalStorageError.unsupportedMessageType
                }
                patch = LocalClaimedPatch(
                    text: item.text,
                    attachmentIDs: selection.map {
                        switch $0 {
                        case .local(let slot): return slot.attachmentID!
                        case .server(let attachment): return attachment.id
                        }
                    }, revision: item.editRevision, metadata: item.metadata)
            }
            try db.execute(
                sql:
                    "UPDATE outgoing_message SET claimed_patch = ?, state = 'sending', mutation_retryable = 0 WHERE client_generated_id = ?",
                arguments: [try JSONEncoder().encode(patch), itemID])
            try Self.bump(db, key)
            return LocalOutgoingPatchClaim(
                snapshot: try Self.snapshot(db, key, directory: self.directory), patch: patch)
        }
    }

    public func acceptPatch(_ message: MessageResponse, itemID: String, revision: Int64)
        async throws
        -> LocalOutgoingTransition
    {
        let key = ConversationKey(chatID: message.chatId, threadID: message.replyRootId)
        return try await database.write { db in
            let before = try Self.snapshot(db, key, directory: self.directory)
            guard revision >= 0, message.clientGeneratedId == itemID else {
                throw LocalStorageError.staleDraft
            }
            guard let item = before.outgoing.first(where: { $0.clientGeneratedID == itemID }) else {
                let exists =
                    try Bool.fetchOne(
                        db,
                        sql:
                            "SELECT EXISTS(SELECT 1 FROM outgoing_message WHERE client_generated_id = ?)",
                        arguments: [itemID]) ?? false
                guard !exists else { throw LocalStorageError.staleDraft }
                return LocalOutgoingTransition(
                    snapshot: before, clientGeneratedID: itemID, disposition: .completed)
            }
            try Self.validateIdentity(message, item: item)
            guard let confirmed = item.confirmedMessage, confirmed.id == message.id else {
                throw LocalStorageError.staleDraft
            }
            if revision <= item.acknowledgedRevision {
                let disposition: LocalOutgoingDisposition =
                    item.isCancelled
                    ? .cancelled
                    : item.isPublished && item.acknowledgedRevision == item.editRevision
                        && item.claimedPatch == nil ? .completed : .retained
                return LocalOutgoingTransition(
                    snapshot: before, clientGeneratedID: itemID, disposition: disposition)
            }
            guard item.claimedPatch?.revision == revision else {
                throw LocalStorageError.staleDraft
            }
            try db.execute(
                sql: """
                    UPDATE outgoing_message SET confirmed_message = ?, acknowledged_revision = ?,
                        claimed_patch = NULL, state = ?, mutation_retryable = ?
                    WHERE client_generated_id = ?
                    """,
                arguments: [
                    try JSONEncoder().encode(item.isCancelled ? confirmed : message),
                    max(item.acknowledgedRevision, revision),
                    item.isCancelled ? item.state.rawValue : "queued",
                    item.isCancelled && item.mutationRetryable, itemID,
                ])
            try Self.bump(db, key)
            return try Self.transition(db, key, itemID: itemID, directory: self.directory)
        }
    }

    public func acceptDelete(chatID: String, threadID: String? = nil, itemID: String) async throws
        -> LocalOutgoingTransition
    {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            guard let item = before.outgoing.first(where: { $0.clientGeneratedID == itemID }),
                item.confirmedMessage != nil
            else { throw LocalStorageError.staleDraft }
            try db.execute(
                sql: "DELETE FROM outgoing_message WHERE client_generated_id = ?",
                arguments: [itemID])
            try Self.bump(db, key)
            return LocalOutgoingTransition(
                snapshot: try Self.snapshot(db, key, directory: self.directory),
                clientGeneratedID: itemID, disposition: .cancelled)
        }
    }

    public func finalizeOutgoing(
        chatID: String, threadID: String? = nil, itemID: String, expectedRevision: Int64
    ) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            guard let item = before.outgoing.first(where: { $0.clientGeneratedID == itemID }),
                item.confirmedMessage != nil, item.isPublished, !item.isCancelled,
                item.editRevision == expectedRevision,
                item.acknowledgedRevision == expectedRevision,
                item.claimedPatch == nil
            else { return before }
            try db.execute(
                sql: "DELETE FROM outgoing_message WHERE client_generated_id = ?",
                arguments: [itemID])
            try Self.bump(db, key)
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    public func failMutation(
        chatID: String, threadID: String? = nil, itemID: String, patchRevision: Int64?,
        retryable: Bool
    ) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            guard let item = before.outgoing.first(where: { $0.clientGeneratedID == itemID }) else {
                return before
            }
            if let patchRevision {
                guard !item.isCancelled, item.claimedPatch?.revision == patchRevision else {
                    return before
                }
            } else {
                guard item.isCancelled else { return before }
            }
            try db.execute(
                sql:
                    "UPDATE outgoing_message SET state = 'failed', mutation_retryable = ? WHERE client_generated_id = ?",
                arguments: [retryable, itemID])
            try Self.bump(db, key)
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    private static func releasedItem(
        _ snapshot: LocalConversationSnapshot, itemID: String, expectedRevision: Int64
    ) throws -> LocalOutgoingMessage {
        guard let item = snapshot.outgoing.first(where: { $0.clientGeneratedID == itemID }),
            !item.isCancelled, item.editRevision == expectedRevision
        else { throw LocalStorageError.staleDraft }
        return item
    }

    private static func validateIdentity(_ message: MessageResponse, item: LocalOutgoingMessage)
        throws
    {
        guard message.chatId == item.chatID, message.replyRootId == item.threadID,
            message.clientGeneratedId == item.clientGeneratedID,
            message.sender.uid == item.senderID,
            item.confirmedMessage.map({ $0.id == message.id }) ?? true
        else { throw LocalStorageError.staleDraft }
    }

    private static func transition(
        _ db: Database, _ key: ConversationKey, itemID: String, directory: URL
    ) throws -> LocalOutgoingTransition {
        let snapshot = try snapshot(db, key, directory: directory)
        guard let item = snapshot.outgoing.first(where: { $0.clientGeneratedID == itemID }) else {
            throw LocalStorageError.staleDraft
        }
        let disposition: LocalOutgoingDisposition =
            item.isCancelled
            ? .cancelled
            : item.isPublished && item.acknowledgedRevision == item.editRevision
                && item.claimedPatch == nil
                ? .completed : .retained
        return LocalOutgoingTransition(
            snapshot: snapshot, clientGeneratedID: itemID, disposition: disposition)
    }

    private static func freezeLegacyClaims(
        _ db: Database, _ key: ConversationKey, directory: URL
    ) throws -> Bool {
        guard
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(SELECT 1 FROM outgoing_message
                        WHERE chat_id = ? AND thread_id = ? AND frozen_create IS NULL
                        AND (dispatch_claimed = 1 OR state = 'sending'))
                    """, arguments: [key.chatID, key.threadID ?? ""]) == true
        else { return false }
        let items = try snapshot(db, key, directory: directory).outgoing
        var changed = false
        for item in items
        where (item.dispatchClaimed || item.state == .sending) && item.frozenCreate == nil {
            // Legacy claimed rows had no separate intent. A missing checkpoint or a
            // post-claim selection cannot be used to guess the original POST payload.
            guard item.intentAttachments == nil else { throw LocalStorageError.corruptRecord }
            if !item.dispatchClaimed {
                try db.execute(
                    sql:
                        "UPDATE outgoing_message SET dispatch_claimed = 1 WHERE client_generated_id = ?",
                    arguments: [item.clientGeneratedID])
            }
            try freeze(db, item)
            changed = true
        }
        return changed
    }

    private static func freeze(_ db: Database, _ item: LocalOutgoingMessage) throws {
        guard item.frozenCreate == nil else { return }
        guard !item.isBlocked, item.isReadyForDispatch,
            item.forwardRequest != nil || item.messageType != .text
                || !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !(item.intentAttachments ?? item.attachments.map(LocalEditAttachment.local))
                    .isEmpty
        else { throw LocalStorageError.corruptRecord }
        let frozen = LocalFrozenCreate(
            body: item.forwardRequest == nil ? item.body : nil,
            forwardRequest: item.forwardRequest, revision: item.editRevision)
        try db.execute(
            sql:
                "UPDATE outgoing_message SET frozen_create = ? WHERE client_generated_id = ? AND frozen_create IS NULL",
            arguments: [try JSONEncoder().encode(frozen), item.clientGeneratedID])
    }

    private static func mergeCheckpoint(
        _ proposed: LocalOutgoingAttachment, into old: LocalOutgoingAttachment
    ) throws -> LocalOutgoingAttachment? {
        guard old.sourcePath == proposed.sourcePath, old.previewPath == proposed.previewPath else {
            return nil
        }
        guard old.isAudio == proposed.isAudio, old.isFile == proposed.isFile else {
            throw LocalStorageError.invalidAttachments
        }
        if old.isAudio || old.isFile {
            guard proposed.preparedPath == old.preparedPath, proposed.mimeType == old.mimeType,
                proposed.fileName == old.fileName, proposed.byteCount == old.byteCount,
                proposed.width == old.width, proposed.height == old.height
            else { throw LocalStorageError.invalidAttachments }
        }
        guard old.attachmentID == nil || old.attachmentID == proposed.attachmentID else {
            return nil
        }
        var merged = proposed
        merged.position = old.position
        return merged == old ? nil : merged
    }

    private static func validateEditAttachments(
        _ selection: [LocalEditAttachment], directory: URL, requireSource: Bool = true
    ) throws {
        guard selection.count <= 20 else { throw LocalStorageError.invalidAttachments }
        var slotIDs = Set<String>()
        var uploadedIDs = Set<String>()
        for (position, selected) in selection.enumerated() {
            switch selected {
            case .local(var slot):
                let mimeType = slot.mimeType.lowercased()
                guard !slot.isFile, !slot.isAudio,
                    mimeType.hasPrefix("image/") || mimeType.hasPrefix("video/"),
                    slot.position == position, slotIDs.insert(slot.id).inserted
                else { throw LocalStorageError.invalidAttachments }
                if let id = slot.attachmentID, !uploadedIDs.insert(id).inserted {
                    throw LocalStorageError.invalidAttachments
                }
                slot.position = 0
                try validateAttachments([slot], directory: directory, requireSource: requireSource)
            case .server(let attachment):
                let kind = attachment.kind.lowercased()
                guard !attachment.id.isEmpty, kind.hasPrefix("image") || kind.hasPrefix("video"),
                    !attachment.url.isEmpty, attachment.size > 0,
                    uploadedIDs.insert(attachment.id).inserted
                else { throw LocalStorageError.invalidAttachments }
            }
        }
    }

    private static func encodeEditAttachments(
        _ selection: [LocalEditAttachment], directory: URL
    ) throws -> Data {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let stored = try selection.map { selected in
            switch selected {
            case .server: return selected
            case .local(let slot):
                return .local(try mapPaths(slot) { try relativePath($0, root: root) })
            }
        }
        return try JSONEncoder().encode(stored)
    }

    private static func decodeEditAttachments(_ data: Data, directory: URL) throws
        -> [LocalEditAttachment]
    {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return try JSONDecoder().decode([LocalEditAttachment].self, from: data).map { selected in
            switch selected {
            case .server: return selected
            case .local(let slot):
                return .local(
                    try mapPaths(slot) { try absolutePath($0, directory: directory, root: root) })
            }
        }
    }

    private static func key(_ row: Row) -> ConversationKey {
        let thread: String = row["thread_id"]
        return ConversationKey(chatID: row["chat_id"], threadID: thread.isEmpty ? nil : thread)
    }

    private static func ensure(_ db: Database, _ key: ConversationKey) throws {
        try db.execute(
            sql: "INSERT OR IGNORE INTO local_conversation(chat_id, thread_id) VALUES (?, ?)",
            arguments: [key.chatID, key.threadID ?? ""])
    }

    private static func bump(_ db: Database, _ key: ConversationKey) throws {
        try db.execute(
            sql:
                "UPDATE local_conversation SET revision = revision + 1 WHERE chat_id = ? AND thread_id = ?",
            arguments: [key.chatID, key.threadID ?? ""])
    }

    private static func writeRevision(
        _ db: Database, _ key: ConversationKey, _ revision: Int64, _ date: Date
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO draft_revision (chat_id, thread_id, edit_revision, updated_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(chat_id, thread_id) DO UPDATE SET edit_revision = excluded.edit_revision, updated_at = excluded.updated_at
                WHERE excluded.edit_revision > draft_revision.edit_revision
                """,
            arguments: [key.chatID, key.threadID ?? "", revision, date.timeIntervalSince1970])
    }

    private static func insert(
        _ db: Database, _ key: ConversationKey, id: String, senderID: Int32, text: String,
        replyData: Data?, date: Date, revision: Int64, blocked: Bool, metadataData: Data? = nil
    ) throws {
        let sequence = try Int64.fetchOne(
            db,
            sql:
                "SELECT next_enqueue_sequence FROM local_conversation WHERE chat_id = ? AND thread_id = ?",
            arguments: [key.chatID, key.threadID ?? ""])!
        try db.execute(
            sql: """
                INSERT INTO outgoing_message
                    (client_generated_id, chat_id, thread_id, sender_id, text, enqueued_at, enqueue_sequence,
                     dispatch_order, state, reply_to_message, is_blocked, edit_revision, updated_at, metadata)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'queued', ?, ?, ?, ?, ?)
                """,
            arguments: [
                id, key.chatID, key.threadID ?? "", senderID, text, date.timeIntervalSince1970,
                sequence, sequence, replyData, blocked, revision, date.timeIntervalSince1970,
                metadataData,
            ])
        try db.execute(
            sql:
                "UPDATE local_conversation SET next_enqueue_sequence = next_enqueue_sequence + 1 WHERE chat_id = ? AND thread_id = ?",
            arguments: [key.chatID, key.threadID ?? ""])
    }

    private static func editableTail(
        _ snapshot: LocalConversationSnapshot, itemID: String, expectedRevision: Int64
    ) throws -> LocalOutgoingMessage {
        guard let item = snapshot.composingItem ?? snapshot.outgoing.last,
            item.clientGeneratedID == itemID
        else { throw LocalStorageError.notTail }
        guard !item.dispatchClaimed else { throw LocalStorageError.dispatchAlreadyClaimed }
        guard item.editRevision == expectedRevision else { throw LocalStorageError.staleDraft }
        return item
    }

    private static func validateAttachments(
        _ attachments: [LocalOutgoingAttachment], directory: URL, requireSource: Bool = true
    ) throws {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for (position, slot) in attachments.enumerated() {
            let validDimensions =
                slot.isAudio || slot.isFile
                ? slot.width == 0 && slot.height == 0 : slot.width > 0 && slot.height > 0
            guard slot.position == position, !slot.id.isEmpty, !slot.generation.isEmpty,
                validDimensions, slot.byteCount > 0,
                slot.attachmentID?.isEmpty != true
            else { throw LocalStorageError.invalidAttachments }
            if slot.isFile {
                guard slot.preparedPath == slot.sourcePath, slot.previewPath == slot.sourcePath,
                    !slot.fileName.isEmpty, !slot.mimeType.isEmpty
                else { throw LocalStorageError.invalidAttachments }
            }
            if slot.isAudio {
                guard attachments.count == 1, slot.mimeType == "audio/mp4",
                    slot.preparedPath == slot.sourcePath, slot.previewPath == slot.sourcePath,
                    URL(fileURLWithPath: slot.fileName).pathExtension.lowercased() == "m4a"
                else {
                    throw LocalStorageError.invalidAttachments
                }
            }
            for path in [slot.sourcePath, slot.previewPath] + [slot.preparedPath].compactMap({ $0 })
            {
                let url = URL(fileURLWithPath: path)
                guard path.hasPrefix("/"),
                    url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root)
                else { throw LocalStorageError.invalidAttachments }
                if FileManager.default.fileExists(atPath: path) {
                    guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
                    else { throw LocalStorageError.invalidAttachments }
                } else if requireSource && slot.attachmentID == nil {
                    throw LocalStorageError.invalidAttachments
                }
            }
        }
    }

    // SQLite stores account-relative references; the public worker/UI model uses absolute URLs.
    // Application containers can relocate while the account directory and database survive.
    private static func mapPaths(
        _ attachment: LocalOutgoingAttachment, transform: (String) throws -> String
    ) rethrows -> LocalOutgoingAttachment {
        var slot = attachment
        slot.sourcePath = try transform(slot.sourcePath)
        slot.previewPath = try transform(slot.previewPath)
        slot.preparedPath = try slot.preparedPath.map(transform)
        return slot
    }

    private static func relativePath(_ path: String, root: String) throws -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix("/"), resolved.hasPrefix(root) else {
            throw LocalStorageError.invalidAttachments
        }
        return String(resolved.dropFirst(root.count))
    }

    private static func absolutePath(_ path: String, directory: URL, root: String) throws -> String
    {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw LocalStorageError.corruptRecord
        }
        let url = directory.appendingPathComponent(path).standardizedFileURL
        guard url.resolvingSymlinksInPath().path.hasPrefix(root) else {
            throw LocalStorageError.corruptRecord
        }
        return url.path
    }

    private static func encodeAttachments(_ attachments: [LocalOutgoingAttachment], directory: URL)
        throws -> Data
    {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return try JSONEncoder().encode(
            attachments.map {
                try mapPaths($0) { try relativePath($0, root: root) }
            })
    }

    private static func decodeAttachments(_ data: Data, directory: URL) throws
        -> [LocalOutgoingAttachment]
    {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return try JSONDecoder().decode([LocalOutgoingAttachment].self, from: data).map {
            try mapPaths($0) { try absolutePath($0, directory: directory, root: root) }
        }
    }

    private static func snapshot(_ db: Database, _ key: ConversationKey, directory: URL) throws
        -> LocalConversationSnapshot
    {
        let arguments: StatementArguments = [key.chatID, key.threadID ?? ""]
        let revision =
            try Int64.fetchOne(
                db,
                sql: "SELECT revision FROM local_conversation WHERE chat_id = ? AND thread_id = ?",
                arguments: arguments) ?? 0
        let watermark = try Row.fetchOne(
            db,
            sql:
                "SELECT edit_revision, updated_at FROM draft_revision WHERE chat_id = ? AND thread_id = ?",
            arguments: arguments)
        let rows = try Row.fetchAll(
            db,
            sql:
                "SELECT * FROM outgoing_message WHERE chat_id = ? AND thread_id = ? ORDER BY enqueue_sequence",
            arguments: arguments)
        let items = try rows.map { row in
            guard let state = LocalOutgoingMessage.State(rawValue: row["state"]),
                let sender = Int32(exactly: row["sender_id"] as Int64)
            else { throw LocalStorageError.corruptRecord }
            let attachments = try decodeAttachments(
                row["attachments"] as Data, directory: directory)
            guard Set(attachments.map(\.id)).count == attachments.count,
                attachments.enumerated().allSatisfy({ $0.offset == $0.element.position })
            else { throw LocalStorageError.corruptRecord }
            let sticker = try (row["sticker"] as Data?).map {
                try JSONDecoder().decode(MessageStickerResponse.self, from: $0)
            }
            let forward = try (row["forward_request"] as Data?).map {
                try JSONDecoder().decode(LocalForwardRequest.self, from: $0)
            }
            let frozen = try (row["frozen_create"] as Data?).map {
                try JSONDecoder().decode(LocalFrozenCreate.self, from: $0)
            }
            let intent = try (row["intent_attachments"] as Data?).map {
                try decodeEditAttachments($0, directory: directory)
            }
            let confirmed = try (row["confirmed_message"] as Data?).map {
                try JSONDecoder().decode(MessageResponse.self, from: $0)
            }
            let patch = try (row["claimed_patch"] as Data?).map {
                try JSONDecoder().decode(LocalClaimedPatch.self, from: $0)
            }
            let speakingRestriction = try (row["speaking_restriction"] as String?).map {
                guard let mode = SpeakingMode(rawValue: $0) else {
                    throw LocalStorageError.corruptRecord
                }
                return mode
            }
            if let forward {
                guard !forward.sources.isEmpty, forward.sources.count <= 100,
                    Set(forward.messageIDs).count == forward.sources.count,
                    forward.sources.allSatisfy({ $0.chatId == forward.sourceChatID }),
                    attachments.isEmpty, sticker == nil, !(row["is_blocked"] as Bool),
                    (row["text"] as String).isEmpty,
                    (row["reply_to_message"] as Data?) == nil
                else { throw LocalStorageError.corruptRecord }
            }
            guard sticker == nil || (attachments.isEmpty && !(row["is_blocked"] as Bool)) else {
                throw LocalStorageError.corruptRecord
            }
            if attachments.contains(where: \.isAudio) {
                guard attachments.count == 1, let audio = attachments.first,
                    audio.mimeType == "audio/mp4", audio.width == 0, audio.height == 0,
                    audio.preparedPath == audio.sourcePath, audio.previewPath == audio.sourcePath,
                    (row["text"] as String).isEmpty, !(row["is_blocked"] as Bool), sticker == nil
                else {
                    throw LocalStorageError.corruptRecord
                }
            }
            let item = LocalOutgoingMessage(
                clientGeneratedID: row["client_generated_id"], chatID: key.chatID,
                threadID: key.threadID, senderID: sender, text: row["text"],
                replyToMessage: try decodeReply(row["reply_to_message"]),
                enqueuedAt: Date(timeIntervalSince1970: row["enqueued_at"]),
                enqueueSequence: row["enqueue_sequence"], dispatchOrder: row["enqueue_sequence"],
                state: state, attachments: attachments, isBlocked: row["is_blocked"],
                editRevision: row["edit_revision"], compressionEnabled: row["compression_enabled"],
                dispatchClaimed: row["dispatch_claimed"], sticker: sticker, forwardRequest: forward,
                speakingRestriction: speakingRestriction, frozenCreate: frozen,
                intentAttachments: intent, confirmedMessage: confirmed,
                isPublished: row["is_published"], isCancelled: row["is_cancelled"],
                acknowledgedRevision: row["acknowledged_revision"], claimedPatch: patch,
                mutationRetryable: row["mutation_retryable"],
                metadata: try (row["metadata"] as Data?).map {
                    try JSONDecoder().decode(MessageMetadataInput.self, from: $0)
                })
            try validateAttachments(attachments, directory: directory, requireSource: false)
            if let intent {
                guard !item.isBlocked, item.forwardRequest == nil, item.messageType == .text else {
                    throw LocalStorageError.corruptRecord
                }
                try validateEditAttachments(intent, directory: directory, requireSource: false)
            }
            guard item.editRevision >= 0, item.acknowledgedRevision >= -1,
                item.acknowledgedRevision <= item.editRevision,
                !item.isBlocked || (frozen == nil && confirmed == nil && !item.isCancelled),
                confirmed != nil
                    || (item.acknowledgedRevision == -1 && !item.isPublished && patch == nil)
            else { throw LocalStorageError.corruptRecord }
            if let frozen {
                guard (frozen.body == nil) != (frozen.forwardRequest == nil),
                    frozen.revision >= 0, frozen.revision <= item.editRevision,
                    frozen.forwardRequest == item.forwardRequest
                else { throw LocalStorageError.corruptRecord }
                if let body = frozen.body {
                    guard body.clientGeneratedId == item.clientGeneratedID,
                        body.messageType == item.messageType,
                        body.replyToId == item.replyToMessage?.id,
                        body.stickerId == item.sticker?.id,
                        body.attachmentIds.allSatisfy({ !$0.isEmpty }),
                        Set(body.attachmentIds).count == body.attachmentIds.count,
                        body.messageType != .text || body.message?.isEmpty == false
                            || !body.attachmentIds.isEmpty
                    else { throw LocalStorageError.corruptRecord }
                }
            }
            if let confirmed {
                guard frozen != nil, item.acknowledgedRevision >= frozen!.revision else {
                    throw LocalStorageError.corruptRecord
                }
                try validateIdentity(confirmed, item: item)
            }
            if let patch {
                guard confirmed != nil, item.isPublished,
                    patch.revision > item.acknowledgedRevision, patch.revision <= item.editRevision,
                    !patch.text.isEmpty || !patch.attachmentIDs.isEmpty,
                    patch.attachmentIDs.allSatisfy({ !$0.isEmpty }),
                    Set(patch.attachmentIDs).count == patch.attachmentIDs.count
                else { throw LocalStorageError.corruptRecord }
            }
            return item
        }
        let composing = items.last?.isBlocked == true ? items.last : nil
        guard items.filter(\.isBlocked).count == (composing == nil ? 0 : 1) else {
            throw LocalStorageError.corruptRecord
        }
        let updatedAt: Date
        if composing != nil, let row = rows.last {
            updatedAt = Date(timeIntervalSince1970: row["updated_at"])
        } else if let watermark {
            updatedAt = Date(timeIntervalSince1970: watermark["updated_at"])
        } else {
            updatedAt = .distantPast
        }
        let draft = LocalDraft(
            text: composing?.text ?? "", replyToMessage: composing?.replyToMessage,
            editRevision: composing?.editRevision ?? watermark?["edit_revision"] ?? 0,
            updatedAt: updatedAt, itemID: composing?.clientGeneratedID,
            attachments: composing?.attachments ?? [],
            compressionEnabled: composing?.compressionEnabled ?? true,
            linkPreviews: composing?.metadata?.linkPreviews ?? [])
        return LocalConversationSnapshot(
            chatID: key.chatID, threadID: key.threadID, revision: revision, draft: draft,
            outgoing: items.filter { !$0.isBlocked }, composingItem: composing)
    }

    private static func decodeReply(_ data: Data?) throws -> MessagePreview? {
        try data.map { try JSONDecoder().decode(MessagePreview.self, from: $0) }
    }
}
