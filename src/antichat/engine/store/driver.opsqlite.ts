import {open} from '@op-engineering/op-sqlite';

import type {SqlDriver, SqlRow, SqlValue} from './driver';

export const ANTICHAT_DB_NAME = 'antichat.db';

/** Opens (or creates) a database file in the app's default data directory. */
export function openOpSqlite(name: string = ANTICHAT_DB_NAME): SqlDriver {
  const db = open({name});
  // WAL keeps readers (search) from blocking behind a writer (sync).
  db.executeSync('PRAGMA journal_mode = WAL');
  db.executeSync('PRAGMA foreign_keys = OFF');
  return {
    async execute(sql: string, params: SqlValue[] = []): Promise<SqlRow[]> {
      const result = await db.execute(sql, params);
      return (result.rows ?? []) as SqlRow[];
    },
    close() {
      db.close();
    },
  };
}

/** Removes the database file. Dev screen and tests only. */
export function deleteOpSqlite(name: string): void {
  const db = open({name});
  db.delete();
}
