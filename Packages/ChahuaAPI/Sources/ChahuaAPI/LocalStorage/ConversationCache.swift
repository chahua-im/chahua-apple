import Foundation
import GRDB

public enum CachedListScope: String, Sendable {
    case activeChats, archivedChats, activeThreads, archivedThreads

    var archived: Bool { self == .archivedChats || self == .archivedThreads }
    var chats: Bool { self == .activeChats || self == .archivedChats }
}

public enum CachedConversation: Sendable {
    case chat(ChatListItem)
    case thread(ThreadListItem)

    public var key: ConversationKey {
        switch self {
        case .chat(let item): ConversationKey(chatID: item.id)
        case .thread(let item): ConversationKey(chatID: item.chatId, threadID: item.threadRootMessage.id.description)
        }
    }

    var scope: CachedListScope {
        switch self {
        case .chat(let item): item.archived ? .archivedChats : .activeChats
        case .thread(let item): item.archived ? .archivedThreads : .activeThreads
        }
    }

    var activity: TimeInterval {
        switch self {
        case .chat(let item): item.lastMessageAt?.timeIntervalSince1970 ?? 0
        case .thread(let item): item.lastReplyAt.timeIntervalSince1970
        }
    }

    func encoded(_ db: Database) throws -> Data {
        let key = self.key
        let context = try ChahuaLocalStore.scopeContext(db, ConversationKey(chatID: key.chatID))
        let policy: MembershipMessagePolicy?
        if case .chat(let item) = self { policy = context?.policy ?? item.membershipMessagePolicy }
        else { policy = context?.policy }
        let hidesMembership = context?.settings?.showMembershipMessages == false || policy?.canView != true
        func sanitized(_ preview: MessagePreview?, keepsIdentity: Bool = false) throws -> MessagePreview? {
            guard let preview else { return nil }
            if preview.systemKind?.isMembership == true, hidesMembership {
                return keepsIdentity ? preview.redactedForDeletion() : nil
            }
            return if try ChahuaLocalStore.hasTombstone(db, key.chatID, preview.id) {
                preview.redactedForDeletion()
            } else { preview }
        }
        let encoder = JSONEncoder()
        switch self {
        case .chat(let item):
            return try encoder.encode(ChatListItem(
                id: item.id, name: item.name, avatar: item.avatar, lastMessageAt: item.lastMessageAt,
                unreadCount: 0, lastReadMessageId: item.lastReadMessageId,
                lastMessage: sanitized(item.lastMessage), mutedUntil: item.mutedUntil,
                muteOverride: item.muteOverride, isMuted: item.isMuted, archived: item.archived,
                kind: item.kind, peer: item.peer, membershipMessagePolicy: policy))
        case .thread(let item):
            return try encoder.encode(ThreadListItem(
                chatId: item.chatId, chatName: item.chatName, chatAvatar: item.chatAvatar,
                threadRootMessage: sanitized(item.threadRootMessage, keepsIdentity: true) ?? item.threadRootMessage,
                peer: item.peer, lastReply: sanitized(item.lastReply), replyCount: item.replyCount,
                lastReplyAt: item.lastReplyAt, unreadCount: 0, lastReadMessageId: item.lastReadMessageId,
                chatKind: item.chatKind, subscribedAt: item.subscribedAt, archived: item.archived))
        }
    }
}

public struct CachedListPage: Sendable {
    public struct Cursor: Sendable {
        let activity: Double
        let chatID: String
        let threadID: String
    }

    public let items: [CachedConversation]
    public let complete: Bool
    public let next: Cursor?
}

public struct CachedScopeContext: Sendable {
    public let policy: MembershipMessagePolicy?
    public let settings: ChatSettings?
    public let canSend: Bool?
    public let sendPeerUID: Int32?
    public let verifiedEmpty: Bool

    var hidesMembership: Bool { settings?.showMembershipMessages == false || policy?.canView != true }
}

public enum CachedHistoryPosition: Sendable {
    case latest
    case around(MessageID)
    case before(MessageID)
    case after(MessageID)
    case previousSection(MessageID)
    case nextSection(MessageID)
}

public struct CachedHistoryPage: Sendable {
    public let messages: [MessageResponse]
    public let context: CachedScopeContext?
    public let hasOlder: Bool
    public let hasNewer: Bool
    public let hasOlderSection: Bool
    public let hasNewerSection: Bool
    public let targetMissing: Bool
}

public struct PendingRead: Sendable, Equatable {
    public let key: ConversationKey
    public let base: MessageID?
    public let target: MessageID
}

public enum PendingReadRecording: Sendable, Equatable {
    case inserted, advanced, unchanged
}

extension ChahuaLocalStore {
    public func cacheEpoch() async throws -> Int64 {
        try await database.read { try Self.readEpoch($0) }
    }

    @discardableResult
    public func advanceCacheEpoch() async throws -> Int64 {
        try await database.write { try Self.advanceCacheEpoch($0) }
    }

    public func clearMessageHistory() async throws {
        try await database.write { try Self.clearCache($0) }
    }

    public func compactMessageStorage() async throws {
        try await database.vacuum()
    }

    public func cachedMessageBytes() async throws -> Int64 {
        try await database.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT
                    (SELECT total(length(payload)) FROM cached_message) +
                    (SELECT total(length(payload)) FROM cached_conversation) +
                    (SELECT total(coalesce(length(policy), 0) + coalesce(length(settings), 0)) FROM cached_scope)
                """) ?? 0
        }
    }

    static func clearCache(_ db: Database) throws {
        _ = try advanceCacheEpoch(db)
        try db.execute(sql: """
            DELETE FROM cached_member;
            DELETE FROM cached_message;
            DELETE FROM cached_segment;
            DELETE FROM cached_scope;
            DELETE FROM cached_conversation;
            DELETE FROM cached_list;
            DELETE FROM cached_tombstone;
            """)
    }

    private static func readEpoch(_ db: Database) throws -> Int64 {
        guard let epoch = try Int64.fetchOne(db, sql: "SELECT epoch FROM cache_meta WHERE singleton = 1")
        else { throw LocalStorageError.corruptRecord }
        return epoch
    }

    private static func advanceCacheEpoch(_ db: Database) throws -> Int64 {
        try db.execute(sql: "UPDATE cache_meta SET epoch = epoch + 1 WHERE singleton = 1")
        return try readEpoch(db)
    }

    public func cachedList(
        _ scope: CachedListScope, after cursor: CachedListPage.Cursor? = nil, limit: Int = 50
    ) async throws -> CachedListPage? {
        try await database.read { db in
            let complete = try Bool.fetchOne(
                db, sql: "SELECT complete FROM cached_list WHERE scope = ?", arguments: [scope.rawValue])
            var sql = "SELECT * FROM cached_conversation WHERE archived = ? AND (thread_id = '') = ?"
            var arguments: StatementArguments = [scope.archived, scope.chats]
            if let cursor {
                sql += " AND (activity < ? OR (activity = ? AND (chat_id, thread_id) > (?, ?)))"
                arguments += [cursor.activity, cursor.activity, cursor.chatID, cursor.threadID]
            }
            let limit = max(1, min(limit, 100))
            sql += " ORDER BY activity DESC, chat_id, thread_id LIMIT ?"
            arguments += [limit + 1]
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            guard complete != nil || !rows.isEmpty else { return nil }
            let items = try rows.prefix(limit).map { try Self.decodeConversation($0, isChat: scope.chats) }
            let next = rows.count > limit ? rows.prefix(limit).last.map {
                CachedListPage.Cursor(activity: $0["activity"], chatID: $0["chat_id"], threadID: $0["thread_id"])
            } : nil
            return CachedListPage(items: items, complete: complete == true, next: next)
        }
    }

    /// `seen` is passed only after every page of this projection succeeds.
    public func cacheList(
        _ scope: CachedListScope, items: [CachedConversation], seen: Set<ConversationKey>? = nil,
        fetchedAt: Date = Date(), epoch: Int64
    ) async throws {
        try await database.write { db in
            guard try Self.readEpoch(db) == epoch else { return }
            for item in items where item.scope == scope { try Self.upsertConversation(db, item) }
            if let seen {
                let payload = try JSONEncoder().encode(seen.map { [$0.chatID, $0.threadID ?? ""] })
                try db.execute(sql: """
                    DELETE FROM cached_conversation WHERE archived = ? AND (thread_id = '') = ?
                    AND (chat_id, thread_id) NOT IN (
                        SELECT value ->> 0, value ->> 1 FROM json_each(?)
                    )
                    """, arguments: [scope.archived, scope.chats, String(decoding: payload, as: UTF8.self)])
            }
            try db.execute(sql: """
                INSERT INTO cached_list VALUES (?, ?, ?)
                ON CONFLICT(scope) DO UPDATE SET complete = max(complete, excluded.complete),
                    fetched_at = excluded.fetched_at
                """, arguments: [scope.rawValue, seen != nil, fetchedAt.timeIntervalSince1970])
        }
    }

    public func cacheConversation(_ item: CachedConversation, epoch: Int64) async throws {
        try await database.write { db in
            guard try Self.readEpoch(db) == epoch else { return }
            try Self.upsertConversation(db, item)
        }
    }

    public func removeCachedConversation(_ key: ConversationKey, epoch: Int64) async throws {
        try await database.write { db in
            guard try Self.readEpoch(db) == epoch else { return }
            try db.execute(sql: "DELETE FROM cached_conversation WHERE chat_id = ? AND thread_id = ?",
                arguments: [key.chatID, key.threadID ?? ""])
        }
    }

    private static func upsertConversation(_ db: Database, _ item: CachedConversation) throws {
        guard try !chatAccessRevoked(db, item.key.chatID) else { return }
        try db.execute(sql: """
            INSERT INTO cached_conversation VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(chat_id, thread_id) DO UPDATE SET
                archived = excluded.archived, activity = excluded.activity, payload = excluded.payload
            """, arguments: [item.key.chatID, item.key.threadID ?? "", item.scope.archived,
                item.activity, try item.encoded(db)])
    }

    private static func decodeConversation(_ row: Row, isChat: Bool) throws -> CachedConversation {
        let data: Data = row["payload"]
        let decoder = JSONDecoder()
        return if isChat { .chat(try decoder.decode(ChatListItem.self, from: data)) }
            else { .thread(try decoder.decode(ThreadListItem.self, from: data)) }
    }

    private static let minID = MessageID(0)
    private static let maxID = MessageID(UInt64.max)

    private struct Segment {
        var lo: MessageID
        var hi: MessageID
        var reachesOldest: Bool
        var wasLatest: Bool

        init(_ lo: MessageID, _ hi: MessageID, reachesOldest: Bool = false, wasLatest: Bool = false) {
            self.lo = lo
            self.hi = hi
            self.reachesOldest = reachesOldest
            self.wasLatest = wasLatest
        }

        init(_ row: Row) throws {
            lo = try ChahuaLocalStore.cachedID(row["lo"])
            hi = try ChahuaLocalStore.cachedID(row["hi"])
            reachesOldest = row["reaches_oldest"]
            wasLatest = row["was_latest"]
        }
    }

    static func cacheBlob(_ id: MessageID) -> Data {
        withUnsafeBytes(of: id.rawValue.bigEndian) { Data($0) }
    }

    static func cachedID(_ data: Data) throws -> MessageID {
        guard data.count == 8 else { throw LocalStorageError.corruptRecord }
        return MessageID(data.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(as: UInt64.self)) })
    }

    static func hasTombstone(_ db: Database, _ chatID: String, _ id: MessageID) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM cached_tombstone WHERE chat_id = ? AND message_id = ?)
            """, arguments: [chatID, cacheBlob(id)]) == true
    }

    /// The full body is shared by all scopes, but membership is not.
    @discardableResult
    static func cacheMessage(
        _ db: Database, _ message: MessageResponse, in key: ConversationKey, addMembership: Bool = true
    ) throws -> Bool {
        guard message.chatId == key.chatID else { return false }
        guard try !chatAccessRevoked(db, key.chatID) else { return false }
        if message.replyRootId == nil, message.systemKind?.isMembership == true,
            try scopeContext(db, ConversationKey(chatID: key.chatID))?.hidesMembership != false
        { return false }
        let id = cacheBlob(message.id)
        var body = message
        if message.isDeleted {
            try redactCachedMessages(db, chatID: key.chatID, ids: [message.id])
        }
        if try hasTombstone(db, key.chatID, message.id) {
            guard key.threadID == message.id.description else { return false }
            body = body.redactedForDeletion()
        }
        if let reply = body.replyToMessage, try hasTombstone(db, key.chatID, reply.id) {
            body = body.redactingReplyPreview(messageIDs: [reply.id])
        } else if body.replyToMessage?.systemKind?.isMembership == true,
            try scopeContext(db, ConversationKey(chatID: key.chatID))?.hidesMembership != false
        {
            body = body.removingReplyPreview()
        }
        try db.execute(sql: """
            INSERT INTO cached_message VALUES (?, ?, ?, ?)
            ON CONFLICT(chat_id, message_id) DO UPDATE SET
                payload = excluded.payload, reply_to_id = excluded.reply_to_id
            """, arguments: [key.chatID, id, try JSONEncoder().encode(body), body.replyToMessage.map { cacheBlob($0.id) }])
        if addMembership {
            try db.execute(sql: "INSERT OR IGNORE INTO cached_member VALUES (?, ?, ?)",
                arguments: [key.chatID, key.threadID ?? "", id])
        }
        return true
    }

    @discardableResult
    static func cacheIsolatedMessage(_ db: Database, _ message: MessageResponse, in key: ConversationKey) throws -> Bool {
        guard try cacheMessage(db, message, in: key) else { return false }
        try mergeSegment(db, key, Segment(message.id, message.id))
        try db.execute(sql: "UPDATE cached_scope SET verified_empty = 0 WHERE chat_id = ? AND thread_id = ?",
            arguments: [key.chatID, key.threadID ?? ""])
        return true
    }

    private static func mergeSegment(_ db: Database, _ key: ConversationKey, _ incoming: Segment) throws {
        let scope: StatementArguments = [key.chatID, key.threadID ?? ""]
        let predicate = "chat_id = ? AND thread_id = ? AND lo <= ? AND hi >= ?"
        let arguments = scope + [cacheBlob(incoming.hi), cacheBlob(incoming.lo)]
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM cached_segment WHERE \(predicate)", arguments: arguments)
        var merged = incoming
        for row in rows {
            let previous = try Segment(row)
            merged.lo = min(merged.lo, previous.lo)
            merged.hi = max(merged.hi, previous.hi)
            merged.reachesOldest = merged.reachesOldest || previous.reachesOldest
            merged.wasLatest = merged.wasLatest || previous.wasLatest
        }
        if !rows.isEmpty {
            try db.execute(sql: "DELETE FROM cached_segment WHERE \(predicate)", arguments: arguments)
        }
        try db.execute(sql: "INSERT INTO cached_segment VALUES (?, ?, ?, ?, ?, ?)",
            arguments: scope + [cacheBlob(merged.lo), cacheBlob(merged.hi), merged.reachesOldest, merged.wasLatest])
    }

    fileprivate static func scopeContext(_ db: Database, _ key: ConversationKey) throws -> CachedScopeContext? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM cached_scope WHERE chat_id = ? AND thread_id = ?",
            arguments: [key.chatID, key.threadID ?? ""]) else { return nil }
        let decoder = JSONDecoder()
        return try CachedScopeContext(
            policy: (row["policy"] as Data?).map { try decoder.decode(MembershipMessagePolicy.self, from: $0) },
            settings: (row["settings"] as Data?).map { try decoder.decode(ChatSettings.self, from: $0) },
            canSend: row["last_write_decision"], sendPeerUID: row["write_peer_id"], verifiedEmpty: row["verified_empty"])
    }

    public func cachedScopeContext(_ key: ConversationKey) async throws -> CachedScopeContext? {
        try await database.read { try Self.scopeContext($0, key) }
    }

    public func cacheSendDecision(
        _ allowed: Bool, in key: ConversationKey, peerUID: Int32? = nil, epoch: Int64
    ) async throws {
        try await database.write { db in
            guard try Self.readEpoch(db) == epoch, try !Self.chatAccessRevoked(db, key.chatID) else { return }
            try db.execute(sql: """
                INSERT INTO cached_scope (chat_id, thread_id, last_write_decision, write_peer_id) VALUES (?, ?, ?, ?)
                ON CONFLICT(chat_id, thread_id) DO UPDATE SET
                    last_write_decision = excluded.last_write_decision, write_peer_id = excluded.write_peer_id
                """, arguments: [key.chatID, key.threadID ?? "", allowed, peerUID])
        }
    }

    public func invalidateSendDecisions(chatID: String, epoch: Int64) async throws {
        try await database.write { db in
            guard try Self.readEpoch(db) == epoch else { return }
            try db.execute(sql: "UPDATE cached_scope SET last_write_decision = NULL WHERE chat_id = ?", arguments: [chatID])
        }
    }

    public func invalidateSendDecisions(peerUID: Int32, epoch: Int64) async throws {
        try await database.write { db in
            guard try Self.readEpoch(db) == epoch else { return }
            try db.execute(sql: "UPDATE cached_scope SET last_write_decision = NULL WHERE write_peer_id = ?", arguments: [peerUID])
        }
    }

    public func completeCachedThread(_ key: ConversationKey, limit: Int) async throws -> [MessageResponse]? {
        guard limit > 0, let threadID = key.threadID, let rootID = MessageID(threadID) else { return nil }
        return try await database.read { db in
            let scope: StatementArguments = [key.chatID, threadID]
            guard let range = try Row.fetchOne(db, sql: """
                SELECT lo, hi FROM cached_segment
                WHERE chat_id = ? AND thread_id = ? AND reaches_oldest AND was_latest
                LIMIT 1
                """, arguments: scope) else { return nil }
            let lower: Data = range["lo"]
            let upper: Data = range["hi"]
            let hasGap = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM cached_member WHERE chat_id = ? AND thread_id = ?
                    AND (message_id < ? OR message_id > ?))
                """, arguments: scope + [lower, upper]) == true
            guard !hasGap else { return nil }
            let blobs = try Data.fetchAll(db, sql: """
                SELECT b.payload FROM cached_member m JOIN cached_message b USING(chat_id, message_id)
                WHERE m.chat_id = ? AND m.thread_id = ? ORDER BY m.message_id LIMIT ?
                """, arguments: scope + [min(limit, 100) + 1])
            let decoder = JSONDecoder()
            let messages = try blobs.map { try decoder.decode(MessageResponse.self, from: $0) }
            return messages.first?.id == rootID ? messages : nil
        }
    }

    /// Pass the accepted baseline and its journal, never a raw response from an obsolete request.
    public func cacheHistory(
        _ key: ConversationKey, query: ListMessagesQuery, response: ListMessagesResponse,
        replay: [CachedMessageChange] = [], epoch: Int64
    ) async throws {
        try await database.write { db in
            guard try Self.readEpoch(db) == epoch else { return }
            try Self.applyPage(db, key, query, response)
            for change in replay { try Self.applyChange(db, change) }
        }
    }

    private static func applyPage(
        _ db: Database, _ key: ConversationKey, _ query: ListMessagesQuery, _ response: ListMessagesResponse
    ) throws {
        let scope: StatementArguments = [key.chatID, key.threadID ?? ""]
        let ids = response.messages.lazy.filter { $0.chatId == key.chatID }.map(\.id)
        let latest = query.around == nil && query.before == nil && query.after == nil
        let first = ids.min(), last = ids.max()
        let encoder = JSONEncoder()
        try db.execute(sql: """
            INSERT INTO cached_scope (chat_id, thread_id, policy, settings, verified_empty) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(chat_id, thread_id) DO UPDATE SET policy = coalesce(excluded.policy, policy),
                settings = coalesce(excluded.settings, settings),
                verified_empty = CASE WHEN ? THEN excluded.verified_empty ELSE verified_empty END
            """, arguments: scope + [try response.membershipMessagePolicy.map { try encoder.encode($0) },
                try response.chatSettings.map { try encoder.encode($0) }, latest && first == nil, latest || first != nil])

        var bounds: Segment?
        if latest && first == nil {
            try db.execute(sql: "DELETE FROM cached_segment WHERE chat_id = ? AND thread_id = ?", arguments: scope)
            bounds = Segment(minID, maxID)
        } else if let before = query.before, before > minID, first != nil || response.olderCursor == nil {
            let exhausted = response.olderCursor == nil
            bounds = Segment(exhausted ? minID : first ?? before, MessageID(before.rawValue - 1), reachesOldest: exhausted)
        } else if let after = query.after, after < maxID, last != nil || response.newerCursor == nil {
            let exhausted = response.newerCursor == nil
            bounds = Segment(MessageID(after.rawValue + 1), exhausted ? maxID : last ?? after, wasLatest: exhausted)
        } else if let first, let last {
            let oldest = response.olderCursor == nil
            let tail = latest || response.newerCursor == nil
            bounds = Segment(oldest ? minID : first, tail ? maxID : last, reachesOldest: oldest, wasLatest: tail)
        }
        if let bounds, bounds.lo <= bounds.hi {
            // Remove only omitted membership. Existing members present in the page
            // stay in place, including a thread root also referenced by its parent.
            let returned = try JSONEncoder().encode(ids.map { cacheBlob($0).map { String(format: "%02X", $0) }.joined() })
            try db.execute(sql: """
                DELETE FROM cached_member WHERE chat_id = ? AND thread_id = ? AND message_id BETWEEN ? AND ?
                AND hex(message_id) NOT IN (SELECT value FROM json_each(?))
                """, arguments: scope + [cacheBlob(bounds.lo), cacheBlob(bounds.hi), String(decoding: returned, as: UTF8.self)])
            if let first, let last {
                // The coverage used to remove omissions can have an open end.
                // Store real edges so a later isolated event does not join it.
                try mergeSegment(db, key, Segment(
                    query.after ?? first, query.before ?? last,
                    reachesOldest: bounds.reachesOldest, wasLatest: bounds.wasLatest))
            } else if let cursor = query.before ?? query.after, response.messages.isEmpty {
                try mergeSegment(db, key, Segment(
                    cursor, cursor, reachesOldest: bounds.reachesOldest, wasLatest: bounds.wasLatest))
            }
        }
        for message in response.messages { try cacheMessage(db, message, in: key) }
    }

    public func cachedHistory(
        _ key: ConversationKey, position: CachedHistoryPosition = .latest, limit requested: Int = 50
    ) async throws -> CachedHistoryPage {
        try await database.read { db in
            let scope: StatementArguments = [key.chatID, key.threadID ?? ""]
            let context = try Self.scopeContext(db, key)
            let query = """
                SELECT s.* FROM cached_segment s WHERE s.chat_id = ? AND s.thread_id = ?
                    AND EXISTS (SELECT 1 FROM cached_member m WHERE m.chat_id = s.chat_id
                        AND m.thread_id = s.thread_id AND m.message_id BETWEEN s.lo AND s.hi)
                """
            func segment(_ clause: String, _ arguments: StatementArguments = []) throws -> Segment? {
                try Row.fetchOne(db, sql: query + clause + " LIMIT 1", arguments: scope + arguments).map(Segment.init)
            }
            let selected: Segment?
            var target: MessageID?
            var direction: CachedHistoryPosition = position
            switch position {
            case .latest:
                selected = try segment(" ORDER BY lo DESC")
            case .before(let id), .after(let id), .around(let id):
                let blob = Self.cacheBlob(id)
                let containing = try segment(" AND lo <= ? AND hi >= ? ORDER BY lo DESC", [blob, blob])
                if case .around = position {
                    target = id
                    selected = try containing ?? segment(" ORDER BY lo DESC")
                    if containing == nil { direction = .latest }
                } else { selected = containing }
            case .previousSection(let id):
                selected = try segment(" AND hi < ? ORDER BY lo DESC", [Self.cacheBlob(id)])
                direction = .latest
            case .nextSection(let id):
                selected = try segment(" AND lo > ? ORDER BY lo ASC", [Self.cacheBlob(id)])
            }
            guard let selected else {
                return CachedHistoryPage(messages: [], context: context, hasOlder: false, hasNewer: false,
                    hasOlderSection: false, hasNewerSection: false, targetMissing: target != nil)
            }
            let arguments = scope + [Self.cacheBlob(selected.lo), Self.cacheBlob(selected.hi)]
            let members = """
                FROM cached_member m JOIN cached_message b USING(chat_id, message_id)
                WHERE m.chat_id = ? AND m.thread_id = ? AND m.message_id BETWEEN ? AND ?
                """
            let limit = max(1, min(100, requested))
            func rows(_ clause: String, _ bounds: StatementArguments, _ count: Int) throws -> [MessageResponse] {
                let data = try Data.fetchAll(db, sql: "SELECT b.payload " + members + clause + " LIMIT ?",
                    arguments: arguments + bounds + [count])
                let decoder = JSONDecoder()
                return try data.map { try decoder.decode(MessageResponse.self, from: $0) }
            }
            let messages: [MessageResponse]
            switch direction {
            case .before(let id):
                messages = try rows(" AND m.message_id < ? ORDER BY m.message_id DESC", [Self.cacheBlob(id)], limit).reversed()
            case .after(let id):
                messages = try rows(" AND m.message_id > ? ORDER BY m.message_id", [Self.cacheBlob(id)], limit)
            case .nextSection:
                messages = try rows(" ORDER BY m.message_id", [], limit)
            case .around(let id):
                let newer = try rows(" AND m.message_id >= ? ORDER BY m.message_id", [Self.cacheBlob(id)], (limit + 1) / 2)
                let older = try rows(" AND m.message_id < ? ORDER BY m.message_id DESC", [Self.cacheBlob(id)], limit - newer.count)
                messages = Array(older.reversed()) + newer
            default:
                messages = try rows(" ORDER BY m.message_id DESC", [], limit).reversed()
            }
            func hasMember(comparedTo id: MessageID?, sql: String) throws -> Bool {
                guard let id else { return false }
                return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 " + members + sql + ")",
                    arguments: arguments + [Self.cacheBlob(id)]) == true
            }
            return try CachedHistoryPage(messages: messages, context: context,
                hasOlder: hasMember(comparedTo: messages.first?.id, sql: " AND m.message_id < ?"),
                hasNewer: hasMember(comparedTo: messages.last?.id, sql: " AND m.message_id > ?"),
                hasOlderSection: segment(" AND hi < ?", [Self.cacheBlob(selected.lo)]) != nil,
                hasNewerSection: segment(" AND lo > ?", [Self.cacheBlob(selected.hi)]) != nil,
                targetMissing: target.map { id in !messages.contains { $0.id == id } } ?? false)
        }
    }

    public static func isDiskFull(_ error: any Error) -> Bool {
        (error as? DatabaseError)?.resultCode == .SQLITE_FULL
    }

    public func invalidateCachedPolicy(
        chatID: String?, policy: MembershipMessagePolicy?, settings: ChatSettings?, epoch: Int64
    ) async throws {
        try await database.write { db in
            guard try Self.readEpoch(db) == epoch else { return }
            let encoder = JSONEncoder()
            if let chatID {
                try db.execute(sql: """
                    INSERT INTO cached_scope (chat_id, thread_id, policy) VALUES (?, '', ?)
                    ON CONFLICT(chat_id, thread_id) DO UPDATE SET policy = excluded.policy
                    """, arguments: [chatID, try encoder.encode(
                        policy ?? .init(visibility: .nobody, canView: false))])
            }
            if let settings {
                try db.execute(sql: "UPDATE cached_scope SET settings = ?", arguments: [try encoder.encode(settings)])
            }
            guard policy?.canView != true && chatID != nil || settings?.showMembershipMessages == false else { return }
            // Visibility changes do not prove deletion. Keep the canonical
            // identities separate from the list and segment membership.
            let filter = chatID == nil
                ? " AND chat_id IN (SELECT chat_id FROM cached_scope WHERE thread_id = '' AND policy IS NOT NULL)"
                : " AND chat_id = ?"
            let args: StatementArguments = chatID.map { [$0] } ?? []
            try db.execute(sql: "DELETE FROM cached_segment WHERE thread_id = ''" + filter, arguments: args)
            try db.execute(sql: "UPDATE cached_scope SET verified_empty = 0 WHERE thread_id = ''" + filter, arguments: args)
            let decoder = JSONDecoder()
            let rows = try Row.fetchAll(db, sql: """
                SELECT chat_id, message_id, payload FROM cached_message
                WHERE (json_extract(CAST(payload AS TEXT), '$.systemKind') IS NOT NULL
                    OR json_extract(CAST(payload AS TEXT), '$.replyToMessage.systemKind') IS NOT NULL)
                """ + filter, arguments: args)
            for row in rows {
                let id: Data = row["message_id"]
                let chat: String = row["chat_id"]
                let original = try decoder.decode(MessageResponse.self, from: row["payload"])
                if original.replyRootId == nil, original.systemKind?.isMembership == true {
                    try db.execute(sql: "DELETE FROM cached_message WHERE chat_id = ? AND message_id = ?", arguments: [chat, id])
                } else if original.replyToMessage?.systemKind?.isMembership == true {
                    try db.execute(sql: "UPDATE cached_message SET payload = ?, reply_to_id = NULL WHERE chat_id = ? AND message_id = ?",
                        arguments: [try encoder.encode(original.removingReplyPreview()), chat, id])
                }
            }
            let listRows = try Row.fetchAll(db, sql: """
                SELECT * FROM cached_conversation WHERE (
                    json_extract(CAST(payload AS TEXT), '$.lastMessage.systemKind') IS NOT NULL
                    OR json_extract(CAST(payload AS TEXT), '$.lastReply.systemKind') IS NOT NULL
                    OR json_extract(CAST(payload AS TEXT), '$.threadRootMessage.systemKind') IS NOT NULL
                )
                """ + filter, arguments: args)
            for row in listRows {
                let thread: String = row["thread_id"]
                try Self.upsertConversation(db, Self.decodeConversation(row, isChat: thread.isEmpty))
            }
            // Saved messages remain usable after a visibility policy change,
            // but the old proof that they cover continuous history is gone.
            try db.execute(sql: """
                INSERT OR IGNORE INTO cached_segment
                SELECT chat_id, thread_id, message_id, message_id, 0, 0 FROM cached_member WHERE thread_id = ''
                """ + filter, arguments: args)
        }
    }

    private static func updateBody(
        _ db: Database, chatID: String, id: MessageID, _ mutate: (MessageResponse) -> MessageResponse
    ) throws {
        let blob = cacheBlob(id)
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM cached_message WHERE chat_id = ? AND message_id = ?",
            arguments: [chatID, blob]) else { return }
        let value = mutate(try JSONDecoder().decode(MessageResponse.self, from: data))
        try db.execute(sql: "UPDATE cached_message SET payload = ? WHERE chat_id = ? AND message_id = ?",
            arguments: [try JSONEncoder().encode(value), chatID, blob])
    }

    public func cacheChange(_ change: CachedMessageChange, epoch: Int64) async throws {
        try await database.write { db in
            guard try Self.readEpoch(db) == epoch else { return }
            try Self.applyChange(db, change)
        }
    }

    private static func applyChange(_ db: Database, _ change: CachedMessageChange) throws {
        switch change {
        case .create(let message, let key, let adjoining):
            guard try cacheIsolatedMessage(db, message, in: key) else { return }
            if let adjoining {
                try mergeSegment(db, key, Segment(min(adjoining, message.id), max(adjoining, message.id)))
            }
        case .update(let message, let key):
            let existing = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM cached_message WHERE chat_id = ? AND message_id = ?)
                """, arguments: [key.chatID, cacheBlob(message.id)]) == true
            if existing { try cacheMessage(db, message, in: key, addMembership: false) }
        case .delete(let chatID, let ids):
            try redactCachedMessages(db, chatID: chatID, ids: ids)
        case .reactions(let payload):
            try updateBody(db, chatID: payload.chatId, id: payload.messageId) { $0.replacingReactions(payload.reactions) }
        case .threadCount(let chatID, let id, let count):
            try updateBody(db, chatID: chatID, id: id) { $0.replacingThreadReplyCount(count) }
        }
    }

    static func redactCachedMessages(_ db: Database, chatID: String, ids: Set<MessageID>) throws {
        guard !ids.isEmpty else { return }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        for id in ids {
            let blob = cacheBlob(id)
            try db.execute(sql: "INSERT OR IGNORE INTO cached_tombstone VALUES (?, ?)", arguments: [chatID, blob])
            try db.execute(sql: "DELETE FROM pending_read WHERE chat_id = ? AND target_id = ?", arguments: [chatID, blob])
            let rows = try Row.fetchAll(db, sql: """
                SELECT message_id, payload FROM cached_message WHERE chat_id = ? AND message_id = ?
                UNION
                SELECT message_id, payload FROM cached_message WHERE chat_id = ? AND reply_to_id = ?
                """, arguments: [chatID, blob, chatID, blob])
            for row in rows {
                let bytes: Data = row["message_id"]
                var message = try decoder.decode(MessageResponse.self, from: row["payload"])
                if message.id == id { message = message.redactedForDeletion() }
                message = message.redactingReplyPreview(messageIDs: [id])
                try db.execute(sql: "UPDATE cached_message SET payload = ? WHERE chat_id = ? AND message_id = ?",
                    arguments: [try encoder.encode(message), chatID, bytes])
            }
            // A deleted thread root remains addressable by its redacted identity.
            try db.execute(sql: "DELETE FROM cached_member WHERE chat_id = ? AND message_id = ? AND thread_id != ?",
                arguments: [chatID, blob, id.description])
        }
        try redactDurableReplyPreviews(db, chatID: chatID, ids: ids)
        for row in try Row.fetchAll(db, sql: "SELECT * FROM cached_conversation WHERE chat_id = ?", arguments: [chatID]) {
            let thread: String = row["thread_id"]
            let item = try decodeConversation(row, isChat: thread.isEmpty)
            try upsertConversation(db, item)
        }
    }

    public func purgeCachedChat(_ chatID: String, epoch: Int64) async throws {
        try await database.write { db in
            guard try Self.readEpoch(db) == epoch else { return }
            try db.execute(sql: """
                DELETE FROM cached_member WHERE chat_id = ?;
                DELETE FROM cached_message WHERE chat_id = ?;
                DELETE FROM cached_segment WHERE chat_id = ?;
                DELETE FROM cached_scope WHERE chat_id = ?;
                DELETE FROM cached_conversation WHERE chat_id = ?;
                DELETE FROM pending_read WHERE chat_id = ?;
                DELETE FROM cached_tombstone WHERE chat_id = ?;
                """, arguments: [chatID, chatID, chatID, chatID, chatID, chatID, chatID])
            try db.execute(sql: "INSERT INTO cached_scope (chat_id, thread_id, access_revoked) VALUES (?, '', 1)",
                arguments: [chatID])
        }
    }

    public func confirmChatAccess(_ chatID: String, epoch: Int64) async throws {
        try await database.write { db in
            guard try Self.readEpoch(db) == epoch else { return }
            try db.execute(sql: "UPDATE cached_scope SET access_revoked = 0 WHERE chat_id = ? AND thread_id = '' AND access_revoked",
                arguments: [chatID])
        }
    }

    private static func chatAccessRevoked(_ db: Database, _ chatID: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT access_revoked FROM cached_scope WHERE chat_id = ? AND thread_id = ''",
            arguments: [chatID]) == true
    }

    @discardableResult
    public func recordPendingRead(
        _ key: ConversationKey, base: MessageID?, target: MessageID
    ) async throws -> PendingReadRecording {
        try await database.write { db in
            guard base.map({ target > $0 }) ?? true,
                try !Self.chatAccessRevoked(db, key.chatID),
                try !Self.hasTombstone(db, key.chatID, target)
            else { return .unchanged }
            let threadID = key.threadID ?? ""
            let baseID = base.map(Self.cacheBlob)
            let targetID = Self.cacheBlob(target)
            try db.execute(sql: """
                INSERT INTO pending_read VALUES (?, ?, ?, ?)
                ON CONFLICT(chat_id, thread_id) DO NOTHING
                """, arguments: [key.chatID, threadID, baseID, targetID])
            if db.changesCount != 0 { return .inserted }
            try db.execute(sql: """
                UPDATE pending_read SET base_id = ?, target_id = ?
                WHERE chat_id = ? AND thread_id = ? AND target_id < ?
                """, arguments: [baseID, targetID, key.chatID, threadID, targetID])
            return db.changesCount == 0 ? .unchanged : .advanced
        }
    }

    public func pendingReads() async throws -> [PendingRead] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pending_read").map(Self.decodePendingRead)
        }
    }

    public func pendingRead(_ key: ConversationKey) async throws -> PendingRead? {
        try await database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM pending_read WHERE chat_id = ? AND thread_id = ?",
                arguments: [key.chatID, key.threadID ?? ""]).map(Self.decodePendingRead)
        }
    }

    private static func decodePendingRead(_ row: Row) throws -> PendingRead {
        let thread: String = row["thread_id"]
        return try PendingRead(key: ConversationKey(chatID: row["chat_id"], threadID: thread.isEmpty ? nil : thread),
            base: (row["base_id"] as Data?).map(Self.cachedID), target: Self.cachedID(row["target_id"]))
    }

    public func clearPendingReadTarget(_ key: ConversationKey, target: MessageID) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM pending_read WHERE chat_id = ? AND thread_id = ? AND target_id = ?",
                arguments: [key.chatID, key.threadID ?? "", Self.cacheBlob(target)])
        }
    }

    public func clearPendingReadTargets(chatID: String, ids: Set<MessageID>) async throws {
        try await database.write { db in
            for id in ids {
                try db.execute(sql: "DELETE FROM pending_read WHERE chat_id = ? AND target_id = ?",
                    arguments: [chatID, Self.cacheBlob(id)])
            }
        }
    }

    public func clearPendingReads(chatID: String) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM pending_read WHERE chat_id = ?", arguments: [chatID])
        }
    }

    public func clearPendingRead(_ key: ConversationKey, through target: MessageID? = nil) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM pending_read WHERE chat_id = ? AND thread_id = ? AND (? IS NULL OR target_id <= ?)",
                arguments: [key.chatID, key.threadID ?? "", target.map(Self.cacheBlob), target.map(Self.cacheBlob)])
        }
    }
}

public enum CachedMessageChange: Sendable {
    case create(MessageResponse, ConversationKey, adjoining: MessageID? = nil)
    case update(MessageResponse, ConversationKey)
    case delete(chatID: String, ids: Set<MessageID>)
    case reactions(ReactionUpdatePayload)
    case threadCount(chatID: String, id: MessageID, count: Int64)
}
