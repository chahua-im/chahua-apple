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
    migrator.registerMigration("v2_reply_context") { db in
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
