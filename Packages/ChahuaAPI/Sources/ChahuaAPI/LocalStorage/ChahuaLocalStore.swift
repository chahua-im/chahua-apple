import Foundation
import GRDB

public final class ChahuaLocalStore: Sendable {
    public let directory: URL
    public let userID: Int32
    private let accountRoot: URL
    let database: DatabaseQueue

    // Accessed only on the database writer, and advanced only after commit.
    private nonisolated(unsafe) var stamps: [ConversationKey: Stamp] = [:]

    public init(directory: URL, userID: Int32) throws {
        self.directory = directory.standardizedFileURL
        self.userID = userID
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        #if os(iOS)
            try manager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory.path)
        #endif
        accountRoot = directory.resolvingSymlinksInPath().standardizedFileURL
        let path = directory.appendingPathComponent("chat.sqlite").path
        database = try DatabaseQueue(path: path)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try migrateLocalStorage(database)
    }

    /// Retires the database connection before the owner removes its files.
    public func close() throws {
        try database.close()
    }

    public func restore() async throws -> [LocalConversationSnapshot] {
        let failure = OutboxFailure(stage: .create, reason: .unknownOutcome, retry: .automatic)
        return try await database.write { db in
            let interrupted = try Row.fetchAll(
                db, sql: "SELECT chat_id, thread_id FROM outgoing_message WHERE state = 'sending'"
            ).map(Self.key)
            if !interrupted.isEmpty {
                try db.execute(
                    sql:
                        "UPDATE outgoing_message SET state = 'failed', failure = ? WHERE state = 'sending'",
                    arguments: [try JSONEncoder().encode(failure)])
            }
            let changed = Dictionary(
                uniqueKeysWithValues: interrupted.map { key in
                    var stamp = self.stamps[key, default: Stamp()]
                    stamp.revision += 1
                    return (key, stamp)
                })
            let snapshots = try Self.keys(db).map { key in
                try self.snapshot(db, key, changed[key] ?? self.stamps[key, default: Stamp()])
            }
            if !changed.isEmpty {
                db.afterNextTransaction { _ in self.stamps.merge(changed) { _, new in new } }
            }
            return snapshots
        }
    }

    public func load() async throws -> [LocalConversationSnapshot] {
        try await database.read { db in
            try Self.keys(db).map { try self.snapshot(db, $0, self.stamps[$0, default: Stamp()]) }
        }
    }

    public func saveDraft(
        chatID: String, threadID: String? = nil, text: String, editRevision: Int64, updatedAt: Date,
        replyToMessage: MessagePreview? = nil, linkPreviews: [LinkPreviewInput] = []
    ) async throws -> LocalConversationSnapshot {
        try await update(ConversationKey(chatID: chatID, threadID: threadID)) { db, key, stamp in
            guard editRevision > stamp.draftRevision else { return .unchanged }
            var draft = try self.readDraft(db, key)
            draft.text = text
            draft.reply = replyToMessage
            draft.metadata =
                linkPreviews.isEmpty ? nil : MessageMetadataInput(linkPreviews: linkPreviews)
            try self.writeDraft(db, key, draft, date: updatedAt)
            return .draft(editRevision, updatedAt)
        }.snapshot
    }

    public func enqueueText(
        chatID: String, threadID: String? = nil, clientGeneratedID: String, text: String,
        enqueuedAt: Date, clearedDraftRevision: Int64, replyToMessage: MessagePreview? = nil,
        metadata: MessageMetadataInput? = nil
    ) async throws -> LocalConversationSnapshot {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await update(ConversationKey(chatID: chatID, threadID: threadID)) {
            db, key, stamp in
            guard clearedDraftRevision > stamp.draftRevision else {
                throw LocalStorageError.staleDraft
            }
            var draft = try self.readDraft(db, key)
            guard !text.isEmpty || !draft.attachments.isEmpty else {
                throw LocalStorageError.blankMessage
            }
            let isFile = draft.attachments.contains(where: \.isFile)
            draft.text = isFile ? "" : text
            draft.reply = replyToMessage
            draft.metadata = isFile ? nil : metadata
            let failure = draft.attachments.lazy.compactMap(\.failure).first.map(
                Self.preparationFailure)
            try self.insert(
                db, key, id: clientGeneratedID, draft, date: enqueuedAt, failure: failure)
            // File payloads cannot carry a caption. Append it in the same transaction.
            if isFile, !text.isEmpty {
                try self.insert(
                    db, key, id: UUID().uuidString, Content(text: text, metadata: metadata),
                    date: enqueuedAt)
            }
            try db.execute(
                sql: "DELETE FROM draft WHERE chat_id = ? AND thread_id = ?",
                arguments: Self.arguments(key))
            return .draft(clearedDraftRevision, enqueuedAt)
        }.snapshot
    }

    public func enqueueIndependentText(
        chatID: String, threadID: String? = nil, clientGeneratedID: String, text: String,
        enqueuedAt: Date
    ) async throws -> LocalConversationSnapshot {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalStorageError.blankMessage }
        return try await enqueue(
            ConversationKey(chatID: chatID, threadID: threadID), id: clientGeneratedID,
            Content(text: text), date: enqueuedAt)
    }

    public func enqueueSticker(
        chatID: String, threadID: String? = nil, clientGeneratedID: String,
        sticker: MessageStickerResponse, enqueuedAt: Date, replyToMessage: MessagePreview? = nil
    ) async throws -> LocalConversationSnapshot {
        try await enqueue(
            ConversationKey(chatID: chatID, threadID: threadID), id: clientGeneratedID,
            Content(reply: replyToMessage, sticker: sticker), date: enqueuedAt)
    }

    public func enqueueVoice(
        chatID: String, threadID: String? = nil, clientGeneratedID: String,
        attachment: LocalOutgoingAttachment, enqueuedAt: Date, replyToMessage: MessagePreview? = nil
    ) async throws -> LocalConversationSnapshot {
        guard attachment.isAudio, !attachment.isUploaded, attachment.failure == nil else {
            throw LocalStorageError.invalidAttachments
        }
        try validateAttachments([attachment], requireSource: true)
        return try await enqueue(
            ConversationKey(chatID: chatID, threadID: threadID), id: clientGeneratedID,
            Content(reply: replyToMessage, attachments: [attachment], compressionEnabled: false),
            date: enqueuedAt)
    }

    public func enqueueForward(
        chatID: String, threadID: String? = nil, request: LocalForwardRequest
    ) async throws -> LocalConversationSnapshot {
        guard !request.sources.isEmpty, request.sources.count <= 100,
            Set(request.messageIDs).count == request.sources.count,
            request.sources.allSatisfy({
                $0.chatId == request.sourceChatID && !$0.isDeleted
                    && $0.messageType != .system && $0.messageType != .invite
            })
        else { throw LocalStorageError.unsupportedMessageType }
        return try await enqueue(
            ConversationKey(chatID: chatID, threadID: threadID), id: UUID().uuidString,
            Content(forward: request), date: Date())
    }

    public func setDraftAttachments(
        key: ConversationKey, attachments: [LocalOutgoingAttachment], compressionEnabled: Bool
    ) async throws -> LocalConversationSnapshot {
        try await update(key) { db, key, _ in
            var draft = try self.readDraft(db, key)
            let updated = try self.mergeSelection(
                attachments, with: draft.attachments,
                compressionChanged: draft.compressionEnabled != compressionEnabled)
            guard !draft.isEmptyDraft || !updated.isEmpty,
                updated != draft.attachments || compressionEnabled != draft.compressionEnabled
            else { return .unchanged }
            draft.attachments = updated
            draft.compressionEnabled = compressionEnabled
            try self.writeDraft(db, key, draft, date: Date())
            return .changed
        }.snapshot
    }

    public func checkpointAttachment(
        key: ConversationKey, itemID: String?, attachment: LocalOutgoingAttachment,
        failure: OutboxFailure? = nil
    ) async throws -> LocalConversationSnapshot {
        precondition(failure == nil || failure?.stage == .preparation)
        var checkpoint = attachment
        if let failure { checkpoint.failure = failure.reason }
        let slot = checkpoint
        return try await update(key) { db, key, _ in
            if itemID == nil, let row = try Self.draftRow(db, key) {
                var draft = try self.decode(row)
                if let index = Self.slotIndex(slot, in: draft) {
                    guard try Self.mergeCheckpoint(slot, into: &draft.attachments[index])
                    else { return .unchanged }
                    try self.validateAttachments(draft.attachments)
                    try self.writeDraft(
                        db, key, draft, date: Date(timeIntervalSince1970: row["updated_at"]))
                    return .changed
                }
            }
            // A job started on the draft may finish after submit moved the slot.
            for row in try Self.outgoingRows(db, key, itemID: itemID) {
                let state: String = row["state"]
                guard state != "sending" else { continue }
                let oldFailure = try Self.failure(row)
                guard oldFailure?.stage != .create else { continue }
                var content = try self.decode(row)
                guard let index = Self.slotIndex(slot, in: content) else { continue }
                guard try Self.mergeCheckpoint(slot, into: &content.attachments[index])
                else { return .unchanged }
                try self.validateAttachments(content.attachments)
                let rowFailure = oldFailure ?? failure ?? slot.failure.map(Self.preparationFailure)
                try self.writeContent(
                    db, id: row["client_generated_id"], content, failure: rowFailure)
                return .changed
            }
            return .unchanged
        }.snapshot
    }

    public func editOutgoing(
        key: ConversationKey, itemID: String, text: String, replyToMessage: MessagePreview?,
        attachments: [LocalOutgoingAttachment], compressionEnabled: Bool,
        metadata: MessageMetadataInput? = nil
    ) async throws -> LocalConversationSnapshot {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await update(key) { db, key, _ in
            guard let row = try Self.outgoingRow(db, key, id: itemID) else {
                throw LocalStorageError.missingOutgoing
            }
            let old = try self.message(row, key)
            guard old.isEditable else { throw LocalStorageError.outgoingNotEditable }
            guard !text.isEmpty || !attachments.isEmpty else {
                throw LocalStorageError.blankMessage
            }
            let isFile = attachments.contains(where: \.isFile)
            guard !isFile || text.isEmpty else { throw LocalStorageError.unsupportedMessageType }
            var updated = try self.mergeSelection(
                attachments, with: old.attachments,
                compressionChanged: compressionEnabled != old.compressionEnabled)
            for i in updated.indices { updated[i].failure = nil }
            let content = Content(
                text: text, reply: replyToMessage, attachments: updated,
                compressionEnabled: compressionEnabled,
                metadata: isFile ? nil : metadata)
            try self.writeContent(db, id: itemID, content, failure: nil)
            return .changed
        }.snapshot
    }

    public func removeOutgoing(key: ConversationKey, itemID: String) async throws
        -> LocalConversationSnapshot
    {
        try await update(key) { db, key, _ in
            guard let row = try Self.outgoingRow(db, key, id: itemID) else { return .unchanged }
            guard (row["state"] as String) != "sending" else {
                throw LocalStorageError.outgoingSending
            }
            try Self.delete(db, id: itemID)
            return .changed
        }.snapshot
    }

    public func claimNext(
        chatID: String, threadID: String? = nil, expectedID: String, retryCreate: Bool = false
    ) async throws -> LocalOutgoingClaim {
        let key = ConversationKey(chatID: chatID, threadID: threadID)
        // The caller serializes this transaction with acquisition/release of editor holds.
        let (snapshot, changed) = try await update(key) { db, key, _ in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql:
                        "SELECT * FROM outgoing_message WHERE chat_id = ? AND thread_id = ? ORDER BY position LIMIT 1",
                    arguments: Self.arguments(key)),
                (row["client_generated_id"] as String) == expectedID
            else { return .unchanged }
            let head = try self.message(row, key)
            guard head.isReadyForDispatch,
                head.retryNotBefore.map({ $0 <= Date() }) ?? true,
                head.state == .pending || (retryCreate && head.failure?.stage == .create)
            else { return .unchanged }
            try db.execute(
                sql:
                    "UPDATE outgoing_message SET state = 'sending', failure = NULL WHERE client_generated_id = ?",
                arguments: [expectedID])
            return .changed
        }
        return LocalOutgoingClaim(
            snapshot: snapshot, message: changed ? snapshot.outgoing.first : nil)
    }

    /// Revert a claim only when the queue can prove it never entered the transport.
    public func releaseUnsentClaim(
        key: ConversationKey, itemID: String, priorFailure: OutboxFailure?,
        retryNotBefore: Date? = nil
    ) async throws -> LocalConversationSnapshot {
        try await update(key) { db, key, _ in
            try db.execute(
                sql: """
                    UPDATE outgoing_message SET state = ?, failure = ?,
                        retry_not_before = COALESCE(?, retry_not_before)
                    WHERE chat_id = ? AND thread_id = ? AND client_generated_id = ? AND state = 'sending'
                    """,
                arguments: [
                    priorFailure == nil ? "pending" : "failed",
                    try priorFailure.map { try JSONEncoder().encode($0) },
                    retryNotBefore?.timeIntervalSince1970,
                    key.chatID, key.threadID ?? "", itemID,
                ])
            return db.changesCount > 0 ? .changed : .unchanged
        }.snapshot
    }

    public func fail(
        key: ConversationKey, itemID: String, failure: OutboxFailure, retryNotBefore: Date? = nil
    ) async throws -> LocalConversationSnapshot {
        precondition(failure.stage == .create)
        return try await update(key) { db, key, _ in
            try db.execute(
                sql: """
                    UPDATE outgoing_message SET state = 'failed', failure = ?, retry_not_before = ?
                    WHERE chat_id = ? AND thread_id = ? AND client_generated_id = ? AND state = 'sending'
                    """,
                arguments: [
                    try JSONEncoder().encode(failure), retryNotBefore?.timeIntervalSince1970,
                    key.chatID, key.threadID ?? "", itemID,
                ])
            return db.changesCount > 0 ? .changed : .unchanged
        }.snapshot
    }

    public func retryPreparation(key: ConversationKey, itemID: String) async throws
        -> LocalConversationSnapshot
    {
        try await update(key) { db, key, _ in
            guard let row = try Self.outgoingRow(db, key, id: itemID),
                try Self.failure(row)?.stage == .preparation
            else { return .unchanged }
            var content = try self.decode(row)
            let now = Date()
            guard content.attachments.allSatisfy({ $0.retryNotBefore.map { $0 <= now } ?? true })
            else { return .unchanged }
            for i in content.attachments.indices { content.attachments[i].failure = nil }
            try self.writeContent(db, id: itemID, content, failure: nil)
            return .changed
        }.snapshot
    }

    public func settleCreate(
        _ message: MessageResponse, published: Bool, cacheHistory: Bool = true
    ) async throws -> LocalConversationSnapshot? {
        guard message.sender.uid == userID, message.replyRootId != "" else { return nil }
        let key = ConversationKey(chatID: message.chatId, threadID: message.replyRootId)
        let (snapshot, changed) = try await update(key) { db, key, _ in
            guard let row = try Self.outgoingRow(db, key, id: message.clientGeneratedId) else {
                return .unchanged
            }
            let state: String = row["state"]
            if state != "sending" {
                guard state == "failed", try Self.failure(row)?.stage == .create else {
                    return .unchanged
                }
            }
            if published && cacheHistory {
                try Self.cacheIsolatedMessage(db, message, in: key)
            }
            try Self.delete(db, id: message.clientGeneratedId)
            return .changed
        }
        return changed ? snapshot : nil
    }

    public func hasWork() async throws -> Bool {
        try await database.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS (SELECT 1 FROM draft UNION ALL SELECT 1 FROM outgoing_message)"
            ) ?? false
        }
    }

    public func purge() async throws {
        try await database.write { db in
            try Self.clearCache(db)
            try db.execute(
                sql: "DELETE FROM pending_read; DELETE FROM outgoing_message; DELETE FROM draft;")
        }
    }

    private struct Stamp: Sendable {
        var revision: Int64 = 0
        var draftRevision: Int64 = 0
        var draftDate = Date.distantPast
    }

    private enum Change {
        case unchanged, changed
        case draft(Int64, Date)
    }

    private struct Content: Codable, Sendable {
        var text = ""
        var reply: MessagePreview?
        var attachments: [LocalOutgoingAttachment] = []
        var compressionEnabled = true
        var sticker: MessageStickerResponse?
        var forward: LocalForwardRequest?
        var metadata: MessageMetadataInput?

        var isEmptyDraft: Bool {
            text.isEmpty && reply == nil && attachments.isEmpty
                && (metadata?.linkPreviews.isEmpty ?? true)
        }
    }

    private func update(
        _ key: ConversationKey,
        _ operation: @escaping @Sendable (Database, ConversationKey, Stamp) throws -> Change
    ) async throws -> (snapshot: LocalConversationSnapshot, changed: Bool) {
        let key = key.threadID == "" ? ConversationKey(chatID: key.chatID) : key
        return try await database.write { db in
            var stamp = self.stamps[key, default: Stamp()]
            switch try operation(db, key, stamp) {
            case .unchanged: return (try self.snapshot(db, key, stamp), false)
            case .changed: break
            case .draft(let revision, let date):
                stamp.draftRevision = revision
                stamp.draftDate = date
            }
            stamp.revision += 1
            let committed = stamp
            let snapshot = try self.snapshot(db, key, committed)
            db.afterNextTransaction { _ in self.stamps[key] = committed }
            return (snapshot, true)
        }
    }

    private func enqueue(_ key: ConversationKey, id: String, _ content: Content, date: Date)
        async throws
        -> LocalConversationSnapshot
    {
        try await update(key) { db, key, _ in
            try self.insert(db, key, id: id, content, date: date)
            return .changed
        }.snapshot
    }

    private func insert(
        _ db: Database, _ key: ConversationKey, id: String, _ content: Content, date: Date,
        failure: OutboxFailure? = nil
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO outgoing_message
                    (client_generated_id, chat_id, thread_id, position, state, content, failure, created_at)
                SELECT ?, ?, ?, COALESCE(MAX(position), -1) + 1, ?, ?, ?, ?
                FROM outgoing_message WHERE chat_id = ? AND thread_id = ?
                """,
            arguments: [
                id, key.chatID, key.threadID ?? "", failure == nil ? "pending" : "failed",
                try encode(content), try failure.map { try JSONEncoder().encode($0) },
                date.timeIntervalSince1970, key.chatID, key.threadID ?? "",
            ])
    }

    private func writeContent(
        _ db: Database, id: String, _ content: Content, failure: OutboxFailure?
    ) throws {
        try db.execute(
            sql:
                "UPDATE outgoing_message SET content = ?, state = ?, failure = ? WHERE client_generated_id = ?",
            arguments: [
                try encode(content), failure == nil ? "pending" : "failed",
                try failure.map { try JSONEncoder().encode($0) }, id,
            ])
    }

    private func writeDraft(_ db: Database, _ key: ConversationKey, _ content: Content, date: Date)
        throws
    {
        guard !content.isEmptyDraft else {
            try db.execute(
                sql: "DELETE FROM draft WHERE chat_id = ? AND thread_id = ?",
                arguments: Self.arguments(key))
            return
        }
        try db.execute(
            sql: """
                INSERT INTO draft (chat_id, thread_id, content, updated_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(chat_id, thread_id) DO UPDATE
                SET content = excluded.content, updated_at = excluded.updated_at
                """,
            arguments: [
                key.chatID, key.threadID ?? "", try encode(content), date.timeIntervalSince1970,
            ])
    }

    private func readDraft(_ db: Database, _ key: ConversationKey) throws -> Content {
        try Self.draftRow(db, key).map(decode) ?? Content()
    }

    private func snapshot(_ db: Database, _ key: ConversationKey, _ stamp: Stamp) throws
        -> LocalConversationSnapshot
    {
        let row = try Self.draftRow(db, key)
        let content = try row.map(decode) ?? Content()
        return LocalConversationSnapshot(
            chatID: key.chatID, threadID: key.threadID, revision: stamp.revision,
            draft: LocalDraft(
                text: content.text, replyToMessage: content.reply,
                editRevision: stamp.draftRevision,
                updatedAt: row.map { Date(timeIntervalSince1970: $0["updated_at"]) }
                    ?? stamp.draftDate,
                attachments: content.attachments, compressionEnabled: content.compressionEnabled,
                linkPreviews: content.metadata?.linkPreviews ?? []),
            outgoing: try Self.outgoingRows(db, key).map { try message($0, key) })
    }

    private func message(_ row: Row, _ key: ConversationKey) throws -> LocalOutgoingMessage {
        guard let state = LocalOutgoingMessage.State(rawValue: row["state"]) else {
            throw LocalStorageError.corruptRecord
        }
        let content = try decode(row)
        let failure = try Self.failure(row)
        let item = LocalOutgoingMessage(
            clientGeneratedID: row["client_generated_id"], chatID: key.chatID,
            threadID: key.threadID,
            senderID: userID, text: content.text, replyToMessage: content.reply,
            enqueuedAt: Date(timeIntervalSince1970: row["created_at"]), position: row["position"],
            state: state, attachments: content.attachments,
            compressionEnabled: content.compressionEnabled,
            sticker: content.sticker, forwardRequest: content.forward, metadata: content.metadata,
            failure: failure,
            retryNotBefore: (row["retry_not_before"] as Double?).map(
                Date.init(timeIntervalSince1970:)))
        guard (state != .sending && failure?.stage != .create) || item.isReadyForDispatch else {
            throw LocalStorageError.corruptRecord
        }
        return item
    }

    private static func failure(_ row: Row) throws -> OutboxFailure? {
        try (row["failure"] as Data?).map { try JSONDecoder().decode(OutboxFailure.self, from: $0) }
    }

    private static func preparationFailure(_ reason: OutboxFailure.Reason) -> OutboxFailure {
        let retry: OutboxFailure.Retry =
            reason == .network || reason == .unknownOutcome
            ? .automatic : .manual
        return OutboxFailure(stage: .preparation, reason: reason, retry: retry)
    }

    private static func arguments(_ key: ConversationKey) -> StatementArguments {
        [key.chatID, key.threadID ?? ""]
    }

    private static func key(_ row: Row) -> ConversationKey {
        let thread: String = row["thread_id"]
        return ConversationKey(chatID: row["chat_id"], threadID: thread.isEmpty ? nil : thread)
    }

    private static func keys(_ db: Database) throws -> [ConversationKey] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT chat_id, thread_id FROM draft
                UNION SELECT chat_id, thread_id FROM outgoing_message
                ORDER BY chat_id, thread_id
                """
        ).map(key)
    }

    private static func draftRow(_ db: Database, _ key: ConversationKey) throws -> Row? {
        try Row.fetchOne(
            db, sql: "SELECT content, updated_at FROM draft WHERE chat_id = ? AND thread_id = ?",
            arguments: arguments(key))
    }

    private static func outgoingRow(_ db: Database, _ key: ConversationKey, id: String) throws
        -> Row?
    {
        try Row.fetchOne(
            db,
            sql:
                "SELECT * FROM outgoing_message WHERE chat_id = ? AND thread_id = ? AND client_generated_id = ?",
            arguments: [key.chatID, key.threadID ?? "", id])
    }

    private static func outgoingRows(_ db: Database, _ key: ConversationKey, itemID: String? = nil)
        throws -> [Row]
    {
        if let itemID {
            return try outgoingRow(db, key, id: itemID).map { [$0] } ?? []
        }
        return try Row.fetchAll(
            db,
            sql:
                "SELECT * FROM outgoing_message WHERE chat_id = ? AND thread_id = ? ORDER BY position",
            arguments: arguments(key))
    }

    private static func delete(_ db: Database, id: String) throws {
        try db.execute(
            sql: "DELETE FROM outgoing_message WHERE client_generated_id = ?", arguments: [id])
    }

    private func mergeSelection(
        _ selected: [LocalOutgoingAttachment], with existing: [LocalOutgoingAttachment],
        compressionChanged: Bool
    ) throws -> [LocalOutgoingAttachment] {
        guard !selected.contains(where: \.isAudio),
            !selected.contains(where: \.isFile) || selected.allSatisfy(\.isFile)
        else { throw LocalStorageError.unsupportedMessageType }
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let updated = selected.enumerated().map { position, choice in
            var slot = choice
            if let old = byID[choice.id] {
                let sameSource =
                    old.sourcePath == choice.sourcePath && old.previewPath == choice.previewPath
                if sameSource, old.generation == choice.generation { slot = old }
                if !sameSource || (compressionChanged && !slot.isFile) {
                    if slot.generation == old.generation { slot.generation = UUID().uuidString }
                    slot.attachmentID = nil
                    slot.failure = nil
                    slot.retryNotBefore = nil
                    slot.preparedPath = slot.isFile ? slot.sourcePath : nil
                } else if old.generation != slot.generation {
                    slot.attachmentID = nil
                    slot.retryNotBefore = nil
                }
            }
            slot.position = position
            return slot
        }
        try validateAttachments(updated)
        // Existing source files may have vanished. Workers report that as preparation failure.
        for slot in updated where byID[slot.id]?.sourcePath != slot.sourcePath {
            try validateFiles(slot, requireSource: true)
        }
        return updated
    }

    private static func slotIndex(_ slot: LocalOutgoingAttachment, in content: Content) -> Int? {
        content.attachments.firstIndex { $0.id == slot.id && $0.generation == slot.generation }
    }

    private static func mergeCheckpoint(
        _ checkpoint: LocalOutgoingAttachment, into current: inout LocalOutgoingAttachment
    ) throws -> Bool {
        guard !current.isUploaded, current.sourcePath == checkpoint.sourcePath,
            current.previewPath == checkpoint.previewPath
        else { return false }
        guard current.isFile == checkpoint.isFile, current.isAudio == checkpoint.isAudio else {
            throw LocalStorageError.invalidAttachments
        }
        if current.isAudio || current.isFile {
            guard current.preparedPath == checkpoint.preparedPath,
                current.mimeType == checkpoint.mimeType,
                current.fileName == checkpoint.fileName, current.byteCount == checkpoint.byteCount,
                current.width == checkpoint.width, current.height == checkpoint.height
            else { throw LocalStorageError.invalidAttachments }
        }
        var merged = checkpoint
        merged.position = current.position
        guard merged != current else { return false }
        current = merged
        return true
    }

    private func validateAttachments(
        _ attachments: [LocalOutgoingAttachment], requireSource: Bool = false
    ) throws {
        guard attachments.count <= 20 else { throw LocalStorageError.invalidAttachments }
        var ids = Set<String>()
        var uploaded = Set<String>()
        for (position, slot) in attachments.enumerated() {
            let validDimensions =
                slot.isAudio || slot.isFile
                ? slot.width == 0 && slot.height == 0 : slot.width > 0 && slot.height > 0
            guard slot.position == position, !slot.id.isEmpty, ids.insert(slot.id).inserted,
                !slot.generation.isEmpty, validDimensions, slot.byteCount > 0
            else { throw LocalStorageError.invalidAttachments }
            if let id = slot.attachmentID {
                guard !id.isEmpty, uploaded.insert(id).inserted, slot.failure == nil
                else { throw LocalStorageError.invalidAttachments }
            }
            if slot.isFile || slot.isAudio {
                guard slot.preparedPath == slot.sourcePath, slot.previewPath == slot.sourcePath,
                    !slot.fileName.isEmpty, !slot.mimeType.isEmpty
                else { throw LocalStorageError.invalidAttachments }
            }
            if slot.isAudio {
                guard attachments.count == 1, slot.mimeType == "audio/mp4",
                    URL(fileURLWithPath: slot.fileName).pathExtension.lowercased() == "m4a"
                else { throw LocalStorageError.invalidAttachments }
            }
            try validateFiles(slot, requireSource: requireSource)
        }
    }

    private func validateFiles(_ slot: LocalOutgoingAttachment, requireSource: Bool) throws {
        for path in [slot.sourcePath, slot.previewPath] + [slot.preparedPath].compactMap({ $0 }) {
            _ = try relativePath(path)
            if FileManager.default.fileExists(atPath: path) {
                guard
                    try URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey])
                        .isRegularFile == true
                else { throw LocalStorageError.invalidAttachments }
            } else if requireSource && !slot.isUploaded {
                throw LocalStorageError.invalidAttachments
            }
        }
    }

    private func encode(_ content: Content) throws -> Data {
        var stored = content
        stored.attachments = try content.attachments.map { try Self.mapPaths($0, relativePath) }
        return try JSONEncoder().encode(stored)
    }

    private func decode(_ row: Row) throws -> Content {
        var stored = try JSONDecoder().decode(Content.self, from: row["content"])
        guard Set(stored.attachments.map(\.id)).count == stored.attachments.count,
            stored.attachments.enumerated().allSatisfy({ $0.offset == $0.element.position })
        else { throw LocalStorageError.corruptRecord }
        stored.attachments = try stored.attachments.map { try Self.mapPaths($0, absolutePath) }
        return stored
    }

    static func redactDurableReplyPreviews(_ db: Database, chatID: String, ids: Set<MessageID>)
        throws
    {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for row in try Row.fetchAll(
            db, sql: "SELECT thread_id, content FROM draft WHERE chat_id = ?",
            arguments: [chatID])
        {
            var content = try decoder.decode(Content.self, from: row["content"])
            guard let reply = content.reply, ids.contains(reply.id), !reply.isDeleted else {
                continue
            }
            content.reply = reply.redactedForDeletion()
            try db.execute(
                sql: "UPDATE draft SET content = ? WHERE chat_id = ? AND thread_id = ?",
                arguments: [try encoder.encode(content), chatID, row["thread_id"] as String])
        }
        let outgoing = try Row.fetchAll(
            db,
            sql: """
                SELECT chat_id, client_generated_id, content FROM outgoing_message
                WHERE chat_id = ? OR json_extract(CAST(content AS TEXT), '$.forward.sourceChatID') = ?
                """, arguments: [chatID, chatID])
        for row in outgoing {
            let destination: String = row["chat_id"]
            var content = try decoder.decode(Content.self, from: row["content"])
            var changed = false
            if destination == chatID, let reply = content.reply, ids.contains(reply.id),
                !reply.isDeleted
            {
                content.reply = reply.redactedForDeletion()
                changed = true
            }
            if let forward = content.forward, forward.sourceChatID == chatID {
                let sources = forward.sources.map {
                    (ids.contains($0.id) ? $0.redactedForDeletion() : $0)
                        .redactingReplyPreview(messageIDs: ids)
                }
                if forward.sources != sources {
                    content.forward = .init(
                        sourceChatID: forward.sourceChatID, sources: sources,
                        allowPlaceholders: forward.allowPlaceholders)
                    changed = true
                }
            }
            if changed {
                try db.execute(
                    sql: "UPDATE outgoing_message SET content = ? WHERE client_generated_id = ?",
                    arguments: [try encoder.encode(content), row["client_generated_id"] as String])
            }
        }
    }

    private static func mapPaths(
        _ attachment: LocalOutgoingAttachment, _ transform: (String) throws -> String
    ) rethrows -> LocalOutgoingAttachment {
        var slot = attachment
        slot.sourcePath = try transform(slot.sourcePath)
        slot.previewPath = try transform(slot.previewPath)
        slot.preparedPath = try slot.preparedPath.map(transform)
        return slot
    }

    // SQLite owns account-relative references; worker/UI models use absolute paths.
    private func relativePath(_ path: String) throws -> String {
        let root = accountRoot.path + "/"
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix("/"), resolved.hasPrefix(root) else {
            throw LocalStorageError.invalidAttachments
        }
        return String(resolved.dropFirst(root.count))
    }

    private func absolutePath(_ path: String) throws -> String {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw LocalStorageError.corruptRecord
        }
        let url = accountRoot.appendingPathComponent(path).standardizedFileURL
        guard url.resolvingSymlinksInPath().path.hasPrefix(accountRoot.path + "/") else {
            throw LocalStorageError.corruptRecord
        }
        return url.path
    }
}
