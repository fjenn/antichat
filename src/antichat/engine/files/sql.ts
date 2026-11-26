/**
 * `sql_query`: questions about a spreadsheet are answered by SQLite, not
 * by the model's arithmetic. One read-only SELECT over the tables imported
 * from the chat's files; everything else in antichat.db is out of reach.
 */
import type {Db} from '../store/driver';
import type {TableRow} from './FilesStore';

export class SqlRejected extends Error {}

const FORBIDDEN =
  /\b(insert|update|delete|drop|alter|create|attach|detach|pragma|replace|vacuum|reindex|analyze|begin|commit|rollback|savepoint|trigger)\b/i;

/**
 * Checks the statement and swaps the names the model knows for the real
 * tables. Throws `SqlRejected` with a message the model can act on.
 */
export function prepareSelect(sql: string, tables: TableRow[]): string {
  let statement = sql.trim().replace(/;+\s*$/, '');
  // Small models wrap the query in a code fence.
  statement = statement.replace(/^```(?:sql)?\s*|\s*```$/gi, '').trim();
  if (!/^(select|with)\b/i.test(statement)) {
    throw new SqlRejected('Only a single SELECT statement is allowed.');
  }
  const bare = statement
    .replace(/'(?:[^']|'')*'/g, "''")
    .replace(/--[^\n]*|\/\*[\s\S]*?\*\//g, ' ');
  if (bare.includes(';')) {
    throw new SqlRejected('Only one statement is allowed.');
  }
  if (FORBIDDEN.test(bare)) {
    throw new SqlRejected('Only reading is allowed (SELECT).');
  }
  const byName = new Map(tables.map(table => [table.name, table.sqlName]));
  const ctes = new Set(
    [...bare.matchAll(/(?:\bwith|,)\s+"?(\w+)"?\s+as\s*\(/gi)].map(m =>
      m[1].toLowerCase(),
    ),
  );
  for (const m of bare.matchAll(/\b(?:from|join)\s+(?!\()["`[]?(\w+)/gi)) {
    const name = m[1].toLowerCase();
    if (!byName.has(name) && !ctes.has(name)) {
      throw new SqlRejected(
        `Unknown table "${m[1]}". Tables: ${[...byName.keys()].join(', ')}.`,
      );
    }
  }
  // Replace outside string literals only.
  return statement
    .split(/('(?:[^']|'')*')/)
    .map((part, index) =>
      index % 2 === 1
        ? part
        : part.replace(/["`[]?\b(\w+)\b["`\]]?/g, (whole, word) => {
            const real = byName.get(String(word).toLowerCase());
            return real && !ctes.has(String(word).toLowerCase()) ? real : whole;
          }),
    )
    .join('');
}

const show = (value: unknown): string => {
  if (value === null || value === undefined) {
    return '';
  }
  if (typeof value === 'number' && !Number.isInteger(value)) {
    // Enough digits for money and averages without float noise.
    return String(Number(value.toFixed(6)));
  }
  return String(value);
};

export interface SqlResult {
  columns: string[];
  rows: unknown[][];
  /** Rows the query returned beyond those shown. */
  moreRows: number;
  text: string;
}

export async function runSelect(
  db: Db,
  sql: string,
  tables: TableRow[],
  maxRows: number,
): Promise<SqlResult> {
  const prepared = prepareSelect(sql, tables);
  // Belt and braces: no other table of antichat.db may be named at all
  // (comma joins and subqueries are not covered by the FROM/JOIN check).
  const allowed = new Set(tables.map(table => table.sqlName));
  const others = await db.all<{name: string}>(
    "SELECT name FROM sqlite_master WHERE type IN ('table', 'view')",
  );
  const words = new Set(
    prepared
      .replace(/'(?:[^']|'')*'/g, "''")
      .toLowerCase()
      .match(/\w+/g) ?? [],
  );
  for (const other of others) {
    const name = other.name.toLowerCase();
    if (
      !allowed.has(other.name) &&
      (words.has(name) || name === 'sqlite_master')
    ) {
      if (words.has(name)) {
        throw new SqlRejected(`Unknown table "${other.name}".`);
      }
    }
  }
  if (words.has('sqlite_master') || words.has('sqlite_schema')) {
    throw new SqlRejected('Only the listed tables can be read.');
  }
  const all = await db.all(
    `SELECT * FROM (${prepared}) LIMIT ${Math.max(1, maxRows) + 1}`,
  );
  const shown = all.slice(0, maxRows);
  const columns = shown.length ? Object.keys(shown[0]) : [];
  const rows = shown.map(row => columns.map(column => row[column]));
  let moreRows = 0;
  if (all.length > maxRows) {
    const count = await db.get<{n: number}>(
      `SELECT count(*) AS n FROM (${prepared})`,
    );
    moreRows = (count?.n ?? all.length) - maxRows;
  }
  const text =
    rows.length === 0
      ? 'The query returned no rows.'
      : [
          columns.join(' | '),
          ...rows.map(row => row.map(show).join(' | ')),
          moreRows > 0 ? `… ${moreRows} more rows not shown` : '',
        ]
          .filter(Boolean)
          .join('\n');
  return {columns, rows, moreRows, text};
}

/** The schema lines the model reads before it writes a query. */
export function describeTables(
  tables: TableRow[],
  samples: Map<number, unknown[][]>,
): string {
  return tables
    .map(table => {
      const rows = samples.get(table.id) ?? [];
      return [
        `Table ${table.name} (${table.rowCount} rows): ${table.columns
          .map(column => `${column.name} ${column.type}`)
          .join(', ')}`,
        ...rows.map(row => `  e.g. ${row.map(show).join(' | ')}`),
      ].join('\n');
    })
    .join('\n');
}
