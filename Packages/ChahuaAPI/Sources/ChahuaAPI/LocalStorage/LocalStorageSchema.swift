import GRDB

func migrateLocalStorage(_ queue: DatabaseQueue) throws {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1_drafts_outbox") { db in
        try db.execute(sql: """
            CREATE TABLE local_conversation (
                chat_id TEXT PRIMARY KEY NOT NULL,
                revision INTEGER NOT NULL DEFAULT 0,
                next_enqueue_sequence INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE draft (
                chat_id TEXT PRIMARY KEY NOT NULL REFERENCES local_conversation(chat_id),
                text TEXT NOT NULL,
                edit_revision INTEGER NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE outgoing_message (
                client_generated_id TEXT PRIMARY KEY NOT NULL,
                chat_id TEXT NOT NULL REFERENCES local_conversation(chat_id),
                sender_id INTEGER NOT NULL,
                text TEXT NOT NULL,
                enqueued_at REAL NOT NULL,
                enqueue_sequence INTEGER NOT NULL,
                dispatch_order INTEGER NOT NULL,
                state TEXT NOT NULL CHECK(state IN ('queued','sending','failed')),
                UNIQUE(chat_id, enqueue_sequence)
            );
            CREATE INDEX outgoing_dispatch ON outgoing_message(chat_id, dispatch_order);
            """)
    }
    migrator.registerMigration("v2_thread_conversations") { db in
        // The empty SQL thread identifier represents the parent conversation only.
        // Rebuild rather than mutate primary keys so existing drafts and outbox order survive.
        try db.execute(sql: """
            CREATE TABLE local_conversation_v2 (
                chat_id TEXT NOT NULL,
                thread_id TEXT NOT NULL DEFAULT '',
                revision INTEGER NOT NULL DEFAULT 0,
                next_enqueue_sequence INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(chat_id, thread_id)
            );
            CREATE TABLE draft_v2 (
                chat_id TEXT NOT NULL,
                thread_id TEXT NOT NULL DEFAULT '',
                text TEXT NOT NULL,
                edit_revision INTEGER NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY(chat_id, thread_id),
                FOREIGN KEY(chat_id, thread_id) REFERENCES local_conversation(chat_id, thread_id)
            );
            CREATE TABLE outgoing_message_v2 (
                client_generated_id TEXT PRIMARY KEY NOT NULL,
                chat_id TEXT NOT NULL,
                thread_id TEXT NOT NULL DEFAULT '',
                sender_id INTEGER NOT NULL,
                text TEXT NOT NULL,
                enqueued_at REAL NOT NULL,
                enqueue_sequence INTEGER NOT NULL,
                dispatch_order INTEGER NOT NULL,
                state TEXT NOT NULL CHECK(state IN ('queued','sending','failed')),
                UNIQUE(chat_id, thread_id, enqueue_sequence),
                FOREIGN KEY(chat_id, thread_id) REFERENCES local_conversation(chat_id, thread_id)
            );
            INSERT INTO local_conversation_v2
                SELECT chat_id, '', revision, next_enqueue_sequence FROM local_conversation;
            INSERT INTO draft_v2
                SELECT chat_id, '', text, edit_revision, updated_at FROM draft;
            INSERT INTO outgoing_message_v2
                SELECT client_generated_id, chat_id, '', sender_id, text, enqueued_at,
                       enqueue_sequence, dispatch_order, state FROM outgoing_message;
            DROP TABLE draft;
            DROP TABLE outgoing_message;
            DROP TABLE local_conversation;
            ALTER TABLE local_conversation_v2 RENAME TO local_conversation;
            ALTER TABLE draft_v2 RENAME TO draft;
            ALTER TABLE outgoing_message_v2 RENAME TO outgoing_message;
            CREATE INDEX outgoing_dispatch ON outgoing_message(chat_id, thread_id, dispatch_order);
            """)
    }
    migrator.registerMigration("v3_reply_context") { db in
        try db.execute(sql: """
            ALTER TABLE draft ADD COLUMN reply_to_message BLOB;
            ALTER TABLE outgoing_message ADD COLUMN reply_to_message BLOB;
            """)
    }
    migrator.registerMigration("v4_blocked_image_outbox") { db in
        try db.execute(sql: """
            ALTER TABLE outgoing_message ADD COLUMN is_blocked INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE outgoing_message ADD COLUMN edit_revision INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE outgoing_message ADD COLUMN updated_at REAL NOT NULL DEFAULT 0;
            ALTER TABLE outgoing_message ADD COLUMN compression_enabled INTEGER NOT NULL DEFAULT 1;
            ALTER TABLE outgoing_message ADD COLUMN dispatch_claimed INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE outgoing_message ADD COLUMN attachments BLOB NOT NULL DEFAULT X'5B5D';
            UPDATE outgoing_message SET
                dispatch_order = enqueue_sequence,
                updated_at = enqueued_at,
                dispatch_claimed = CASE WHEN state IN ('sending', 'failed') THEN 1 ELSE 0 END;
            CREATE UNIQUE INDEX outgoing_blocked_tail
                ON outgoing_message(chat_id, thread_id) WHERE is_blocked = 1;
            CREATE INDEX outgoing_fifo ON outgoing_message(chat_id, thread_id, enqueue_sequence);
            DROP INDEX outgoing_dispatch;

            INSERT INTO outgoing_message
                (client_generated_id, chat_id, thread_id, sender_id, text, enqueued_at,
                 enqueue_sequence, dispatch_order, state, reply_to_message,
                 is_blocked, edit_revision, updated_at)
            SELECT lower(hex(randomblob(16))), d.chat_id, d.thread_id,
                   COALESCE((SELECT sender_id FROM outgoing_message o
                       WHERE o.chat_id = d.chat_id AND o.thread_id = d.thread_id
                       ORDER BY enqueue_sequence DESC LIMIT 1), 0),
                   d.text, d.updated_at, c.next_enqueue_sequence, c.next_enqueue_sequence,
                   'queued', d.reply_to_message, 1, d.edit_revision, d.updated_at
            FROM draft d JOIN local_conversation c
                ON c.chat_id = d.chat_id AND c.thread_id = d.thread_id
            WHERE d.text != '' OR d.reply_to_message IS NOT NULL;
            UPDATE local_conversation SET next_enqueue_sequence = next_enqueue_sequence + 1
                WHERE EXISTS (SELECT 1 FROM outgoing_message o
                    WHERE o.chat_id = local_conversation.chat_id
                    AND o.thread_id = local_conversation.thread_id AND o.is_blocked = 1);

            CREATE TABLE draft_revision (
                chat_id TEXT NOT NULL,
                thread_id TEXT NOT NULL DEFAULT '',
                edit_revision INTEGER NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY(chat_id, thread_id),
                FOREIGN KEY(chat_id, thread_id) REFERENCES local_conversation(chat_id, thread_id)
            );
            INSERT INTO draft_revision SELECT chat_id, thread_id, edit_revision, updated_at FROM draft;
            DROP TABLE draft;
            """)
    }
    try queue.read { db in
        if try migrator.hasBeenSuperseded(db) { throw LocalStorageError.unsupportedSchema }
    }
    try migrator.migrate(queue)
}
