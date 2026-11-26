import type {Db} from './driver';

/**
 * antichat.db schema. Each milestone owns a namespace with its own version
 * counter, so M9 (memory) or M10 (files) can add steps with
 * `registerMigrations` without editing this file's `core` list.
 *
 * Never edit a shipped step; append a new one.
 */
export interface MigrationStep {
  version: number;
  statements: string[];
}

const FTS_OPTIONS =
  "tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3'";

const core: MigrationStep[] = [
  {
    version: 1,
    statements: [
      // Every message ever written, as a tree. `on_path` marks the visible
      // thread (root to current leaf); `up_id` is the id of the row that
      // mirrors the node in upstream's WatermelonDB `messages` table.
      `CREATE TABLE nodes (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        id TEXT NOT NULL UNIQUE,
        session_id TEXT NOT NULL,
        parent_id TEXT,
        role TEXT NOT NULL,
        text TEXT NOT NULL DEFAULT '',
        payload TEXT NOT NULL,
        ext_id TEXT,
        ext TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        on_path INTEGER NOT NULL DEFAULT 0,
        depth INTEGER NOT NULL DEFAULT 0,
        active_child_id TEXT,
        up_id TEXT
      )`,
      'CREATE INDEX nodes_path ON nodes (session_id, on_path, depth)',
      'CREATE INDEX nodes_parent ON nodes (session_id, parent_id)',
      'CREATE INDEX nodes_up ON nodes (up_id)',
      `CREATE TABLE session_meta (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL UNIQUE,
        title TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        archived_at INTEGER,
        pinned_at INTEGER,
        temporary INTEGER NOT NULL DEFAULT 0,
        locked INTEGER NOT NULL DEFAULT 0,
        project_id TEXT,
        current_leaf_id TEXT,
        origin_kind TEXT,
        origin_session_id TEXT,
        origin_node_id TEXT,
        ext_id TEXT,
        ext TEXT
      )`,
      'CREATE INDEX session_meta_listing ON session_meta (temporary, archived_at, updated_at)',
      'CREATE INDEX session_meta_project ON session_meta (project_id)',
      'CREATE INDEX session_meta_ext ON session_meta (ext_id)',
      // Full-text mirrors. External-content tables: the text lives once, in
      // `nodes` / `session_meta`, and triggers keep the index in step.
      `CREATE VIRTUAL TABLE messages_fts USING fts5(
        text, content = 'nodes', content_rowid = 'seq', ${FTS_OPTIONS}
      )`,
      `CREATE TRIGGER nodes_fts_insert AFTER INSERT ON nodes BEGIN
        INSERT INTO messages_fts (rowid, text) VALUES (new.seq, new.text);
      END`,
      `CREATE TRIGGER nodes_fts_delete AFTER DELETE ON nodes BEGIN
        INSERT INTO messages_fts (messages_fts, rowid, text)
        VALUES ('delete', old.seq, old.text);
      END`,
      `CREATE TRIGGER nodes_fts_update AFTER UPDATE OF text ON nodes BEGIN
        INSERT INTO messages_fts (messages_fts, rowid, text)
        VALUES ('delete', old.seq, old.text);
        INSERT INTO messages_fts (rowid, text) VALUES (new.seq, new.text);
      END`,
      `CREATE VIRTUAL TABLE titles_fts USING fts5(
        title, content = 'session_meta', content_rowid = 'seq', ${FTS_OPTIONS}
      )`,
      `CREATE TRIGGER session_meta_fts_insert AFTER INSERT ON session_meta BEGIN
        INSERT INTO titles_fts (rowid, title) VALUES (new.seq, new.title);
      END`,
      `CREATE TRIGGER session_meta_fts_delete AFTER DELETE ON session_meta BEGIN
        INSERT INTO titles_fts (titles_fts, rowid, title)
        VALUES ('delete', old.seq, old.title);
      END`,
      `CREATE TRIGGER session_meta_fts_update AFTER UPDATE OF title ON session_meta BEGIN
        INSERT INTO titles_fts (titles_fts, rowid, title)
        VALUES ('delete', old.seq, old.title);
        INSERT INTO titles_fts (rowid, title) VALUES (new.seq, new.title);
      END`,
      // Reserved for later milestones (M9 memory and projects, M10 files,
      // M12 tasks). Created now so one migration history covers the file;
      // owners add columns through their own namespace.
      `CREATE TABLE memories (
        id TEXT PRIMARY KEY NOT NULL,
        text TEXT NOT NULL,
        kind TEXT,
        source_session_id TEXT,
        source_node_id TEXT,
        pinned INTEGER NOT NULL DEFAULT 0,
        data TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )`,
      `CREATE TABLE projects (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        instructions TEXT NOT NULL DEFAULT '',
        data TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )`,
      `CREATE TABLE files (
        id TEXT PRIMARY KEY NOT NULL,
        project_id TEXT,
        session_id TEXT,
        name TEXT NOT NULL,
        mime_type TEXT,
        size INTEGER,
        uri TEXT,
        status TEXT,
        data TEXT,
        created_at INTEGER NOT NULL
      )`,
      'CREATE INDEX files_project ON files (project_id)',
      'CREATE INDEX files_session ON files (session_id)',
      `CREATE TABLE chunks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        text TEXT NOT NULL,
        data TEXT
      )`,
      'CREATE INDEX chunks_file ON chunks (file_id, position)',
      // Plain BLOB embeddings; sqlite-vec's scalar functions
      // (vec_distance_cosine) work on them without a vec0 table.
      `CREATE TABLE vectors (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        owner_kind TEXT NOT NULL,
        owner_id TEXT NOT NULL,
        model TEXT NOT NULL,
        dims INTEGER NOT NULL,
        embedding BLOB NOT NULL
      )`,
      'CREATE INDEX vectors_owner ON vectors (owner_kind, owner_id)',
      `CREATE TABLE tasks (
        id TEXT PRIMARY KEY NOT NULL,
        title TEXT NOT NULL,
        prompt TEXT NOT NULL,
        schedule TEXT,
        next_run_at INTEGER,
        last_run_at INTEGER,
        session_id TEXT,
        enabled INTEGER NOT NULL DEFAULT 1,
        data TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )`,
    ],
  },
];

const registry = new Map<string, MigrationStep[]>([['core', core]]);

/** Adds another namespace's steps. Call before the store is initialised. */
export function registerMigrations(
  namespace: string,
  steps: MigrationStep[],
): void {
  if (namespace === 'core') {
    throw new Error('The core namespace belongs to the conversation store');
  }
  registry.set(namespace, steps);
}

/** Applies every pending step, one transaction per step. `core` runs first. */
export async function migrate(db: Db): Promise<Record<string, number>> {
  await db.run(
    `CREATE TABLE IF NOT EXISTS schema_migrations (
      namespace TEXT PRIMARY KEY NOT NULL,
      version INTEGER NOT NULL
    )`,
  );
  const applied: Record<string, number> = {};
  for (const [namespace, steps] of registry) {
    const row = await db.get<{version: number}>(
      'SELECT version FROM schema_migrations WHERE namespace = ?',
      [namespace],
    );
    let current = row?.version ?? 0;
    const pending = steps
      .filter(step => step.version > current)
      .sort((a, b) => a.version - b.version);
    for (const step of pending) {
      await db.transaction(async () => {
        for (const statement of step.statements) {
          await db.run(statement);
        }
        await db.run(
          `INSERT INTO schema_migrations (namespace, version) VALUES (?, ?)
           ON CONFLICT (namespace) DO UPDATE SET version = excluded.version`,
          [namespace, step.version],
        );
      });
      current = step.version;
    }
    applied[namespace] = current;
  }
  return applied;
}

export const CORE_SCHEMA_VERSION = core[core.length - 1].version;
