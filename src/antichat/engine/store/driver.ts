/**
 * The only thing the conversation store knows about SQLite. Two drivers
 * implement it: op-sqlite on the phone (`driver.opsqlite.ts`) and Node's
 * built-in SQLite in Jest (`__tests__/support/nodeDriver.ts`).
 */
/** BLOB parameters (vectors) are bytes; op-sqlite takes either form. */
export type SqlValue = string | number | null | Uint8Array | ArrayBuffer;
export type SqlRow = Record<string, any>;

export interface SqlDriver {
  /** Runs one statement and returns its rows (empty for writes). */
  execute(sql: string, params?: SqlValue[]): Promise<SqlRow[]>;
  close(): void;
}

/**
 * Serialises units of work on one connection and wraps each in a
 * transaction. Not re-entrant: code running inside `transaction` must use
 * `all` / `get` / `run`, never `transaction` again (it would wait on itself).
 */
export class Db {
  private tail: Promise<unknown> = Promise.resolve();
  /** Counts `run` calls; lets callers tell whether a unit wrote anything. */
  mutations = 0;

  constructor(readonly driver: SqlDriver) {}

  all<T = SqlRow>(sql: string, params: SqlValue[] = []): Promise<T[]> {
    return this.driver.execute(sql, params) as Promise<T[]>;
  }

  async get<T = SqlRow>(
    sql: string,
    params: SqlValue[] = [],
  ): Promise<T | undefined> {
    const rows = await this.driver.execute(sql, params);
    return rows[0] as T | undefined;
  }

  async run(sql: string, params: SqlValue[] = []): Promise<void> {
    this.mutations++;
    await this.driver.execute(sql, params);
  }

  /**
   * Queues `work` behind every earlier unit and runs it inside
   * BEGIN/COMMIT. A throw rolls the whole unit back.
   */
  transaction<T>(work: () => Promise<T>): Promise<T> {
    const run = async () => {
      await this.driver.execute('BEGIN IMMEDIATE');
      try {
        const result = await work();
        await this.driver.execute('COMMIT');
        return result;
      } catch (error) {
        await this.driver.execute('ROLLBACK').catch(() => undefined);
        throw error;
      }
    };
    const next = this.tail.then(run, run);
    this.tail = next.catch(() => undefined);
    return next;
  }
}
