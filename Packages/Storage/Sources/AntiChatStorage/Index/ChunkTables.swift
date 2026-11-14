// The semantic index tables (M2.T16 step 2; architecture §5.1): `chunk` holds the text units the background indexer
// cut from finished messages, `chunk_fts` is their FTS5 index (external content), `chunk_vec` their embeddings
// (sqlite-vec vec0, 1024-d, rowid = chunk.id). A chunk without a `chunk_vec` row is waiting for the embedder.
// Incognito chats never get rows here (R-247; BackgroundJobQueue drops their jobs before anything is written).
import Foundation
import GRDB

public enum ChunkTables {
    static func v11ChunksVec(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE chunk (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              source TEXT NOT NULL,
              source_id TEXT NOT NULL,
              chat_id TEXT REFERENCES chat(id) ON DELETE CASCADE,
              ord INTEGER NOT NULL DEFAULT 0,
              text TEXT NOT NULL,
              created_at DOUBLE NOT NULL,
              UNIQUE (source, source_id, ord)
            );
            CREATE INDEX chunk_chat ON chunk(chat_id);
            CREATE VIRTUAL TABLE chunk_fts USING fts5(
              text, content='chunk', content_rowid='id', tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER chunk_fts_ai AFTER INSERT ON chunk
              BEGIN INSERT INTO chunk_fts(rowid, text) VALUES (new.id, new.text); END;
            CREATE TRIGGER chunk_fts_ad AFTER DELETE ON chunk
              BEGIN INSERT INTO chunk_fts(chunk_fts, rowid, text) VALUES ('delete', old.id, old.text); END;
            CREATE TRIGGER chunk_fts_au AFTER UPDATE OF text ON chunk
              BEGIN
                INSERT INTO chunk_fts(chunk_fts, rowid, text) VALUES ('delete', old.id, old.text);
                INSERT INTO chunk_fts(rowid, text) VALUES (new.id, new.text);
              END;
            """)
        try ensureVectorTable(db)
    }

    /// Creates `chunk_vec` when missing (idempotent; AppDatabase runs it after every migration) and keeps it in step
    /// with `chunk` deletes (a deleted chat drops its vectors too).
    public static func ensureVectorTable(_ db: Database) throws {
        guard try db.tableExists("chunk") else { return }
        if VecLoader.version(db) == nil { try VecLoader.load(db) }  // a writer opened without AppDatabase's config
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS chunk_vec USING vec0(embedding float[\(VecLoader.dimensions)]);
            CREATE TRIGGER IF NOT EXISTS chunk_vec_ad AFTER DELETE ON chunk
              BEGIN DELETE FROM chunk_vec WHERE rowid = old.id; END;
            """)
    }

    /// Little-endian float32 blob, the vec0 input format.
    public static func blob(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
