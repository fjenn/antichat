import {registerMigrations, type MigrationStep} from '../store/schema';

/**
 * The `files` namespace of antichat.db. M3 reserved `files`, `chunks` and
 * `vectors`; this adds what attachments need: where a file is attached,
 * how it is used, a keyword index over its chunks, and the list of tables
 * imported from spreadsheets.
 */
export const FILES_NAMESPACE = 'files';

const steps: MigrationStep[] = [
  {
    version: 1,
    statements: [
      // The message the file was sent with; null while it is a draft.
      'ALTER TABLE files ADD COLUMN message_id TEXT',
      'ALTER TABLE files ADD COLUMN kind TEXT',
      // 'inline' | 'retrieval' | 'vision' | 'ocr' | 'table' | 'audio'
      'ALTER TABLE files ADD COLUMN mode TEXT',
      'ALTER TABLE files ADD COLUMN page_count INTEGER',
      'ALTER TABLE files ADD COLUMN token_count INTEGER',
      'ALTER TABLE chunks ADD COLUMN page_start INTEGER',
      'ALTER TABLE chunks ADD COLUMN page_end INTEGER',
      `CREATE VIRTUAL TABLE chunks_fts USING fts5(
        text, content = 'chunks', content_rowid = 'id',
        tokenize = 'unicode61 remove_diacritics 2'
      )`,
      `CREATE TRIGGER chunks_fts_insert AFTER INSERT ON chunks BEGIN
        INSERT INTO chunks_fts (rowid, text) VALUES (new.id, new.text);
      END`,
      `CREATE TRIGGER chunks_fts_delete AFTER DELETE ON chunks BEGIN
        INSERT INTO chunks_fts (chunks_fts, rowid, text)
        VALUES ('delete', old.id, old.text);
      END`,
      // One row per spreadsheet table imported for SQL questions. The data
      // itself is in a table of its own named `sql_name` (ft_<n>).
      `CREATE TABLE file_tables (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_id TEXT NOT NULL,
        name TEXT NOT NULL,
        sql_name TEXT NOT NULL,
        columns TEXT NOT NULL,
        row_count INTEGER NOT NULL
      )`,
      'CREATE INDEX file_tables_file ON file_tables (file_id)',
    ],
  },
];

/** Call before the conversation store is initialised (or before `migrate`). */
export function registerFilesMigrations(): void {
  registerMigrations(FILES_NAMESPACE, steps);
}
