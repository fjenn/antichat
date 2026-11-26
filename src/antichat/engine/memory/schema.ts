import {registerMigrations, type MigrationStep} from '../store/schema';

/**
 * The `memory` namespace of antichat.db. M3 reserved the `memories` table;
 * these steps add what M9 needs. Never edit a shipped step; append one.
 */
export const MEMORY_NAMESPACE = 'memory';

const steps: MigrationStep[] = [
  {
    version: 1,
    statements: [
      'ALTER TABLE memories ADD COLUMN project_id TEXT',
      "ALTER TABLE memories ADD COLUMN origin TEXT NOT NULL DEFAULT 'user'",
      'ALTER TABLE memories ADD COLUMN importance REAL NOT NULL DEFAULT 0.5',
      'ALTER TABLE memories ADD COLUMN sensitive TEXT',
      // Normalised text (exact-duplicate key) and single-valued slot.
      "ALTER TABLE memories ADD COLUMN norm TEXT NOT NULL DEFAULT ''",
      'ALTER TABLE memories ADD COLUMN slot TEXT',
      'ALTER TABLE memories ADD COLUMN last_used_at INTEGER',
      'ALTER TABLE memories ADD COLUMN use_count INTEGER NOT NULL DEFAULT 0',
      // 1: saved by the tool next to similar memories; the idle pass lets
      // the model merge them.
      'ALTER TABLE memories ADD COLUMN review INTEGER NOT NULL DEFAULT 0',
      'CREATE INDEX memories_scope ON memories (project_id, pinned, updated_at)',
      'CREATE INDEX memories_norm ON memories (norm)',
      `CREATE VIRTUAL TABLE memories_fts USING fts5(
        text, content = 'memories', content_rowid = 'rowid',
        tokenize = 'porter unicode61 remove_diacritics 2'
      )`,
      `CREATE TRIGGER memories_fts_insert AFTER INSERT ON memories BEGIN
        INSERT INTO memories_fts (rowid, text) VALUES (new.rowid, new.text);
      END`,
      `CREATE TRIGGER memories_fts_delete AFTER DELETE ON memories BEGIN
        INSERT INTO memories_fts (memories_fts, rowid, text)
        VALUES ('delete', old.rowid, old.text);
      END`,
      `CREATE TRIGGER memories_fts_update AFTER UPDATE OF text ON memories BEGIN
        INSERT INTO memories_fts (memories_fts, rowid, text)
        VALUES ('delete', old.rowid, old.text);
        INSERT INTO memories_fts (rowid, text) VALUES (new.rowid, new.text);
      END`,
      // One row per answer that had memories in its prompt. The items hold
      // ids only: deleting a memory removes it from every old answer too.
      `CREATE TABLE memory_uses (
        id TEXT PRIMARY KEY NOT NULL,
        session_id TEXT NOT NULL,
        message_id TEXT,
        created_at INTEGER NOT NULL
      )`,
      'CREATE INDEX memory_uses_session ON memory_uses (session_id, created_at)',
      'CREATE INDEX memory_uses_message ON memory_uses (message_id)',
      `CREATE TABLE memory_use_items (
        use_id TEXT NOT NULL,
        memory_id TEXT NOT NULL,
        how TEXT NOT NULL,
        cited INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (use_id, memory_id)
      )`,
      'CREATE INDEX memory_use_items_memory ON memory_use_items (memory_id)',
      `CREATE TABLE memory_settings (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
      )`,
      // Signatures of memories the user deleted, so the background pass
      // does not bring them back. Hashes only; no text.
      `CREATE TABLE memory_tombstones (
        signature TEXT PRIMARY KEY NOT NULL,
        created_at INTEGER NOT NULL
      )`,
      // How far each chat has been read by the background pass.
      `CREATE TABLE memory_extraction (
        session_id TEXT PRIMARY KEY NOT NULL,
        through_seq INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )`,
      // Rolling one-line digest per chat ("reference past chats").
      `CREATE TABLE chat_digests (
        session_id TEXT PRIMARY KEY NOT NULL,
        digest TEXT NOT NULL,
        through_seq INTEGER NOT NULL,
        source TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )`,
    ],
  },
];

/** Call before the conversation store is initialised (or before `migrate`). */
export function registerMemoryMigrations(): void {
  registerMigrations(MEMORY_NAMESPACE, steps);
}

export const MEMORY_SCHEMA_VERSION = steps[steps.length - 1].version;
