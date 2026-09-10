import Foundation
import GRDB

public final class ChahuaLocalStore: Sendable {
    private let database: DatabaseQueue

    public init(directory: URL) throws {
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
            try db.execute(sql: "UPDATE outgoing_message SET state = 'queued' WHERE state = 'sending'")
            for row in interrupted { try Self.bump(db, Self.key(row)) }
            return try Row.fetchAll(db, sql: "SELECT chat_id, thread_id FROM local_conversation ORDER BY chat_id, thread_id")
                .map { try Self.snapshot(db, Self.key($0)) }
        }
    }

    public func saveDraft(chatID: String, threadID: String? = nil, text: String, editRevision: Int64, updatedAt: Date, replyToMessage: MessagePreview? = nil) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        let replyData = try replyToMessage.map { try JSONEncoder().encode($0) }
        return try await database.write { db in
            try Self.ensure(db, key)
            if try Self.writeDraft(db, key, text, editRevision, updatedAt, replyData) { try Self.bump(db, key) }
            return try Self.snapshot(db, key)
        }
    }

    public func enqueueText(chatID: String, threadID: String? = nil, senderID: Int32, clientGeneratedID: String, text: String, enqueuedAt: Date, clearedDraftRevision: Int64, replyToMessage: MessagePreview? = nil) async throws -> LocalConversationSnapshot {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalStorageError.blankMessage }
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        let replyData = try replyToMessage.map { try JSONEncoder().encode($0) }
        return try await database.write { db in
            try Self.ensure(db, key)
            guard try Self.writeDraft(db, key, "", clearedDraftRevision, enqueuedAt, nil) else { throw LocalStorageError.staleDraft }
            let thread = key.threadID ?? ""
            let sequence = try Int64.fetchOne(db, sql: "SELECT next_enqueue_sequence FROM local_conversation WHERE chat_id = ? AND thread_id = ?", arguments: [chatID, thread])!
            let order = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(dispatch_order), -1) + 1 FROM outgoing_message WHERE chat_id = ? AND thread_id = ?", arguments: [chatID, thread])!
            let failed = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM outgoing_message WHERE chat_id = ? AND thread_id = ? AND state = 'failed')", arguments: [chatID, thread])!
            try db.execute(sql: """
                INSERT INTO outgoing_message
                    (client_generated_id, chat_id, thread_id, sender_id, text, enqueued_at, enqueue_sequence, dispatch_order, state, reply_to_message)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [clientGeneratedID, chatID, thread, senderID, trimmed, enqueuedAt.timeIntervalSince1970, sequence, order, failed ? "failed" : "queued", replyData])
            try db.execute(sql: "UPDATE local_conversation SET next_enqueue_sequence = next_enqueue_sequence + 1 WHERE chat_id = ? AND thread_id = ?", arguments: [chatID, thread])
            try Self.bump(db, key)
            return try Self.snapshot(db, key)
        }
    }

    public func claimNext(chatID: String, threadID: String? = nil) async throws -> LocalOutgoingClaim {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key)
            guard !before.outgoing.contains(where: { $0.state == .sending }), let head = before.outgoing.first, head.state == .queued else {
                return LocalOutgoingClaim(snapshot: before, message: nil)
            }
            try db.execute(sql: "UPDATE outgoing_message SET state = 'sending' WHERE client_generated_id = ?", arguments: [head.clientGeneratedID])
            try Self.bump(db, key)
            let snapshot = try Self.snapshot(db, key)
            return LocalOutgoingClaim(snapshot: snapshot, message: snapshot.outgoing.first)
        }
    }

    public func fail(chatID: String, threadID: String? = nil, clientGeneratedID: String) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            if let order = try Int64.fetchOne(db, sql: "SELECT dispatch_order FROM outgoing_message WHERE chat_id = ? AND thread_id = ? AND client_generated_id = ?", arguments: [chatID, threadID ?? "", clientGeneratedID]) {
                try db.execute(sql: "UPDATE outgoing_message SET state = 'failed' WHERE chat_id = ? AND thread_id = ? AND dispatch_order >= ?", arguments: [chatID, threadID ?? "", order])
                try Self.bump(db, key)
            }
            return try Self.snapshot(db, key)
        }
    }

    public func retry(chatID: String, threadID: String? = nil, clientGeneratedID: String, scope: OutgoingRetryScope) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            let before = try Self.snapshot(db, key)
            guard let index = before.outgoing.firstIndex(where: { $0.clientGeneratedID == clientGeneratedID && $0.state == .failed }) else { return before }
            let selected = scope == .message ? [before.outgoing[index]] : Array(before.outgoing[index...])
            let ids = Set(selected.map(\.clientGeneratedID))
            let remaining = before.outgoing.filter { !ids.contains($0.clientGeneratedID) }
            let ordered = remaining.filter { $0.state == .sending } + selected + remaining.filter { $0.state != .sending }
            for (order, row) in ordered.enumerated() {
                try db.execute(sql: "UPDATE outgoing_message SET dispatch_order = ?, state = ? WHERE client_generated_id = ?", arguments: [order, ids.contains(row.clientGeneratedID) ? "queued" : row.state.rawValue, row.clientGeneratedID])
            }
            try Self.bump(db, key)
            return try Self.snapshot(db, key)
        }
    }

    public func acknowledge(chatID: String, threadID: String? = nil, clientGeneratedID: String) async throws -> LocalConversationSnapshot {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        return try await database.write { db in
            try Self.ensure(db, key)
            try db.execute(sql: "DELETE FROM outgoing_message WHERE chat_id = ? AND thread_id = ? AND client_generated_id = ?", arguments: [chatID, threadID ?? "", clientGeneratedID])
            if db.changesCount > 0 { try Self.bump(db, key) }
            return try Self.snapshot(db, key)
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

    private static func writeDraft(_ db: Database, _ key: ConversationKey, _ text: String, _ revision: Int64, _ date: Date, _ replyData: Data?) throws -> Bool {
        try db.execute(sql: """
            INSERT INTO draft (chat_id, thread_id, text, edit_revision, updated_at, reply_to_message) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(chat_id, thread_id) DO UPDATE SET text = excluded.text, edit_revision = excluded.edit_revision, updated_at = excluded.updated_at, reply_to_message = excluded.reply_to_message
            WHERE excluded.edit_revision > draft.edit_revision
            """, arguments: [key.chatID, key.threadID ?? "", text, revision, date.timeIntervalSince1970, replyData])
        return db.changesCount > 0
    }

    private static func snapshot(_ db: Database, _ key: ConversationKey) throws -> LocalConversationSnapshot {
        let arguments: StatementArguments = [key.chatID, key.threadID ?? ""]
        let revision = try Int64.fetchOne(db, sql: "SELECT revision FROM local_conversation WHERE chat_id = ? AND thread_id = ?", arguments: arguments) ?? 0
        let draftRow = try Row.fetchOne(db, sql: "SELECT * FROM draft WHERE chat_id = ? AND thread_id = ?", arguments: arguments)
        let draft = try draftRow.map { LocalDraft(text: $0["text"], replyToMessage: try decodeReply($0["reply_to_message"]), editRevision: $0["edit_revision"], updatedAt: Date(timeIntervalSince1970: $0["updated_at"])) }
            ?? LocalDraft(text: "", replyToMessage: nil, editRevision: 0, updatedAt: .distantPast)
        let outgoing = try Row.fetchAll(db, sql: "SELECT * FROM outgoing_message WHERE chat_id = ? AND thread_id = ? ORDER BY dispatch_order", arguments: arguments).map { row in
            guard let state = LocalOutgoingMessage.State(rawValue: row["state"]), let sender = Int32(exactly: row["sender_id"] as Int64) else { throw LocalStorageError.corruptRecord }
            return LocalOutgoingMessage(clientGeneratedID: row["client_generated_id"], chatID: key.chatID, threadID: key.threadID, senderID: sender, text: row["text"], replyToMessage: try decodeReply(row["reply_to_message"]), enqueuedAt: Date(timeIntervalSince1970: row["enqueued_at"]), enqueueSequence: row["enqueue_sequence"], dispatchOrder: row["dispatch_order"], state: state)
        }
        return LocalConversationSnapshot(chatID: key.chatID, threadID: key.threadID, revision: revision, draft: draft, outgoing: outgoing)
    }

    private static func decodeReply(_ data: Data?) throws -> MessagePreview? {
        try data.map { try JSONDecoder().decode(MessagePreview.self, from: $0) }
    }
}
