import Foundation
import GRDB

/// The durable projection and the replacement baseline, if one is in progress.
public struct ListSyncState: Equatable, Sendable {
    public let installedToken: String?
    public let stagingToken: String?
    public let installedChatSettings: ChatSettings?
    public let stagedChatSettings: ChatSettings?
    public let installedNotificationSettings: NotificationSettingsResponse?
    public let stagedNotificationSettings: NotificationSettingsResponse?

    public init(
        installedToken: String? = nil, stagingToken: String? = nil,
        installedChatSettings: ChatSettings? = nil, stagedChatSettings: ChatSettings? = nil,
        installedNotificationSettings: NotificationSettingsResponse? = nil,
        stagedNotificationSettings: NotificationSettingsResponse? = nil
    ) {
        self.installedToken = installedToken
        self.stagingToken = stagingToken
        self.installedChatSettings = installedChatSettings
        self.stagedChatSettings = stagedChatSettings
        self.installedNotificationSettings = installedNotificationSettings
        self.stagedNotificationSettings = stagedNotificationSettings
    }
}

public enum ListSyncRequest: Sendable {
    case forcedStart, installed, staged
}

extension ChahuaLocalStore {
    public func listSyncState(epoch: Int64) async throws -> ListSyncState {
        try await database.read { db in
            guard try Self.readEpoch(db) == epoch else { throw CancellationError() }
            return try Self.readListSyncState(db)
        }
    }

    /// A page and its cursor are always committed together. Even an explicit nil-cursor
    /// request must still describe the complete state it intends to replace.
    public func commitListDifference(
        _ page: ConversationDifference, expected: ListSyncState, request: ListSyncRequest,
        epoch: Int64, authorizedRejoins: Set<String> = []
    ) async throws -> SyncCommit {
        try await database.write { db in
            guard try Self.readEpoch(db) == epoch else { return .stale }
            guard try Self.readListSyncState(db) == expected else { return .mismatch }
            let from: String?
            switch request {
            case .forcedStart:
                from = nil
            case .installed:
                guard let token = expected.installedToken, expected.stagingToken == nil else {
                    return .mismatch
                }
                from = token
            case .staged:
                guard let token = expected.stagingToken else { return .mismatch }
                from = token
            }
            try Self.validateListDifference(page, from: from)
            // Only a request captured after revocation can authorize a rejoin.
            // Earlier staged rows never clear the durable access fence.
            for chat in page.chats where authorizedRejoins.contains(chat.id) {
                try db.execute(
                    sql: "UPDATE cached_scope SET access_revoked = 0 WHERE chat_id = ? AND thread_id = ''",
                    arguments: [chat.id])
            }
            let encoder = JSONEncoder()
            try db.execute(sql: "INSERT OR IGNORE INTO list_sync_state (singleton) VALUES (1)")

            if page.reset != nil {
                // Never remove the installed projection while starting over.
                try db.execute(sql: "DELETE FROM list_sync_stage")
                try Self.invalidateCachedPolicy(
                    db, chatID: nil, policy: nil, settings: page.chatSettings)
                try db.execute(
                    sql: """
                        UPDATE list_sync_state SET staging_token = ?, staged_chat_settings = ?,
                            staged_notification_settings = ? WHERE singleton = 1
                        """,
                    arguments: [
                        page.cursor, try encoder.encode(page.chatSettings),
                        try encoder.encode(page.notificationSettings),
                    ])
                return .committed
            }

            try Self.invalidateCachedPolicy(
                db, chatID: nil, policy: nil, settings: page.chatSettings)
            for chat in page.chats where try !Self.chatAccessRevoked(db, chat.id) {
                try Self.invalidateCachedPolicy(
                    db, chatID: chat.id, policy: chat.membershipMessagePolicy, settings: page.chatSettings)
            }
            var sidecars: [ConversationKey: MessageResponse] = [:]
            for message in page.latestMessages {
                sidecars[ConversationKey(chatID: message.chatId)] = message
            }
            if case .staged = request {
                for chat in page.chats {
                    try Self.stageListRow(
                        db, .chat(chat), sidecar: sidecars[ConversationKey(chatID: chat.id)])
                }
                for thread in page.threads { try Self.stageListRow(db, .thread(thread)) }
                try Self.removeListRows(db, page.removed, staged: true)
                if page.complete {
                    // Re-encode against durable live policies and tombstones, not the
                    // policy snapshot from when each enumeration page was staged.
                    try db.execute(sql: "DELETE FROM cached_conversation")
                    for row in try Row.fetchAll(db, sql: "SELECT * FROM list_sync_stage") {
                        let thread: String = row["thread_id"]
                        let item = try Self.decodeConversation(row, isChat: thread.isEmpty)
                        try Self.upsertConversation(db, item)
                        if case .chat(let chat) = item, let payload: Data = row["latest_message"] {
                            let message = try JSONDecoder().decode(MessageResponse.self, from: payload)
                            try Self.seedListLatestMessage(db, message, for: chat)
                        }
                    }
                    for scope in [CachedListScope.activeChats, .archivedChats, .activeThreads, .archivedThreads] {
                        try db.execute(
                            sql: """
                                INSERT INTO cached_list (scope, complete, fetched_at) VALUES (?, 1, ?)
                                ON CONFLICT(scope) DO UPDATE SET complete = 1, fetched_at = excluded.fetched_at
                                """, arguments: [scope.rawValue, Date().timeIntervalSince1970])
                    }
                    try Self.installListSyncState(db, page)
                    try db.execute(sql: "DELETE FROM list_sync_stage")
                } else {
                    try db.execute(
                        sql: """
                            UPDATE list_sync_state SET staging_token = ?, staged_chat_settings = ?,
                                staged_notification_settings = ? WHERE singleton = 1
                            """,
                        arguments: [
                            page.cursor, try encoder.encode(page.chatSettings),
                            try encoder.encode(page.notificationSettings),
                        ])
                }
            } else {
                for chat in page.chats {
                    try Self.upsertConversation(db, .chat(chat))
                    if let message = sidecars[ConversationKey(chatID: chat.id)] {
                        try Self.seedListLatestMessage(db, message, for: chat)
                    }
                }
                for thread in page.threads { try Self.upsertConversation(db, .thread(thread)) }
                try Self.removeListRows(db, page.removed, staged: false)
                try Self.installListSyncState(db, page)
            }
            return .committed
        }
    }

    /// Live notification defaults participate in the same full-state response fence.
    public func cacheListNotificationSettings(
        _ settings: NotificationSettingsResponse, epoch: Int64
    ) async throws {
        try await database.write { db in
            guard try Self.readEpoch(db) == epoch else { return }
            let payload = try JSONEncoder().encode(settings)
            try db.execute(
                sql: """
                    INSERT INTO list_sync_state (singleton, installed_notification_settings) VALUES (1, ?)
                    ON CONFLICT(singleton) DO UPDATE SET
                        installed_notification_settings = excluded.installed_notification_settings,
                        staged_notification_settings = CASE WHEN staging_token IS NOT NULL
                            THEN excluded.installed_notification_settings ELSE staged_notification_settings END
                    """, arguments: [payload])
        }
    }

    public func cacheListReceipt(
        _ value: MessageID?, for key: ConversationKey, epoch: Int64
    ) async throws {
        try await database.write { db in
            guard try Self.readEpoch(db) == epoch else { return }
            for table in ["cached_conversation", "list_sync_stage"] {
                try db.execute(
                    sql: """
                        UPDATE \(table) SET payload =
                            CAST(json_set(CAST(payload AS TEXT), '$.peerLastReadMessageId', ?) AS BLOB)
                        WHERE chat_id = ? AND thread_id = ?
                        """, arguments: [value?.description, key.chatID, key.threadID ?? ""])
            }
        }
    }

    /// A receipt-sharing revocation must survive restart and baseline promotion.
    public func clearCachedListReceipts(epoch: Int64) async throws {
        try await database.write { db in
            guard try Self.readEpoch(db) == epoch else { return }
            for table in ["cached_conversation", "list_sync_stage"] {
                try db.execute(
                    sql: """
                        UPDATE \(table) SET payload =
                            CAST(json_remove(CAST(payload AS TEXT), '$.peerLastReadMessageId') AS BLOB)
                        """)
            }
        }
    }

    /// Legacy scans cannot advance a projection described by a native token.
    public func invalidateListSync(epoch: Int64) async throws {
        try await database.write { db in
            guard try Self.readEpoch(db) == epoch else { return }
            try db.execute(sql: """
                DELETE FROM list_sync_stage;
                UPDATE list_sync_state SET installed_token = NULL, staging_token = NULL,
                    staged_chat_settings = NULL, staged_notification_settings = NULL WHERE singleton = 1;
                """)
        }
    }

    private static func readListSyncState(_ db: Database) throws -> ListSyncState {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM list_sync_state WHERE singleton = 1") else {
            return ListSyncState()
        }
        let decoder = JSONDecoder()
        return try ListSyncState(
            installedToken: row["installed_token"], stagingToken: row["staging_token"],
            installedChatSettings: (row["installed_chat_settings"] as Data?).map {
                try decoder.decode(ChatSettings.self, from: $0)
            },
            stagedChatSettings: (row["staged_chat_settings"] as Data?).map {
                try decoder.decode(ChatSettings.self, from: $0)
            },
            installedNotificationSettings: (row["installed_notification_settings"] as Data?).map {
                try decoder.decode(NotificationSettingsResponse.self, from: $0)
            },
            stagedNotificationSettings: (row["staged_notification_settings"] as Data?).map {
                try decoder.decode(NotificationSettingsResponse.self, from: $0)
            })
    }

    private static func installListSyncState(_ db: Database, _ page: ConversationDifference) throws {
        let encoder = JSONEncoder()
        try db.execute(
            sql: """
                UPDATE list_sync_state SET installed_token = ?, installed_chat_settings = ?,
                    installed_notification_settings = ?, staging_token = NULL,
                    staged_chat_settings = NULL, staged_notification_settings = NULL WHERE singleton = 1
                """,
            arguments: [
                page.cursor, try encoder.encode(page.chatSettings),
                try encoder.encode(page.notificationSettings),
            ])
    }

    private static func stageListRow(
        _ db: Database, _ item: CachedConversation, sidecar: MessageResponse? = nil
    ) throws {
        guard try !chatAccessRevoked(db, item.key.chatID) else { return }
        let payload = try sidecar.flatMap { try sanitizedListSidecar(db, $0) }
            .map { try JSONEncoder().encode($0) }
        try db.execute(
            sql: """
                INSERT INTO list_sync_stage VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(chat_id, thread_id) DO UPDATE SET archived = excluded.archived,
                    activity = excluded.activity, payload = excluded.payload,
                    latest_message = excluded.latest_message
                """,
            arguments: [
                item.key.chatID, item.key.threadID ?? "", item.scope.archived,
                item.activity, try item.encoded(db), payload,
            ])
    }

    private static func removeListRows(
        _ db: Database, _ removed: [ConversationRef], staged: Bool
    ) throws {
        let table = staged ? "list_sync_stage" : "cached_conversation"
        for reference in removed {
            if let thread = reference.threadId {
                try db.execute(
                    sql: "DELETE FROM \(table) WHERE chat_id = ? AND thread_id = ?",
                    arguments: [reference.chatId, thread.description])
            } else {
                try db.execute(sql: "DELETE FROM \(table) WHERE chat_id = ?", arguments: [reference.chatId])
            }
        }
    }

    private static func validateListDifference(_ page: ConversationDifference, from: String?) throws {
        guard !page.cursor.isEmpty else { throw LocalStorageError.corruptRecord }
        if page.reset != nil {
            guard !page.complete, page.chats.isEmpty, page.threads.isEmpty,
                page.latestMessages.isEmpty, page.removed.isEmpty
            else { throw LocalStorageError.corruptRecord }
            return
        }
        guard let from, page.complete || page.cursor != from else {
            throw LocalStorageError.corruptRecord
        }
        func validChatID(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
        }
        var keys = Set<ConversationKey>()
        var chats: [String: ChatListItem] = [:]
        for chat in page.chats {
            guard validChatID(chat.id), chat.unreadCount >= 0,
                chat.unreadMentions >= 0, chat.unreadReactions >= 0,
                keys.insert(ConversationKey(chatID: chat.id)).inserted
            else { throw LocalStorageError.corruptRecord }
            chats[chat.id] = chat
        }
        for thread in page.threads {
            guard validChatID(thread.chatId), thread.unreadCount >= 0,
                thread.unreadMentions >= 0, thread.unreadReactions >= 0, thread.replyCount >= 0,
                keys.insert(ConversationKey(
                    chatID: thread.chatId, threadID: thread.threadRootMessage.id.description)).inserted
            else { throw LocalStorageError.corruptRecord }
        }
        var sidecars = Set<ConversationKey>()
        for message in page.latestMessages {
            let key = ConversationKey(chatID: message.chatId)
            guard message.replyRootId == nil, let chat = chats[message.chatId],
                chat.lastMessage?.id == message.id, sidecars.insert(key).inserted
            else { throw LocalStorageError.corruptRecord }
        }
        var removals = Set<ConversationRef>()
        for reference in page.removed {
            let key = ConversationKey(chatID: reference.chatId, threadID: reference.threadId?.description)
            guard validChatID(reference.chatId), removals.insert(reference).inserted,
                !keys.contains(key),
                reference.threadId != nil || !keys.contains(where: { $0.chatID == reference.chatId })
            else { throw LocalStorageError.corruptRecord }
        }
    }
}
