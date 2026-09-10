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
            let interrupted = try String.fetchAll(db, sql: "SELECT DISTINCT chat_id FROM outgoing_message WHERE state = 'sending'")
            try db.execute(sql: "UPDATE outgoing_message SET state = 'queued' WHERE state = 'sending'")
            for chat in interrupted { try Self.bump(db, chat) }
            return try String.fetchAll(db, sql: "SELECT chat_id FROM local_conversation ORDER BY chat_id")
                .map { try Self.snapshot(db, $0) }
        }
    }

    public func saveDraft(chatID: String, text: String, editRevision: Int64, updatedAt: Date, replyToMessage: MessagePreview? = nil) async throws -> LocalConversationSnapshot {
        let replyData = try replyToMessage.map { try JSONEncoder().encode($0) }
        return try await database.write { db in
            try Self.ensure(db, chatID)
            if try Self.writeDraft(db, chatID, text, editRevision, updatedAt, replyData) { try Self.bump(db, chatID) }
            return try Self.snapshot(db, chatID)
        }
    }

    public func enqueueText(chatID: String, senderID: Int32, clientGeneratedID: String, text: String, enqueuedAt: Date, clearedDraftRevision: Int64, replyToMessage: MessagePreview? = nil) async throws -> LocalConversationSnapshot {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalStorageError.blankMessage }
        let replyData = try replyToMessage.map { try JSONEncoder().encode($0) }
        return try await database.write { db in
            try Self.ensure(db, chatID)
            guard try Self.writeDraft(db, chatID, "", clearedDraftRevision, enqueuedAt, nil) else { throw LocalStorageError.staleDraft }
            let sequence = try Int64.fetchOne(db, sql: "SELECT next_enqueue_sequence FROM local_conversation WHERE chat_id = ?", arguments: [chatID])!
            let order = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(dispatch_order), -1) + 1 FROM outgoing_message WHERE chat_id = ?", arguments: [chatID])!
            let failed = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM outgoing_message WHERE chat_id = ? AND state = 'failed')", arguments: [chatID])!
            try db.execute(sql: """
                INSERT INTO outgoing_message
                    (client_generated_id, chat_id, sender_id, text, enqueued_at, enqueue_sequence, dispatch_order, state, reply_to_message)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [clientGeneratedID, chatID, senderID, trimmed, enqueuedAt.timeIntervalSince1970, sequence, order, failed ? "failed" : "queued", replyData])
            try db.execute(sql: "UPDATE local_conversation SET next_enqueue_sequence = next_enqueue_sequence + 1 WHERE chat_id = ?", arguments: [chatID])
            try Self.bump(db, chatID)
            return try Self.snapshot(db, chatID)
        }
    }

    public func claimNext(chatID: String) async throws -> LocalOutgoingClaim {
        try await database.write { db in
            try Self.ensure(db, chatID)
            let before = try Self.snapshot(db, chatID)
            guard !before.outgoing.contains(where: { $0.state == .sending }), let head = before.outgoing.first, head.state == .queued else {
                return LocalOutgoingClaim(snapshot: before, message: nil)
            }
            try db.execute(sql: "UPDATE outgoing_message SET state = 'sending' WHERE client_generated_id = ?", arguments: [head.clientGeneratedID])
            try Self.bump(db, chatID)
            let snapshot = try Self.snapshot(db, chatID)
            return LocalOutgoingClaim(snapshot: snapshot, message: snapshot.outgoing.first)
        }
    }

    public func fail(chatID: String, clientGeneratedID: String) async throws -> LocalConversationSnapshot {
        try await database.write { db in
            try Self.ensure(db, chatID)
            if let order = try Int64.fetchOne(db, sql: "SELECT dispatch_order FROM outgoing_message WHERE chat_id = ? AND client_generated_id = ?", arguments: [chatID, clientGeneratedID]) {
                try db.execute(sql: "UPDATE outgoing_message SET state = 'failed' WHERE chat_id = ? AND dispatch_order >= ?", arguments: [chatID, order])
                try Self.bump(db, chatID)
            }
            return try Self.snapshot(db, chatID)
        }
    }

    public func retry(chatID: String, clientGeneratedID: String, scope: OutgoingRetryScope) async throws -> LocalConversationSnapshot {
        try await database.write { db in
            try Self.ensure(db, chatID)
            let before = try Self.snapshot(db, chatID)
            guard let index = before.outgoing.firstIndex(where: { $0.clientGeneratedID == clientGeneratedID && $0.state == .failed }) else { return before }
            let selected = scope == .message ? [before.outgoing[index]] : Array(before.outgoing[index...])
            let ids = Set(selected.map(\.clientGeneratedID))
            let remaining = before.outgoing.filter { !ids.contains($0.clientGeneratedID) }
            let ordered = remaining.filter { $0.state == .sending } + selected + remaining.filter { $0.state != .sending }
            for (order, row) in ordered.enumerated() {
                try db.execute(sql: "UPDATE outgoing_message SET dispatch_order = ?, state = ? WHERE client_generated_id = ?", arguments: [order, ids.contains(row.clientGeneratedID) ? "queued" : row.state.rawValue, row.clientGeneratedID])
            }
            try Self.bump(db, chatID)
            return try Self.snapshot(db, chatID)
        }
    }

    public func acknowledge(chatID: String, clientGeneratedID: String) async throws -> LocalConversationSnapshot {
        try await database.write { db in
            try Self.ensure(db, chatID)
            try db.execute(sql: "DELETE FROM outgoing_message WHERE chat_id = ? AND client_generated_id = ?", arguments: [chatID, clientGeneratedID])
            if db.changesCount > 0 { try Self.bump(db, chatID) }
            return try Self.snapshot(db, chatID)
        }
    }

    private static func ensure(_ db: Database, _ chat: String) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO local_conversation(chat_id) VALUES (?)", arguments: [chat])
    }

    private static func bump(_ db: Database, _ chat: String) throws {
        try db.execute(sql: "UPDATE local_conversation SET revision = revision + 1 WHERE chat_id = ?", arguments: [chat])
    }

    private static func writeDraft(_ db: Database, _ chat: String, _ text: String, _ revision: Int64, _ date: Date, _ replyData: Data?) throws -> Bool {
        try db.execute(sql: """
            INSERT INTO draft (chat_id, text, edit_revision, updated_at, reply_to_message) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(chat_id) DO UPDATE SET text = excluded.text, edit_revision = excluded.edit_revision, updated_at = excluded.updated_at, reply_to_message = excluded.reply_to_message
            WHERE excluded.edit_revision > draft.edit_revision
            """, arguments: [chat, text, revision, date.timeIntervalSince1970, replyData])
        return db.changesCount > 0
    }

    private static func snapshot(_ db: Database, _ chat: String) throws -> LocalConversationSnapshot {
        let revision = try Int64.fetchOne(db, sql: "SELECT revision FROM local_conversation WHERE chat_id = ?", arguments: [chat]) ?? 0
        let draftRow = try Row.fetchOne(db, sql: "SELECT * FROM draft WHERE chat_id = ?", arguments: [chat])
        let draft = try draftRow.map { LocalDraft(text: $0["text"], replyToMessage: try decodeReply($0["reply_to_message"]), editRevision: $0["edit_revision"], updatedAt: Date(timeIntervalSince1970: $0["updated_at"])) }
            ?? LocalDraft(text: "", replyToMessage: nil, editRevision: 0, updatedAt: .distantPast)
        let outgoing = try Row.fetchAll(db, sql: "SELECT * FROM outgoing_message WHERE chat_id = ? ORDER BY dispatch_order", arguments: [chat]).map { row in
            guard let state = LocalOutgoingMessage.State(rawValue: row["state"]), let sender = Int32(exactly: row["sender_id"] as Int64) else { throw LocalStorageError.corruptRecord }
            return LocalOutgoingMessage(clientGeneratedID: row["client_generated_id"], chatID: chat, senderID: sender, text: row["text"], replyToMessage: try decodeReply(row["reply_to_message"]), enqueuedAt: Date(timeIntervalSince1970: row["enqueued_at"]), enqueueSequence: row["enqueue_sequence"], dispatchOrder: row["dispatch_order"], state: state)
        }
        return LocalConversationSnapshot(chatID: chat, revision: revision, draft: draft, outgoing: outgoing)
    }

    private static func decodeReply(_ data: Data?) throws -> MessagePreview? {
        try data.map { try JSONDecoder().decode(MessagePreview.self, from: $0) }
    }
}
