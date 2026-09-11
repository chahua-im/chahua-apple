import Foundation
import GRDB

public final class ChahuaLocalStore: Sendable {
    public let directory: URL
    private let database: DatabaseQueue

    public init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #if os(iOS)
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        let path = directory.appendingPathComponent("chat.sqlite").path
        database = try DatabaseQueue(path: path)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try migrateLocalStorage(database)
    }

    public func restore() async throws -> [LocalConversationSnapshot] {
        try await database.write { db in
            let interrupted = try Row.fetchAll(db, sql: "SELECT DISTINCT chat_id, thread_id FROM outgoing_message WHERE state = 'sending'")
            try db.execute(sql: "UPDATE outgoing_message SET state = 'queued', dispatch_claimed = 1 WHERE state = 'sending'")
            for row in interrupted { try Self.bump(db, Self.key(row)) }
            return try Row.fetchAll(db, sql: "SELECT chat_id, thread_id FROM local_conversation ORDER BY chat_id, thread_id")
                .map { try Self.snapshot(db, Self.key($0), directory: self.directory) }
        }
    }

    public func beginComposition(chatID: String, threadID: String? = nil, senderID: Int32) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            if let item = before.composingItem {
                if item.senderID != senderID {
                    try db.execute(sql: "UPDATE outgoing_message SET sender_id = ? WHERE client_generated_id = ?", arguments: [senderID, item.clientGeneratedID])
                    try Self.bump(db, key)
                }
            } else {
                try Self.insert(db, key, id: UUID().uuidString, senderID: senderID, text: "", replyData: nil, date: Date(), revision: before.draft.editRevision, blocked: true)
                try Self.bump(db, key)
            }
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    public func saveDraft(chatID: String, threadID: String? = nil, text: String, editRevision: Int64, updatedAt: Date, replyToMessage: MessagePreview? = nil) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        let replyData = try replyToMessage.map { try JSONEncoder().encode($0) }
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            guard editRevision > before.draft.editRevision else { return before }
            if let item = before.composingItem {
                try db.execute(sql: "UPDATE outgoing_message SET text = ?, reply_to_message = ?, edit_revision = ?, updated_at = ? WHERE client_generated_id = ?", arguments: [text, replyData, editRevision, updatedAt.timeIntervalSince1970, item.clientGeneratedID])
            } else if !text.isEmpty || replyData != nil {
                try Self.insert(db, key, id: UUID().uuidString, senderID: 0, text: text, replyData: replyData, date: updatedAt, revision: editRevision, blocked: true)
            }
            try Self.writeRevision(db, key, editRevision, updatedAt)
            try Self.bump(db, key)
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    /// Releases the existing composition in place, or creates an already-released text item.
    /// The supplied identity is used only when there is no blocked tail.
    public func enqueueText(chatID: String, threadID: String? = nil, senderID: Int32, clientGeneratedID: String, text: String, enqueuedAt: Date, clearedDraftRevision: Int64, replyToMessage: MessagePreview? = nil) async throws -> LocalConversationSnapshot {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        let replyData = try replyToMessage.map { try JSONEncoder().encode($0) }
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            guard clearedDraftRevision > before.draft.editRevision else { throw LocalStorageError.staleDraft }
            guard !trimmed.isEmpty || before.composingItem?.attachments.isEmpty == false else { throw LocalStorageError.blankMessage }
            if let item = before.composingItem {
                try Self.validateAttachments(item.attachments, directory: self.directory)
                try db.execute(sql: "UPDATE outgoing_message SET sender_id = ?, text = ?, reply_to_message = ?, is_blocked = 0, edit_revision = ?, updated_at = ? WHERE client_generated_id = ?", arguments: [senderID, trimmed, replyData, clearedDraftRevision, enqueuedAt.timeIntervalSince1970, item.clientGeneratedID])
            } else {
                try Self.insert(db, key, id: clientGeneratedID, senderID: senderID, text: trimmed, replyData: replyData, date: enqueuedAt, revision: clearedDraftRevision, blocked: false)
            }
            try Self.writeRevision(db, key, clearedDraftRevision, enqueuedAt)
            try Self.bump(db, key)
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    public func setCompositionAttachments(chatID: String, threadID: String? = nil, itemID: String, expectedRevision: Int64, attachments: [LocalOutgoingAttachment], compressionEnabled: Bool) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            let item = try Self.editableTail(before, itemID: itemID, expectedRevision: expectedRevision)
            guard item.isBlocked else { throw LocalStorageError.notTail }
            guard attachments.count <= 20, Set(attachments.map(\.id)).count == attachments.count else { throw LocalStorageError.invalidAttachments }
            let existing = Dictionary(uniqueKeysWithValues: item.attachments.map { ($0.id, $0) })
            let optionsChanged = item.compressionEnabled != compressionEnabled
            let updated = try attachments.enumerated().map { position, proposed in
                var slot = proposed
                let old = existing[proposed.id]
                let sourceChanged = old.map { $0.sourcePath != proposed.sourcePath } ?? false
                if let old {
                    guard proposed.generation == old.generation else { throw LocalStorageError.staleDraft }
                    // A caller's snapshot can predate a completed worker checkpoint.
                    if !sourceChanged { slot = old }
                }
                if position != (old?.position ?? proposed.position) || sourceChanged || optionsChanged {
                    slot.generation = UUID().uuidString
                    slot.attachmentID = nil
                    slot.error = nil
                    if sourceChanged || optionsChanged { slot.preparedPath = nil }
                }
                slot.position = position
                return slot
            }
            try Self.validateAttachments(updated, directory: self.directory)
            guard updated != item.attachments || compressionEnabled != item.compressionEnabled else { return before }
            let revision = item.editRevision + 1
            let date = Date()
            try db.execute(sql: "UPDATE outgoing_message SET attachments = ?, compression_enabled = ?, edit_revision = ?, updated_at = ? WHERE client_generated_id = ?", arguments: [try Self.encodeAttachments(updated, directory: self.directory), compressionEnabled, revision, date.timeIntervalSince1970, itemID])
            try Self.writeRevision(db, key, revision, date)
            try Self.bump(db, key)
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    public func checkpointAttachment(chatID: String, threadID: String? = nil, itemID: String, attachment: LocalOutgoingAttachment) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            let matching = before.composingItem?.clientGeneratedID == itemID
                ? before.composingItem
                : before.outgoing.first { $0.clientGeneratedID == itemID }
            guard let item = matching,
                  !item.dispatchClaimed,
                  let index = item.attachments.firstIndex(where: { $0.id == attachment.id && $0.generation == attachment.generation }) else { return before }
            let old = item.attachments[index]
            guard old.position == attachment.position, old.sourcePath == attachment.sourcePath, old.previewPath == attachment.previewPath else { return before }
            // A late preparation completion cannot roll back a successful PUT.
            guard old.attachmentID == nil || old.attachmentID == attachment.attachmentID else { return before }
            guard attachment != old else { return before }
            var slots = item.attachments
            slots[index] = attachment
            try Self.validateAttachments(slots, directory: self.directory, requireSource: false)
            try db.execute(sql: "UPDATE outgoing_message SET attachments = ? WHERE client_generated_id = ?", arguments: [try Self.encodeAttachments(slots, directory: self.directory), itemID])
            try Self.bump(db, key)
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    public func blockTail(chatID: String, threadID: String? = nil, itemID: String, expectedRevision: Int64) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            let item = try Self.editableTail(before, itemID: itemID, expectedRevision: expectedRevision)
            guard !item.isBlocked else { return before }
            let revision = max(before.draft.editRevision, item.editRevision) + 1
            let date = Date()
            try db.execute(sql: "UPDATE outgoing_message SET is_blocked = 1, state = 'queued', edit_revision = ?, updated_at = ? WHERE client_generated_id = ?", arguments: [revision, date.timeIntervalSince1970, itemID])
            try Self.writeRevision(db, key, revision, date)
            try Self.bump(db, key)
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    public func revokeTail(chatID: String, threadID: String? = nil, itemID: String, expectedRevision: Int64) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            let item = try Self.editableTail(before, itemID: itemID, expectedRevision: expectedRevision)
            try db.execute(sql: "DELETE FROM outgoing_message WHERE client_generated_id = ?", arguments: [itemID])
            try Self.writeRevision(db, key, max(before.draft.editRevision, item.editRevision) + 1, Date())
            try Self.bump(db, key)
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    public func claimNext(chatID: String, threadID: String? = nil) async throws -> LocalOutgoingClaim {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            guard let head = before.outgoing.first, head.state == .queued, head.isReadyForDispatch else {
                return LocalOutgoingClaim(snapshot: before, message: nil)
            }
            try db.execute(sql: "UPDATE outgoing_message SET state = 'sending', dispatch_claimed = 1 WHERE client_generated_id = ?", arguments: [head.clientGeneratedID])
            try Self.bump(db, key)
            let snapshot = try Self.snapshot(db, key, directory: self.directory)
            return LocalOutgoingClaim(snapshot: snapshot, message: snapshot.outgoing.first)
        }
    }

    public func fail(chatID: String, threadID: String? = nil, clientGeneratedID: String) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            try db.execute(sql: "UPDATE outgoing_message SET state = 'failed' WHERE chat_id = ? AND thread_id = ? AND client_generated_id = ? AND is_blocked = 0 AND state != 'failed'", arguments: [chatID, threadID ?? "", clientGeneratedID])
            if db.changesCount > 0 { try Self.bump(db, key) }
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    public func retry(chatID: String, threadID: String? = nil, clientGeneratedID: String, scope: OutgoingRetryScope) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key, directory: self.directory)
            let items = before.outgoing + [before.composingItem].compactMap { $0 }
            guard let index = items.firstIndex(where: { $0.clientGeneratedID == clientGeneratedID }) else { return before }
            let selected = scope == .message ? [items[index]] : Array(items[index...])
            var changed = false
            for item in selected where item.state != .sending {
                var slots = item.attachments
                if !item.dispatchClaimed {
                    for index in slots.indices { slots[index].error = nil }
                }
                guard item.state == .failed || slots != item.attachments else { continue }
                try db.execute(sql: "UPDATE outgoing_message SET state = 'queued', attachments = ? WHERE client_generated_id = ?", arguments: [try Self.encodeAttachments(slots, directory: self.directory), item.clientGeneratedID])
                changed = true
            }
            if changed { try Self.bump(db, key) }
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    public func acknowledge(chatID: String, threadID: String? = nil, clientGeneratedID: String) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            try db.execute(sql: "DELETE FROM outgoing_message WHERE chat_id = ? AND thread_id = ? AND client_generated_id = ? AND is_blocked = 0", arguments: [chatID, threadID ?? "", clientGeneratedID])
            if db.changesCount > 0 { try Self.bump(db, key) }
            return try Self.snapshot(db, key, directory: self.directory)
        }
    }

    private static func key(_ row: Row) -> ConversationKey {
        let thread: String = row["thread_id"]
        return ConversationKey(chatID: row["chat_id"], threadID: thread.isEmpty ? nil : thread)
    }

    private static func ensure(_ db: Database, _ key: ConversationKey) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO local_conversation(chat_id, thread_id) VALUES (?, ?)", arguments: [key.chatID, key.threadID ?? ""])
    }

    private static func bump(_ db: Database, _ key: ConversationKey) throws {
        try db.execute(sql: "UPDATE local_conversation SET revision = revision + 1 WHERE chat_id = ? AND thread_id = ?", arguments: [key.chatID, key.threadID ?? ""])
    }

    private static func writeRevision(_ db: Database, _ key: ConversationKey, _ revision: Int64, _ date: Date) throws {
        try db.execute(sql: """
            INSERT INTO draft_revision (chat_id, thread_id, edit_revision, updated_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(chat_id, thread_id) DO UPDATE SET edit_revision = excluded.edit_revision, updated_at = excluded.updated_at
            WHERE excluded.edit_revision > draft_revision.edit_revision
            """, arguments: [key.chatID, key.threadID ?? "", revision, date.timeIntervalSince1970])
    }

    private static func insert(_ db: Database, _ key: ConversationKey, id: String, senderID: Int32, text: String, replyData: Data?, date: Date, revision: Int64, blocked: Bool) throws {
        let sequence = try Int64.fetchOne(db, sql: "SELECT next_enqueue_sequence FROM local_conversation WHERE chat_id = ? AND thread_id = ?", arguments: [key.chatID, key.threadID ?? ""])!
        try db.execute(sql: """
            INSERT INTO outgoing_message
                (client_generated_id, chat_id, thread_id, sender_id, text, enqueued_at, enqueue_sequence,
                 dispatch_order, state, reply_to_message, is_blocked, edit_revision, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'queued', ?, ?, ?, ?)
            """, arguments: [id, key.chatID, key.threadID ?? "", senderID, text, date.timeIntervalSince1970, sequence, sequence, replyData, blocked, revision, date.timeIntervalSince1970])
        try db.execute(sql: "UPDATE local_conversation SET next_enqueue_sequence = next_enqueue_sequence + 1 WHERE chat_id = ? AND thread_id = ?", arguments: [key.chatID, key.threadID ?? ""])
    }

    private static func editableTail(_ snapshot: LocalConversationSnapshot, itemID: String, expectedRevision: Int64) throws -> LocalOutgoingMessage {
        guard let item = snapshot.composingItem ?? snapshot.outgoing.last, item.clientGeneratedID == itemID else { throw LocalStorageError.notTail }
        guard !item.dispatchClaimed else { throw LocalStorageError.dispatchAlreadyClaimed }
        guard item.editRevision == expectedRevision else { throw LocalStorageError.staleDraft }
        return item
    }

    private static func validateAttachments(_ attachments: [LocalOutgoingAttachment], directory: URL, requireSource: Bool = true) throws {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for (position, slot) in attachments.enumerated() {
            guard slot.position == position, !slot.id.isEmpty, !slot.generation.isEmpty,
                  slot.width > 0, slot.height > 0, slot.byteCount > 0,
                  slot.attachmentID?.isEmpty != true else { throw LocalStorageError.invalidAttachments }
            for path in [slot.sourcePath, slot.previewPath] + [slot.preparedPath].compactMap({ $0 }) {
                let url = URL(fileURLWithPath: path)
                guard path.hasPrefix("/"), url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { throw LocalStorageError.invalidAttachments }
                if FileManager.default.fileExists(atPath: path) {
                    guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw LocalStorageError.invalidAttachments }
                } else if requireSource && slot.attachmentID == nil {
                    throw LocalStorageError.invalidAttachments
                }
            }
        }
    }

    // SQLite stores account-relative references; the public worker/UI model uses absolute URLs.
    // Application containers can relocate while the account directory and database survive.
    private static func encodeAttachments(_ attachments: [LocalOutgoingAttachment], directory: URL) throws -> Data {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        func relative(_ path: String) throws -> String {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix("/"), resolved.hasPrefix(root) else { throw LocalStorageError.invalidAttachments }
            return String(resolved.dropFirst(root.count))
        }
        let stored = try attachments.map { attachment in
            var slot = attachment
            slot.sourcePath = try relative(slot.sourcePath)
            slot.previewPath = try relative(slot.previewPath)
            slot.preparedPath = try slot.preparedPath.map(relative)
            return slot
        }
        return try JSONEncoder().encode(stored)
    }

    private static func decodeAttachments(_ data: Data, directory: URL) throws -> [LocalOutgoingAttachment] {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        func absolute(_ path: String) throws -> String {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw LocalStorageError.corruptRecord }
            let url = directory.appendingPathComponent(path).standardizedFileURL
            guard url.resolvingSymlinksInPath().path.hasPrefix(root) else { throw LocalStorageError.corruptRecord }
            return url.path
        }
        return try JSONDecoder().decode([LocalOutgoingAttachment].self, from: data).map { attachment in
            var slot = attachment
            slot.sourcePath = try absolute(slot.sourcePath)
            slot.previewPath = try absolute(slot.previewPath)
            slot.preparedPath = try slot.preparedPath.map(absolute)
            return slot
        }
    }

    private static func snapshot(_ db: Database, _ key: ConversationKey, directory: URL) throws -> LocalConversationSnapshot {
        let arguments: StatementArguments = [key.chatID, key.threadID ?? ""]
        let revision = try Int64.fetchOne(db, sql: "SELECT revision FROM local_conversation WHERE chat_id = ? AND thread_id = ?", arguments: arguments) ?? 0
        let watermark = try Row.fetchOne(db, sql: "SELECT edit_revision, updated_at FROM draft_revision WHERE chat_id = ? AND thread_id = ?", arguments: arguments)
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM outgoing_message WHERE chat_id = ? AND thread_id = ? ORDER BY enqueue_sequence", arguments: arguments)
        let items = try rows.map { row in
            guard let state = LocalOutgoingMessage.State(rawValue: row["state"]), let sender = Int32(exactly: row["sender_id"] as Int64) else { throw LocalStorageError.corruptRecord }
            let attachments = try decodeAttachments(row["attachments"] as Data, directory: directory)
            guard Set(attachments.map(\.id)).count == attachments.count,
                  attachments.enumerated().allSatisfy({ $0.offset == $0.element.position }) else { throw LocalStorageError.corruptRecord }
            return LocalOutgoingMessage(clientGeneratedID: row["client_generated_id"], chatID: key.chatID, threadID: key.threadID, senderID: sender, text: row["text"], replyToMessage: try decodeReply(row["reply_to_message"]), enqueuedAt: Date(timeIntervalSince1970: row["enqueued_at"]), enqueueSequence: row["enqueue_sequence"], dispatchOrder: row["enqueue_sequence"], state: state, attachments: attachments, isBlocked: row["is_blocked"], editRevision: row["edit_revision"], compressionEnabled: row["compression_enabled"], dispatchClaimed: row["dispatch_claimed"])
        }
        let composing = items.last?.isBlocked == true ? items.last : nil
        guard items.filter(\.isBlocked).count == (composing == nil ? 0 : 1) else { throw LocalStorageError.corruptRecord }
        let updatedAt: Date
        if composing != nil, let row = rows.last {
            updatedAt = Date(timeIntervalSince1970: row["updated_at"])
        } else if let watermark {
            updatedAt = Date(timeIntervalSince1970: watermark["updated_at"])
        } else {
            updatedAt = .distantPast
        }
        let draft = LocalDraft(text: composing?.text ?? "", replyToMessage: composing?.replyToMessage, editRevision: composing?.editRevision ?? watermark?["edit_revision"] ?? 0, updatedAt: updatedAt, itemID: composing?.clientGeneratedID, attachments: composing?.attachments ?? [], compressionEnabled: composing?.compressionEnabled ?? true)
        return LocalConversationSnapshot(chatID: key.chatID, threadID: key.threadID, revision: revision, draft: draft, outgoing: items.filter { !$0.isBlocked }, composingItem: composing)
    }

    private static func decodeReply(_ data: Data?) throws -> MessagePreview? {
        try data.map { try JSONDecoder().decode(MessagePreview.self, from: $0) }
    }
}
