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
    try queue.read { db in
        if try migrator.hasBeenSuperseded(db) { throw LocalStorageError.unsupportedSchema }
    }
    try migrator.migrate(queue)
}
