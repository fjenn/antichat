import type {SqlDriver, SqlRow, SqlValue} from '../../driver';

/**
 * Jest driver on Node's built-in SQLite (FTS5 included). Jest's resolver
 * does not know `node:sqlite`, so the module is fetched from the process.
 */
export function openNodeSqlite(path: string = ':memory:'): SqlDriver {
  const sqlite = (process as any).getBuiltinModule('node:sqlite');
  const db = new sqlite.DatabaseSync(path);
  const statements = new Map<string, any>();
  return {
    async execute(sql: string, params: SqlValue[] = []): Promise<SqlRow[]> {
      let statement = statements.get(sql);
      if (!statement) {
        statement = db.prepare(sql);
        statements.set(sql, statement);
      }
      const rows = statement.all(...params) as SqlRow[];
      return rows.map(row => ({...row}));
    },
    close() {
      statements.clear();
      db.close();
    },
  };
}
